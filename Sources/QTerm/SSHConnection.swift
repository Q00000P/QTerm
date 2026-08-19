import Foundation
import Citadel
import NIOCore
import NIOSSH
import Crypto
import SessionVaultKit

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

// MARK: - TerminalChannel (вкладка)

/// Один shell-канал с PTY поверх SSH-соединения ноды = одна вкладка.
/// Несколько каналов мультиплексируются в одном соединении, как в MobaXterm:
/// аутентификация, TOFU и Touch ID происходят один раз на ноду.
@MainActor
final class TerminalChannel: ObservableObject, Identifiable {
    let id = UUID()
    /// Номер вкладки для заголовка (1, 2, 3…). Присваивает соединение.
    @Published var index: Int = 1
    /// Заголовок из OSC 0/2, если шелл его прислал.
    @Published var title: String?
    /// Канал открыт и качает данные.
    @Published private(set) var isRunning = false

    /// Байты с сервера — терминал кормит их в SwiftTerm.feed.
    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    /// Любая активность канала (для маячка в сайдбаре).
    var onActivity: (() -> Void)?

    private var stdinWriter: TTYStdinWriter?
    var task: Task<Void, Never>?
    /// Последний известный размер — используется при переоткрытии канала.
    var cols: Int = 80
    var rows: Int = 24

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return "Терминал \(index)"
    }

    func send(_ data: ArraySlice<UInt8>) {
        guard let writer = stdinWriter else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        Task { try? await writer.write(buffer) }
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        guard let writer = stdinWriter else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    func detach() {
        stdinWriter = nil
        isRunning = false
        task?.cancel()
        task = nil
    }

    func write(_ text: String) {
        onOutput?(Array(text.utf8)[...])
    }

    /// Открывает shell+PTY и качает вывод до конца канала. Блокируется.
    func run(client: SSHClient, isCurrent: @escaping () -> Bool) async throws {
        isRunning = true
        defer { isRunning = false }
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
            guard isCurrent() else { return }
            self.stdinWriter = stdinWriter
            for try await chunk in ttyOutput {
                guard isCurrent() else { return }
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
    }
}

// MARK: - SSHConnection (соединение ноды)

/// Одно SSH-соединение на ноду: аутентификация, TOFU, SFTP, реконнект.
/// Терминалы живут во вкладках (TerminalChannel) поверх этого соединения.
/// Транспортные алгоритмы: добавляем AES128-CTR к штатным GCM из nio-ssh.
private let ctrOnlyAlgorithms: SSHAlgorithms = {
    var a = SSHAlgorithms()
    a.transportProtectionSchemes = .add([AES128CTR.self])
    return a
}()

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
    /// Вкладки этой ноды. Первая создаётся сразу, чтобы UI было что рисовать.
    @Published private(set) var channels: [TerminalChannel] = []

    private let sessionProvider: () -> Session
    var session: Session { sessionProvider() }
    private let secrets: SecretStore
    /// Ключ из хранилища вейлта по id (замыкание в AppState).
    private let keyProvider: (UUID) -> SSHKey?

    private var client: SSHClient?
    private(set) var sftp: SFTPClient?

    /// Активность любой вкладки (маячок в сайдбаре).
    var onActivity: (() -> Void)?

    private var connectTask: Task<Void, Never>?

    // MARK: - Реконнект / TOFU state

    var pendingHostKey: String?
    var pendingFingerprint: String?

    var autoReconnect = true
    private var generation = 0
    @Published var autoPausedUntil: Date?
    @Published var nextRetryAt: Date?
    @Published var attemptStartedAt: Date?
    @Published var attemptNumber = 0
    private var retryAttempt = 0
    private var retryTask: Task<Void, Never>?
    private var wasConnected = false

    init(sessionProvider: @escaping () -> Session,
         secrets: SecretStore,
         keyProvider: @escaping (UUID) -> SSHKey? = { _ in nil }) {
        self.sessionProvider = sessionProvider
        self.secrets = secrets
        self.keyProvider = keyProvider
        _ = addChannel() // первая вкладка
    }

    // MARK: - Вкладки

    @discardableResult
    func addChannel() -> TerminalChannel {
        let ch = TerminalChannel()
        ch.index = (channels.map(\.index).max() ?? 0) + 1
        ch.onActivity = { [weak self] in self?.onActivity?() }
        channels.append(ch)
        // Соединение живо — открываем канал сразу.
        if let client, status == .connected {
            startChannel(ch, client: client, gen: generation)
        }
        return ch
    }

    func closeChannel(_ ch: TerminalChannel) {
        ch.detach()
        channels.removeAll { $0.id == ch.id }
        // Последнюю вкладку не закрываем в ноль — держим одну пустую.
        if channels.isEmpty {
            _ = addChannel()
        }
    }

    /// Рассылка во все вкладки этой ноды.
    func sendToAllChannels(_ data: ArraySlice<UInt8>) {
        for ch in channels { ch.send(data) }
    }

    private func startChannel(_ ch: TerminalChannel, client: SSHClient, gen: Int) {
        ch.task = Task { [weak self] in
            guard let self else { return }
            do {
                try await ch.run(client: client) { gen == self.generation }
            } catch {
                if gen == self.generation {
                    let text = String(describing: error)
                    let short = text.count > 90 ? String(text.prefix(90)) + "…" : text
                    ch.write("\r\n\u{1B}[31m✗ канал закрыт: \(short)\u{1B}[0m\r\n")
                }
            }
            guard gen == self.generation else { return }
            self.channelFinished()
        }
    }

    /// Канал завершился: если умерли все — соединение считается оборванным.
    private func channelFinished() {
        guard status == .connected else { return }
        if channels.allSatisfy({ !$0.isRunning }) {
            status = .closed
            scheduleRetryIfNeeded(reason: "соединение закрыто")
        }
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
        connectTask = Task {
            do {
                let session = self.session
                let auth = try self.makeAuthMethod()

                let recorder = FirstContactRecorder()
                let validator: SSHHostKeyValidator = .custom(recorder)

                let client = try await SSHClient.connect(
                    host: session.host,
                    port: session.port,
                    authenticationMethod: auth,
                    hostKeyValidator: validator,
                    reconnect: .never,
                    // Только транспортный шифр: AES128-CTR нужен Keenetic/
                    // Entware (там нет gcm). RSA как алгоритм ХОСТ-ключа не
                    // регистрируем: наш патченый префикс rsa-sha2-256 заставлял
                    // сервер отдавать RSA-хост-ключ, а его сериализация в
                    // Citadel падает (precondition в ByteBuffer).
                    algorithms: ctrOnlyAlgorithms
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

                // Открываем каналы для всех существующих вкладок.
                if self.channels.isEmpty { _ = self.addChannel() }
                self.channels.first?.cols = cols
                self.channels.first?.rows = rows
                for ch in self.channels {
                    ch.write("\r\n")
                    self.startChannel(ch, client: client, gen: gen)
                }
            } catch {
                guard gen == self.generation else { return }
                let text = String(describing: error)
                self.attemptStartedAt = nil
                if self.wasConnected {
                    let short = text.count > 90 ? String(text.prefix(90)) + "…" : text
                    self.broadcastToChannels("\u{1B}[31m✗ попытка не удалась: \(short)\u{1B}[0m\r\n")
                }
                self.status = .failed(text)
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

    private func broadcastToChannels(_ text: String) {
        for ch in channels { ch.write(text) }
    }

    private func makeAuthMethod() throws -> SSHAuthenticationMethod {
        switch session.authMethod {
        case .password:
            guard let password = try secrets.get(for: session.id, kind: .password) else {
                throw ConnectionError.missingSecret("нет пароля в хранилище")
            }
            return .passwordBased(username: session.username, password: password)

        case .privateKey:
            let keyText: String
            let passphrase: String?
            let sourceLabel: String

            if let keyID = session.keyID, let vaultKey = keyProvider(keyID) {
                // Ключ из хранилища вейлта — файл на диске не нужен.
                keyText = vaultKey.privateKey
                passphrase = secrets.passphrase(forKeyID: keyID)
                sourceLabel = "ключ «\(vaultKey.name)» из хранилища"
            } else if let path = session.privateKeyPath {
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else {
                    throw ConnectionError.missingSecret("файл ключа не найден: \(expanded)")
                }
                keyText = try String(contentsOfFile: expanded, encoding: .utf8)
                passphrase = secrets.passphrase(forPath: expanded, legacySession: session.id)
                sourceLabel = expanded
            } else {
                throw ConnectionError.missingSecret("не назначен ключ (хранилище или файл)")
            }

            let firstLine = keyText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "<пусто>"
            guard keyText.contains("BEGIN OPENSSH PRIVATE KEY") else {
                throw ConnectionError.missingSecret("не-OpenSSH формат (\(sourceLabel)), первая строка: \(firstLine.prefix(40))")
            }
            let decryptionKey = passphrase.map { Data($0.utf8) }
            if let ed = try? Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: decryptionKey) {
                return .ed25519(username: session.username, privateKey: ed)
            }
            // RSA: наш форк Citadel подписывает rsa-sha2-256 (RFC 8332).
            let rsa = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey)
            return .rsa(username: session.username, privateKey: rsa)

        case .agent:
            throw ConnectionError.missingSecret("agent-аутентификация — после MVP")
        }
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
        if retryAttempt == 1 {
            broadcastToChannels("\r\n\u{1B}[33m— обрыв: \(reason) —\u{1B}[0m\r\n")
        }
        status = .closed
        nextRetryAt = Date().addingTimeInterval(delay)
        retryTask?.cancel()
        let gen = generation
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.nextRetryAt = nil
            self.teardownTransport()
            self.status = .idle
            self.connect(cols: self.channels.first?.cols ?? 80, rows: self.channels.first?.rows ?? 24)
        }
    }

    /// Немедленная попытка, минуя таймер бэкоффа (клавиша R / кнопка).
    /// Каждый вызов перевзводит ручную паузу автомата на 60с.
    func retryNow() {
        broadcastToChannels("\r\n\u{1B}[36m→ попытка подключения вручную…\u{1B}[0m\r\n")
        autoPausedUntil = Date().addingTimeInterval(60)
        nextRetryAt = nil
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        teardownTransport()
        status = .idle
        connect(cols: channels.first?.cols ?? 80, rows: channels.first?.rows ?? 24)
    }

    /// Рвём транспорт, но НЕ трогаем список вкладок — их каналы переоткроются.
    private func teardownTransport() {
        connectTask?.cancel()
        connectTask = nil
        for ch in channels { ch.detach() }
        let oldClient = client
        Task { try? await oldClient?.close() }
        client = nil
        sftp = nil
    }

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
        connect(cols: channels.first?.cols ?? 80, rows: channels.first?.rows ?? 24)
    }

    // MARK: - Teardown

    func disconnect() {
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        wasConnected = false
        retryAttempt = 0
        autoPausedUntil = nil
        nextRetryAt = nil
        attemptStartedAt = nil
        attemptNumber = 0
        teardownTransport()
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
