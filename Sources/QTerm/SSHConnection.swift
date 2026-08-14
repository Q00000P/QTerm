import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto
import SessionVaultKit

/// Одно SSH-соединение на сессию: shell-канал с PTY (для терминала) и
/// SFTP-канал (для проводника) поверх него же — как это делает MobaXterm.

/// Wire-сериализация публичного ключа сервера (для TOFU-хранения/сравнения).
func hostKeyWireData(_ key: NIOSSHPublicKey) -> Data {
    var buf = ByteBufferAllocator().buffer(capacity: 256)
    _ = key.write(to: &buf)
    return Data(buf.readableBytesView)
}

/// TOFU: делегат первого контакта — пропускает любой ключ, но отдаёт его
/// наружу; решение о доверии принимается после коннекта сравнением с вейлтом.
final class FirstContactRecorder: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    var capturedKey: NIOSSHPublicKey?
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        capturedKey = hostKey
        validationCompletePromise.succeed(())
    }
}

@MainActor
final class SSHConnection: ObservableObject {

    enum Status: Equatable {
        case idle
        case connecting
        case awaitingTrust(fingerprint: String)
        case connected
        case failed(String)
        case closed
    }

    @Published var status: Status = .idle

    private let sessionProvider: () -> Session
    var session: Session { sessionProvider() }
    private let secrets: SecretStore

    private var client: SSHClient?
    private(set) var sftp: SFTPClient?

    /// Терминал подписывается сюда и кормит байты в SwiftTerm.feed.
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    /// Дёргается на любой вывод с сервера — для индикатора активности в сайдбаре.
    var onActivity: (() -> Void)?
    /// Писалка в stdin PTY; выставляется после установления shell-канала.
    private var stdinWriter: TTYStdinWriter?

    private var shellTask: Task<Void, Never>?

    // MARK: - Реконнект / TOFU state

    var pendingHostKey: String?
    var pendingFingerprint: String?

    /// Авто-реконнект при обрыве установленного соединения.
    var autoReconnect = true
    /// Поколение соединения: события от устаревших connect-тасков игнорируются.
    private var generation = 0
    /// Ручной режим: до этого момента авто-ретраи молчат. Published — UI показывает отсчёт.
    @Published var autoPausedUntil: Date?
    /// Когда автомат сделает следующую попытку (для живого отсчёта в статус-баре).
    @Published var nextRetryAt: Date?
    /// Начало текущей попытки подключения — статус-бар показывает её длительность.
    @Published var attemptStartedAt: Date?
    /// Номер текущей попытки (1, 2, 3…) — 0 если попыток ещё не было.
    @Published var attemptNumber = 0
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?
    private var wasConnected = false

    init(sessionProvider: @escaping () -> Session, secrets: SecretStore) {
        self.sessionProvider = sessionProvider
        self.secrets = secrets
    }

    // MARK: - Connect

