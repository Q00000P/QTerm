import SwiftUI
import SwiftTerm
import Combine
import SessionVaultKit

@main
struct QTermApp: App {
    @StateObject private var state = AppState()

    private var titleString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "QTerm \(v) (\(b))"
    }

    var body: some Scene {
        WindowGroup(titleString) {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowStyle(.titleBar)
    }
}

/// Central app state: session list (from encrypted vault) + active
/// connections keyed by session id. One connection per session for MVP;
/// tabs/multi-connect later.
@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selectedSessionID: UUID?
    @Published var connections: [UUID: SSHConnection] = [:]
    /// Сессии с непросмотренным выводом (маячок в сайдбаре).
    @Published var unseenActivity: Set<UUID> = []
    /// Сквозной ввод: печать в активном терминале уходит во все подключённые сессии.
    @Published var broadcastInput = false

    /// Разослать байты во все подключённые сессии (для сквозного ввода и сниппетов).
    func sendToAllConnected(_ data: ArraySlice<UInt8>) {
        for conn in connections.values where conn.status == .connected {
            conn.sendToShell(data)
        }
    }
    /// Живые экраны терминалов: создаются один раз на сессию и переживают
    /// переключения между сессиями (буфер/скроллбек сохраняются).
    var terminals: [UUID: TerminalView] = [:]
    @Published var vaultError: String?
    /// Избранные команды из вейлта.
    @Published var snippets: [Snippet] = []

    let store = SessionStore()
    lazy var secrets = SecretStore(store: store)
    /// Подписки на вложенные ObservableObject (SSHConnection): без них
    /// сайдбар не перерисовывается при смене статуса соединения.
    private var connectionSubs: [UUID: AnyCancellable] = [:]

    init() {
        loadVault()
    }

    func loadVault() {
        do {
            let vault = try store.initializeIfNeeded()
            sessions = vault.sessions
            snippets = vault.snippets ?? []
            vaultError = nil
        } catch {
            // Touch ID отменён / SE недоступен / битый файл — показываем
            // и даём кнопку "повторить" в UI, не падаем.
            vaultError = "Не удалось открыть хранилище: \(error)"
        }
    }

    func addSnippet(title: String, command: String) {
        snippets.append(Snippet(title: title, command: command))
        persistSnippets()
    }

    func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        persistSnippets()
    }

    private func persistSnippets() {
        do { try store.save(snippets: snippets) }
        catch { vaultError = "Не удалось сохранить сниппеты: \(error)" }
    }

    func persist() {
        do {
            try store.save(sessions: sessions)
        } catch {
            vaultError = "Не удалось сохранить хранилище: \(error)"
        }
    }

    func upsert(_ session: Session) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        persist()
    }

    func delete(_ session: Session) {
        connections[session.id]?.disconnect()
        connections[session.id] = nil
        connectionSubs[session.id] = nil
        terminals.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }
        secrets.deleteAll(for: session.id)
        persist()
    }

    func connection(for session: Session) -> SSHConnection {
        if let existing = connections[session.id] { return existing }
        let id = session.id
        let conn = SSHConnection(sessionProvider: { [weak self] in
            self?.sessions.first(where: { $0.id == id }) ?? session
        }, secrets: secrets)
        conn.onActivity = { [weak self] in
            guard let self, self.selectedSessionID != id else { return }
            self.unseenActivity.insert(id)
        }
        // Пробрасываем изменения внутри соединения наверх — иначе точки
        // статуса в сайдбаре обновляются только при переключении сессий.
        connectionSubs[id] = conn.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        connections[session.id] = conn
        return conn
    }

    /// Выбор сессии гасит её маячок активности.
    func markSeen(_ id: UUID?) {
        if let id { unseenActivity.remove(id) }
    }
}
