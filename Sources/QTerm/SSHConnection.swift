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
/// Несколько каналов мультиплексируются в одном соединении: логин, TOFU и
/// Touch ID происходят один раз на ноду, как в MobaXterm.
@MainActor
final class TerminalChannel: ObservableObject, Identifiable {
    let id = UUID()
    /// Номер вкладки для заголовка (1, 2, 3…). Присваивается соединением.
    @Published var index: Int = 1
    /// Заголовок из OSC 0/2, если шелл его прислал.
    @Published var title: String?
    /// Канал жив (PTY открыт).
    @Published var isLive = false
    /// Закрыт пользователем — такой канал не восстанавливается при реконнекте.
    var closedByUser = false

    var onOutput: ((ArraySlice<UInt8>) -> Void)?
    var onActivity: (() -> Void)?

    private var stdinWriter: TTYStdinWriter?
    var task: Task<Void, Never>?
    /// Последние размеры терминала — нужны при переоткрытии после реконнекта.
    var cols = 80
    var rows = 24

    var displayName: String {
        if let title, !title.isEmpty { return title }
        return "Вкладка \(index)"
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
        isLive = false
    }

    func write(_ text: String) {
        onOutput?(Array(text.utf8)[...])
    }

    /// Открывает shell+PTY и качает вывод до конца канала. Блокируется.
    func run(client: SSHClient, isCurrent: @escaping () -> Bool) async throws {
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
            self.isLive = true
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
/// Терминалы живут во вкладках-каналах поверх этого соединения.
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

    // MARK: - Вкладки

    @Published private(set) var channels: [TerminalChannel] = []
    @Published var activeChannelID: UUID?

    /// Активность любой вкладки (для маячка в сайдбаре).
    var onActivity: (() -> Void)?
    /// Служебные сообщения (обрывы, реконнект) — во все вкладки.
    private func broadcastNotice(_ text: String) {
        for ch in channels { ch.write(text) }
    }

    var activeChannel: TerminalChannel? {
        channels.first { $0.id == activeChannelID } ?? channels.first
    }

    /// Новая вкладка. Если соединение живое — открывается сразу.
    @discardableResult
    func openChannel(cols: Int = 80, rows: Int = 24) -> TerminalChannel {
        let ch = TerminalChannel()
        ch.cols = cols
        ch.rows = rows
        ch.index = (channels.map(\.index).max() ?? 0) + 1
        ch.onActivity = { [weak self] in self?.onActivity?() }
        channels.append(ch)
        activeChannelID = ch.id
        if status == .connected { startChannel(ch) }
        return ch
    }

    func closeChannel(_ id: UUID) {
        guard let idx = channels.firstIndex(where: { $0.id == id }) else { return }
        let ch = channels[idx]
        ch.closedByUser = true
        ch.task?.cancel()
        ch.detach()
        channels.remove(at: idx)
        if activeChannelID == id { activeChannelID = channels.last?.id }
        // Закрыли последнюю вкладку — рвём соединение ноды.
        if channels.isEmpty { disconnect() }
    }

    private func startChannel(_ ch: TerminalChannel) {
        guard let client else { return }
        let gen = generation
        ch.task = Task { [weak self] in
            guard let self else { return }
            do {
                try await ch.run(client: client) { gen == self.generation }
                self.channelEnded(ch, error: nil, gen: gen)
            } catch {
                self.channelEnded(ch, error: error, gen: gen)
            }
        }
    }

    /// Канал завершился. Если это не пользовательское закрытие и живых
    /// каналов не осталось — считаем соединение потерянным.
    private func channelEnded(_ ch: TerminalChannel, error: Error?, gen: Int) {
        guard gen == generation else { return }
        ch.detach()
        if ch.closedByUser { return }
        if channels.contains(where: { $0.isLive }) { return }
        status = .closed
        scheduleRetryIfNeeded(reason: error.map { String(describing: $0) } ?? "соединение закрыто")
    }

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

    init(sessionProvider: @escaping () -> Session, secrets: SecretStore) {
        self.sessionProvider = sessionProvider
        self.secrets = secrets
    }

    // MARK: - Connect

    func connect(cols: Int = 80, rows: Int = 24) {
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
                    reconnect: .never
                )
                guard gen == self.generation else { try? await client.close(); return }
                self.client = client

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

                // Поднимаем вкладки: существующие переоткрываем (скроллбек
                // сохраняется), если ни одной — создаём первую.
                if self.channels.isEmpty {
                    self.openChannel(cols: cols, rows: rows)
                } else {
                    for ch in self.channels { self.startChannel(ch) }
                }
            } catch {
                guard gen == self.generation else { return }
                let text = String(describing: error)
                self.attemptStartedAt = nil
                if self.wasConnected {
                    let short = text.count > 90 ? String(text.prefix(90)) + "…" : text
                    self.broadcastNotice("\u{1B}[31m✗ попытка не удалась: \(short)\u{1B}[0m\r\n")
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

    private func makeAuthMethod() throws -> SSHAuthenticationMethod {
        switch session.authMethod {
        case .password:
            guard let password = try secrets.get(for: session.id, kind: .password) else {
                throw ConnectionError.missingSecret("нет пароля в хранилище")
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
            _ = try Insecure.RSA.PrivateKey(sshRsa: keyText, decryptionKey: decryptionKey)
            throw ConnectionError.missingSecret("RSA-ключ (\(expanded)) — Citadel подписывает его как ssh-rsa, сервер такое не примет; укажи ed25519-ключ")

        case .agent:
            throw ConnectionError.missingSecret("agent-аутентификация — после MVP")
        }
    }

    // MARK: - Ввод (в активную вкладку)

    func sendToShell(_ data: ArraySlice<UInt8>) {
        activeChannel?.send(data)
    }

    /// Разослать во все вкладки этой ноды.
    func sendToAllChannels(_ data: ArraySlice<UInt8>) {
        for ch in channels where ch.isLive { ch.send(data) }
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
            broadcastNotice("\r\n\u{1B}[33m— обрыв: \(reason) —\u{1B}[0m\r\n")
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
            self.connect()
        }
    }

    /// Немедленная попытка, минуя таймер бэкоффа (клавиша R / кнопка).
    func retryNow() {
        broadcastNotice("\r\n\u{1B}[36m→ попытка подключения вручную…\u{1B}[0m\r\n")
        autoPausedUntil = Date().addingTimeInterval(60)
        nextRetryAt = nil
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        teardownTransport()
        status = .idle
        connect()
    }

    /// Закрыть транспорт, СОХРАНИВ вкладки (их переоткроет connect).
    private func teardownTransport() {
        connectTask?.cancel()
        for ch in channels {
            ch.task?.cancel()
            ch.detach()
        }
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
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        teardownTransport()
        status = .idle
        connect()
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