    func connect(cols: Int, rows: Int) {
        guard status != .connecting, status != .connected else { return }
        status = .connecting
        attemptStartedAt = Date()
        attemptNumber += 1
        nextRetryAt = nil

        generation += 1
        let gen = generation
        shellTask = Task {
            do {
                let session = self.session // свежая копия из AppState
                let auth = try self.makeAuthMethod()

                let recorder = FirstContactRecorder()
                let validator: SSHHostKeyValidator = .custom(recorder)

                let client = try await SSHClient.connect(
                    host: session.host,
                    port: session.port,
                    authenticationMethod: auth,
                    hostKeyValidator: validator,
                    reconnect: .never
                )
                guard gen == self.generation else { try? await client.close(); return }
                self.client = client

                // TOFU: сверка/сохранение ключа сервера.
                if let captured = recorder.capturedKey {
                    let wire = hostKeyWireData(captured)
                    let fingerprint = "SHA256:" + Data(SHA256.hash(data: wire)).base64EncodedString()
                    if let stored = session.extra["hostkey"] {
                        if stored != wire.base64EncodedString() {
                            try? await client.close()
                            self.client = nil
                            self.status = .failed("КЛЮЧ СЕРВЕРА ИЗМЕНИЛСЯ! Возможен MITM или переустановка сервера. Текущий: \(fingerprint). Если смена легитимна — удали сессию и создай заново.")
                            return
                        }
                    } else {
                        self.pendingHostKey = wire.base64EncodedString()
                        self.pendingFingerprint = fingerprint
                        try? await client.close()
                        self.client = nil
                        self.status = .awaitingTrust(fingerprint: fingerprint)
                        return
                    }
                }

                // SFTP на том же соединении — сразу, чтобы проводник
                // был готов одновременно с терминалом.
                let sftp = try await client.openSFTP()
                guard gen == self.generation else { try? await client.close(); return }
                self.sftp = sftp

                self.status = .connected
                self.wasConnected = true
                self.retryAttempt = 0
                self.autoPausedUntil = nil
                self.nextRetryAt = nil
                self.attemptStartedAt = nil
                self.attemptNumber = 0
                self.onOutput?(Array("\r\n".utf8)[...])

                // Shell с PTY. Блокируется до конца сессии.
                try await client.withPTY(
                    SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: "xterm-256color",
                        terminalCharacterWidth: cols,
                        terminalRowHeight: rows,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes: .init([.ECHO: 1])
                    )
                ) { ttyOutput, stdinWriter in
                    guard gen == self.generation else { return }
                    self.stdinWriter = stdinWriter
                    for try await chunk in ttyOutput {
                        guard gen == self.generation else { return }
                        let buffer: ByteBuffer
                        switch chunk {
                        case .stdout(let b): buffer = b
                        case .stderr(let b): buffer = b
                        }
                        if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                            self.onOutput?(bytes[...])
                            self.onActivity?()
                        }
                    }
                }

                guard gen == self.generation else { return }
                self.status = .closed
                self.scheduleRetryIfNeeded(reason: "соединение закрыто")
            } catch {
                guard gen == self.generation else { return }
                let text = String(describing: error)
                self.attemptStartedAt = nil
                // Исход каждой попытки видим в терминале — иначе непонятно,
                // работает ли реконнект вообще.
                if self.wasConnected {
                    let short = text.count > 90 ? String(text.prefix(90)) + "…" : text
                    self.onOutput?(Array("\u{1B}[31m✗ попытка не удалась: \(short)\u{1B}[0m\r\n".utf8)[...])
                }
                self.status = .failed(text)
                // Сетевые обрывы ретраим, ошибки аутентификации/ключей — нет
                // (молотить сервер неверным ключом = бан fail2ban).
                let authFailure = text.contains("allAuthenticationOptionsFailed")
                    || text.contains("InvalidOpenSSHKey")
                    || text.contains("missingDecryptionKey")
                    || text.contains("КЛЮЧ СЕРВЕРА")
                if !authFailure {
                    self.scheduleRetryIfNeeded(reason: text)
                }
            }
        }
    }

    private func makeAuthMethod() throws -> SSHAuthenticationMethod {
        switch session.authMethod {
        case .password:
            guard let password = try secrets.get(for: session.id, kind: .password) else {
                throw ConnectionError.missingSecret("нет пароля в Keychain")
            }
            return .passwordBased(username: session.username, password: password)

        case .privateKey:
            guard let path = session.privateKeyPath else {
                throw ConnectionError.missingSecret("не указан путь к ключу")
            }
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw ConnectionError.missingSecret("файл ключа не найден: \(expanded)")
            }
            let keyText = try String(contentsOfFile: expanded, encoding: .utf8)
            let firstLine = keyText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "<пусто>"
            guard keyText.contains("BEGIN OPENSSH PRIVATE KEY") else {
                throw ConnectionError.missingSecret("не-OpenSSH формат в \(expanded), первая строка: \(firstLine.prefix(40))")
            }
            let passphrase = try secrets.get(for: session.id, kind: .privateKeyPassphrase)
            let decryptionKey = passphrase.map { Data($0.utf8) }
            if let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryptionKey) {
                return .ed25519(username: session.username, privateKey: ed)
            }
            // RSA Citadel подписывает как ssh-rsa (SHA-1) — современный sshd отвергнет.
            // Поддержка RSA — через будущий форк Citadel (легаси-хосты типа Keenetic).
            _ = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey)
            throw ConnectionError.missingSecret("RSA-ключ (\(expanded)) — Citadel подписывает его как ssh-rsa, сервер такое не примет; укажи ed25519-ключ")

        case .agent:
            throw ConnectionError.missingSecret("agent-аутентификация — после MVP")
        }
    }

    // MARK: - Terminal I/O

    func sendToShell(_ data: ArraySlice<UInt8>) {
        guard let writer = stdinWriter else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        Task { try? await writer.write(buffer) }
    }

    func resize(cols: Int, rows: Int) {
        guard let writer = stdinWriter else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    // MARK: - TOFU

    func trustPendingHostKey(save: (String) -> Void) {
        guard let key = pendingHostKey else { return }
        save(key)
        pendingHostKey = nil
        pendingFingerprint = nil
        reconnect()
    }

    // MARK: - Реконнект

    private func scheduleRetryIfNeeded(reason: String) {
        guard autoReconnect, wasConnected else { return }

        // Ручной режим: автомат молчит до конца паузы, потом возобновляется.
        if let until = autoPausedUntil, Date() < until {
            status = .closed
            let gen = generation
            retryTask = Task { [weak self] in
                let ns = UInt64(max(1, until.timeIntervalSinceNow) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                self.autoPausedUntil = nil
                self.retryAttempt = 0
                self.scheduleRetryIfNeeded(reason: "возобновление после ручного режима")
            }
            return
        }
        if autoPausedUntil != nil { autoPausedUntil = nil; retryAttempt = 0 }

        retryAttempt += 1
        let delay = min(30.0, pow(2.0, Double(retryAttempt - 1)))
        // В скроллбек — только факт обрыва, без обещаний времени (они устаревают
        // и путают: живое состояние показывает статус-бар).
        if retryAttempt == 1 {
            let banner = "\r\n\u{1B}[33m— обрыв: \(reason) —\u{1B}[0m\r\n"
            onOutput?(Array(banner.utf8)[...])
        }
        status = .closed
        nextRetryAt = Date().addingTimeInterval(delay)
        retryTask?.cancel()
        let gen = generation
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.nextRetryAt = nil
            self.shellTask?.cancel()
            let oldClient = self.client
            Task { try? await oldClient?.close() }
            self.client = nil
            self.sftp = nil
            self.stdinWriter = nil
            self.status = .idle
            self.connect(cols: 80, rows: 24)
        }
    }

    /// Немедленная попытка, минуя таймер бэкоффа (клавиша R / кнопка «Сейчас»).
    /// Каждый вызов перевзводит ручную паузу автомата на 60с.
    func retryNow() {
        onOutput?(Array("\r\n\u{1B}[36m→ попытка подключения вручную…\u{1B}[0m\r\n".utf8)[...])
        autoPausedUntil = Date().addingTimeInterval(60)
        nextRetryAt = nil
        generation += 1 // осиротить все летящие таски
        retryTask?.cancel()
        retryTask = nil
        shellTask?.cancel()
        let oldClient = client
        Task { try? await oldClient?.close() }
        client = nil
        sftp = nil
        stdinWriter = nil
        status = .idle
        connect(cols: 80, rows: 24)
    }

    /// R живая всегда, пока нет установленного соединения — включая долгую
    /// попытку подключения: нажатие бросает её и стартует новую немедленно.
    var isInterrupted: Bool {
        switch status {
        case .connected, .awaitingTrust, .idle: return false
        case .connecting: return wasConnected || attemptNumber > 1
        case .failed, .closed: return true
        }
    }

    func reconnect() {
        disconnect()
        status = .idle
        connect(cols: 80, rows: 24)
    }

    // MARK: - Teardown

    func disconnect() {
        generation += 1 // никакие висящие таски больше не действительны
        retryTask?.cancel()
        retryTask = nil
        wasConnected = false
        retryAttempt = 0
        autoPausedUntil = nil
        nextRetryAt = nil
        attemptStartedAt = nil
        attemptNumber = 0
        shellTask?.cancel()
        shellTask = nil
        let client = self.client
        self.client = nil
        self.sftp = nil
        self.stdinWriter = nil
        Task { try? await client?.close() }
        status = .closed
    }

    enum ConnectionError: LocalizedError {
        case missingSecret(String)
        var errorDescription: String? {
            if case .missingSecret(let s) = self { return s }
            return nil
        }
    }
}
