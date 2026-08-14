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
        .commands {
            CommandGroup(after: .newItem) {
                Button("Новая вкладка") { state.duplicateActiveTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Закрыть вкладку") { state.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Следующая вкладка") { state.cycleTab(+1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Предыдущая вкладка") { state.cycleTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Вкладка \(n)") { state.selectTab(index: n - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
        }
    }
}

/// Режим ввода: обычный или во все подключённые ноды.
/// («во все вкладки одной ноды» смысла не имеет — это один и тот же сервер.)
enum BroadcastMode: String, CaseIterable {
    case off
    case allNodes

    var title: String {
        switch self {
        case .off: return "Обычный ввод"
        case .allNodes: return "Во все ноды"
        }
    }
}

/// Вкладка = нода + её канал. Лента вкладок общая на всё окно (как в MobaXterm).
struct Tab: Identifiable, Equatable {
    let id: UUID          // == channel.id
    let sessionID: UUID
}

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    /// Выделение в сайдбаре (что открывать), НЕ определяет показанный терминал.
    @Published var selectedSessionID: UUID?

    /// Общая лента вкладок и активная вкладка.
    @Published var tabs: [Tab] = []
    @Published var activeTabID: UUID?

    @Published var connections: [UUID: SSHConnection] = [:]
    /// Ноды с непросмотренным выводом (маячок в сайдбаре и на вкладке).
    @Published var unseenActivity: Set<UUID> = []
    @Published var broadcastMode: BroadcastMode = .off

    /// Живые экраны терминалов по вкладке (channel.id).
    var terminals: [UUID: TerminalView] = [:]
    @Published var vaultError: String?
    @Published var snippets: [Snippet] = []

    let store = SessionStore()
    lazy var secrets = SecretStore(store: store)
    private var connectionSubs: [UUID: AnyCancellable] = [:]

    init() {
        loadVault()
    }

    // MARK: - Вкладки

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    /// Нода активной вкладки — по ней подсвечивается строка в сайдбаре.
    var activeSessionID: UUID? {
        activeTab?.sessionID
    }

    /// Клик по ноде в сайдбаре: если вкладки открыты — активируем первую,
    /// если нет — просто выделяем (коннект только двойным кликом).
    func focusNode(_ session: Session) {
        selectedSessionID = session.id
        if let first = tabs.first(where: { $0.sessionID == session.id }) {
            activeTabID = first.id
            markSeen(session.id)
        }
    }

    /// Закрыть все вкладки ноды (дисконнект + вкладки уходят из ленты).
    func closeAllTabs(for sessionID: UUID) {
        for tab in tabs where tab.sessionID == sessionID {
            terminals.removeValue(forKey: tab.id)
        }
        tabs.removeAll { $0.sessionID == sessionID }
        connections[sessionID]?.disconnect()
        connections[sessionID] = nil
        connectionSubs[sessionID] = nil
        if activeTabID != nil, !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
        }
    }

    func session(for tab: Tab) -> Session? {
        sessions.first { $0.id == tab.sessionID }
    }

    func channel(for tab: Tab) -> TerminalChannel? {
        connections[tab.sessionID]?.channels.first { $0.id == tab.id }
    }

    /// Заголовок вкладки: имя ноды, а при нескольких вкладках — с #N.
    func title(for tab: Tab) -> String {
        let name = session(for: tab)?.name ?? "?"
        let sameNode = tabs.filter { $0.sessionID == tab.sessionID }
        guard sameNode.count > 1, let idx = sameNode.firstIndex(of: tab) else { return name }
        return "\(name) #\(idx + 1)"
    }

    /// Открыть новую вкладку для ноды (двойной клик в сайдбаре, ⌘T, «+»).
    @discardableResult
    func openTab(for session: Session) -> Tab {
        let conn = connection(for: session)
        // Первый канал соединения ещё не занят вкладкой — используем его.
        let free = conn.channels.first { ch in !tabs.contains { $0.id == ch.id } }
        let ch = free ?? conn.addChannel()
        let tab = Tab(id: ch.id, sessionID: session.id)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func duplicateActiveTab() {
        guard let tab = activeTab, let s = session(for: tab) else { return }
        openTab(for: s)
    }

    func closeActiveTab() {
        guard let tab = activeTab else { return }
        close(tab)
    }

    func close(_ tab: Tab) {
        guard let conn = connections[tab.sessionID] else { return }
        terminals.removeValue(forKey: tab.id)
        if let ch = conn.channels.first(where: { $0.id == tab.id }) {
            conn.closeChannel(ch)
        }
        let wasActive = activeTabID == tab.id
        let idx = tabs.firstIndex(of: tab)
        tabs.removeAll { $0.id == tab.id }

        // Последняя вкладка ноды закрыта — рвём её соединение.
        if !tabs.contains(where: { $0.sessionID == tab.sessionID }) {
            conn.disconnect()
            connections[tab.sessionID] = nil
            connectionSubs[tab.sessionID] = nil
        }
        if wasActive {
            let next = min(idx ?? 0, max(tabs.count - 1, 0))
            activeTabID = tabs.indices.contains(next) ? tabs[next].id : nil
        }
    }

    func cycleTab(_ delta: Int) {
        guard !tabs.isEmpty, let cur = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let next = (cur + delta + tabs.count) % tabs.count
        activeTabID = tabs[next].id
    }

    func selectTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
        markSeen(tabs[index].sessionID)
    }

    /// Перетаскивание вкладок: живые терминалы не пересоздаются — они лежат
    /// в реестре по channel.id, меняется только порядок в ленте.
    func moveTab(id: UUID, before targetID: UUID?) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let moved = tabs.remove(at: from)
        if let targetID, let to = tabs.firstIndex(where: { $0.id == targetID }) {
            tabs.insert(moved, at: to)
        } else {
            tabs.append(moved)
        }
    }

    // MARK: - Ввод

    /// Во все подключённые ноды — по одной (активной или первой) вкладке на ноду.
    func sendToAllConnected(_ data: ArraySlice<UInt8>) {
        var visited = Set<UUID>()
        // Активная вкладка ноды имеет приоритет.
        if let active = activeTab {
            channel(for: active)?.send(data)
            visited.insert(active.sessionID)
        }
        for tab in tabs where !visited.contains(tab.sessionID) {
            guard connections[tab.sessionID]?.status == .connected else { continue }
            channel(for: tab)?.send(data)
            visited.insert(tab.sessionID)
        }
    }

    // MARK: - Вейлт

    func loadVault() {
        do {
            let vault = try store.initializeIfNeeded()
            sessions = vault.sessions
            snippets = vault.snippets ?? []
            vaultError = nil
        } catch {
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
        for tab in tabs where tab.sessionID == session.id {
            terminals.removeValue(forKey: tab.id)
        }
        tabs.removeAll { $0.sessionID == session.id }
        if activeTabID != nil && !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
        }
        connections[session.id]?.disconnect()
        connections[session.id] = nil
        connectionSubs[session.id] = nil
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
            guard let self else { return }
            // Маячок, если активная вкладка сейчас не на этой ноде.
            if self.activeTab?.sessionID != id {
                self.unseenActivity.insert(id)
            }
        }
        connectionSubs[id] = conn.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        connections[session.id] = conn
        return conn
    }

    func markSeen(_ id: UUID?) {
        if let id { unseenActivity.remove(id) }
    }

    /// Активная вкладка сменилась — её нода считается просмотренной.
    func didActivateTab() {
        markSeen(activeTab?.sessionID)
    }

    /// Очистка активного терминала: локально, работает и при обрыве.
    /// includeScrollback = false — только видимый экран (как clear),
    /// true — экран и весь скроллбек.
    func clearActiveTerminal(includeScrollback: Bool) {
        guard let tab = activeTab, let tv = terminals[tab.id] else { return }
        let terminal = tv.getTerminal()
        if includeScrollback {
            // ESC[3J вычищает скроллбек, ESC[2J — экран, ESC[H — курсор домой.
            terminal.feed(text: "\u{1B}[3J\u{1B}[2J\u{1B}[H")
        } else {
            terminal.feed(text: "\u{1B}[2J\u{1B}[H")
        }
        tv.needsDisplay = true
        // Промпт перерисовать сразу — иначе остаётся чёрный экран до Enter.
        if connections[tab.sessionID]?.status == .connected {
            channel(for: tab)?.send(Array("\n".utf8)[...])
        }
    }
}
