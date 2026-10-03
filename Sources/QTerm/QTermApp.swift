import SwiftUI
import AppKit
import SwiftTerm
import Combine
import SessionVaultKit

/// Делегат приложения: меню в доке (правый клик по иконке) — оттуда
/// поднимается окно редактора. Своей иконки в доке у вспомогательного окна
/// macOS не даёт, поэтому пункт живёт в док-меню основного приложения.
final class QTermAppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Окно редактора",
            action: #selector(openEditor),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @MainActor
    @objc private func openEditor() {
        state?.editor.focusEditor()
    }
}

@main
struct QTermApp: App {
    @NSApplicationDelegateAdaptor(QTermAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow
    /// Сочетания клавиш: меню перестраивается при их изменении.
    @StateObject private var hotkeys = Hotkeys.shared

    init() {
        // macOS 27 + русская локаль: CoreUI валит приложение при отрисовке
        // SF Symbols в NSAlert, если в процессе числовая локаль с запятой
        // (разбор SVG даёт символ 0×0). Числа — только в «C».
        setlocale(LC_NUMERIC, "C")
    }

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
        .defaultSize(width: 1440, height: 860)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("О QTerm") { state.showAbout = true }
            }
            CommandGroup(after: .appSettings) {
                Button("Горячие клавиши…") { state.performHotkey("hotkeys") }
                    .keyboardShortcut(hotkeys.shortcut("hotkeys"))
            }
            CommandMenu("Данные") {
                Button("Импорт из MobaXterm…") { state.importFromMoba() }
                Button("Экспорт в MobaXterm…") { state.exportToMoba() }
                Divider()
                Button("Ключи…") { state.showKeyManager = true }
                Button("Локальный терминал") { state.performHotkey("local") }
                    .keyboardShortcut(hotkeys.shortcut("local"))
                Divider()
                Button("Команды Git…") { state.performHotkey("git") }
                    .keyboardShortcut(hotkeys.shortcut("git"))
                Button("Сниппеты…") { state.performHotkey("snippets") }
                    .keyboardShortcut(hotkeys.shortcut("snippets"))
                Button("Синхронизация…") { state.showSyncSettings = true }
                Button("Синхронизировать сейчас") { state.performHotkey("sync") }
                    .keyboardShortcut(hotkeys.shortcut("sync"))
                Button("Журнал команд…") { state.performHotkey("journal") }
                    .keyboardShortcut(hotkeys.shortcut("journal"))
                Button("Импортировать ключ в хранилище…") { state.importKeyFile() }
                Button("Назначить ключ нодам без ключа…") { state.assignKeyToOrphans() }
                Button("Задать passphrase ключа…") { state.setKeyPassphrase() }
                Divider()
                Button("Экспорт вейлта в файл…") { state.exportVaultToFile() }
                Button("Импорт вейлта из файла…") { state.importVaultFromFile() }
            }
            CommandGroup(after: .newItem) {
                Button("Новая нода…") { state.performHotkey("newnode") }
                    .keyboardShortcut(hotkeys.shortcut("newnode"))
                Button("Редактор") { state.performHotkey("qeditor") }
                    .keyboardShortcut(hotkeys.shortcut("qeditor"))
                Divider()
                Button("Новая вкладка") { state.performHotkey("dup") }
                    .keyboardShortcut(hotkeys.shortcut("dup"))
                // Редактор — отдельное приложение, своё ⌘W у него своё.
                Button("Закрыть вкладку") { state.performHotkey("close") }
                    .keyboardShortcut(hotkeys.shortcut("close"))
                Divider()
                Button("Следующая вкладка") { state.performHotkey("next") }
                    .keyboardShortcut(hotkeys.shortcut("next"))
                Button("Предыдущая вкладка") { state.performHotkey("prev") }
                    .keyboardShortcut(hotkeys.shortcut("prev"))
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Вкладка \(n)") { state.performHotkey("tab\(n)") }
                        .keyboardShortcut(hotkeys.shortcut("tab\(n)"))
                }
            }
            CommandMenu("Терминал") {
                Button("Очистить экран") { state.performHotkey("clear") }
                    .keyboardShortcut(hotkeys.shortcut("clear"))
                Button("Очистить экран и скроллбек") { state.performHotkey("clearAll") }
                    .keyboardShortcut(hotkeys.shortcut("clearAll"))
                Divider()
                Button(state.broadcastMode == .off ? "Включить «Во все ноды»" : "Выключить «Во все ноды»") {
                    state.performHotkey("broadcast")
                }
                .keyboardShortcut(hotkeys.shortcut("broadcast"))
                Button("Переподключить ноду") { state.performHotkey("reconnect") }
                    .keyboardShortcut(hotkeys.shortcut("reconnect"))
                Button(state.showFiles ? "Скрыть файлы" : "Показать файлы") { state.performHotkey("files") }
                    .keyboardShortcut(hotkeys.shortcut("files"))
            }
        }

        // Настройки (⌘,) — стандартное маковское окно.
        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

/// Режим ввода: обычный или во все подключённые ноды.
/// («во все вкладки одной ноды» смысла не имеет — это один и тот же сервер.)
enum BroadcastMode: String, CaseIterable {
    case off
    /// WYSIWYG (канон Windows): печать в активную, по Enter видимая строка
    /// целиком уходит в остальные ноды; ^C — во все.
    case allNodes
    /// Каждое нажатие во все ноды (пароли sudo, TUI-программы).
    case allKeys

    var title: String {
        switch self {
        case .off: return "Обычный ввод"
        case .allNodes: return "Во все ноды (по Enter)"
        case .allKeys: return "Во все ноды (посимвольно)"
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
    /// Окна/листы, которые открываются и горячими клавишами.
    @Published var showAddSession = false
    @Published var showSnippetEditor = false
    @Published var showAbout = false
    /// Панель файлов справа (переключается горячей клавишей, запоминается).
    @Published var showFiles = UserDefaults.standard.object(forKey: "showFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showFiles, forKey: "showFiles") }
    }

    /// Живые экраны терминалов по вкладке (channel.id).
    var terminals: [UUID: TerminalView] = [:]
    /// Живые проводники по ноде (session.id): путь и листинг переживают
    /// переключение нод, сбрасываются только с закрытием всех вкладок ноды.
    var browsers: [UUID: SFTPBrowser] = [:]

    func browser(for connection: SSHConnection) -> SFTPBrowser {
        let id = connection.session.id
        if let existing = browsers[id] { return existing }
        let b = SFTPBrowser(connection: connection)
        browsers[id] = b
        return b
    }
    @Published var vaultError: String?
    /// Экран управления ключами (Данные → Ключи…).
    @Published var showKeyManager = false
    @Published var snippets: [Snippet] = []
    /// Команды с Git (имя / команда / заметка), синкаются как "gitCommands".
    @Published var gitCommands: [GitCommand] = []
    @Published var showGitCommands = false
    /// Псевдо-нода «Локальный терминал» (в вейлт и синк НЕ пишется).
    static let localSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000700C")!
    /// Живые вьюхи локальных терминалов по вкладке.
    var localTerminals: [UUID: TrackedLocalTerminalView] = [:]

    /// Журнал СЕРВЕРНЫХ команд (легаси-имя, синкается; кап 500).
    @Published var cmdHistory: [String: CmdStat] = [:]
    /// Журналы по скоупам: "mac" — локальный терминал (синкается отдельно).
    @Published var cmdScopes: [String: [String: CmdStat]] = [:]
    /// Пользовательский словарь (добавления/скрытия, синкается).
    @Published var cmdDictUser: [String: DictEntry] = [:]
    /// Панель: показать журнал другого мира (по клику ⇄).
    @Published var crossScopeShown = false
    /// Восстановление набираемой строки активной вкладки.
    let cmdTracker = CommandTracker()
    /// Префикс набора для полосы подсказок (зеркало трекера).
    @Published var cmdPrefix = ""
    /// Выделенная строка панели подсказок (-1 = нет).
    @Published var suggestionSelection = -1
    /// Панель закрыта по Esc — до следующего изменения набора.
    @Published var suggestionsSuppressed = false
    /// Диагностика: трекер потерял строку (стрелки/Tab) — ждёт Enter/^C/^U.
    @Published var trackerDirty = false
    /// Приватные ключи из вейлта.
    @Published var sshKeys: [SSHKey] = []

    let store = SessionStore()
    lazy var secrets = SecretStore(store: store)
    private var connectionSubs: [UUID: AnyCancellable] = [:]

    /// Мост к отдельному приложению-редактору QTermEditor.app.
    lazy var editor: EditorBridge = {
        let e = EditorBridge()
        e.app = self
        return e
    }()

    /// Синк вейлта (WebDAV, QTS1 — общий формат с Android).
    lazy var syncEngine: SyncEngine = {
        let e = SyncEngine(store: store)
        e.app = self
        return e
    }()
    @Published var showSyncSettings = false
    @Published var showCommandLog = false

    /// Живые записи (tombstones скрыты, но синкаются).
    var visibleSessions: [Session] { sessions.filter { $0.deleted != true } }
    var visibleKeys: [SSHKey] { sshKeys.filter { $0.deleted != true } }
    var visibleSnippets: [Snippet] { snippets.filter { $0.deleted != true } }

    static func nowISO() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    init() {
        loadVault()
        TerminalLook.install(self)
    }

    // MARK: - Вкладки

    func noteActiveTabChanged() {
        cmdTracker.reset()
        crossScopeShown = false
    }

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
        browsers[sessionID]?.stopWatchers()
        browsers.removeValue(forKey: sessionID)
        tabs.removeAll { $0.sessionID == sessionID }
        connections[sessionID]?.disconnect()
        connections[sessionID] = nil
        connectionSubs[sessionID] = nil
        if activeTabID != nil, !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
        }
    }

    /// Кнопка «закрыть все вкладки»: с подтверждением, рвёт все соединения.
    func confirmCloseAllTabs() {
        guard !tabs.isEmpty else { return }
        let nodeCount = Set(tabs.map(\.sessionID)).count
        let alert = NSAlert()
        alert.messageText = "Закрыть все вкладки?"
        alert.informativeText = "Вкладок: \(tabs.count), нод: \(nodeCount). Все соединения будут разорваны."
        alert.addButton(withTitle: "Закрыть все")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for id in Set(tabs.map(\.sessionID)) {
            closeAllTabs(for: id)
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
        if tab.sessionID == Self.localSessionID { return "Mac" }
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
        if tab.sessionID == Self.localSessionID {
            localTerminals[tab.id]?.process.terminate()
            localTerminals.removeValue(forKey: tab.id)
            let wasActive = activeTabID == tab.id
            tabs.removeAll { $0.id == tab.id }
            if wasActive { activeTabID = tabs.last?.id }
            return
        }
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
            browsers[tab.sessionID]?.stopWatchers()
            browsers.removeValue(forKey: tab.sessionID)
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

    /// Остальные подключённые ноды (кроме ноды активной вкладки) — по одной
    /// вкладке на ноду, как sendToAllConnected. Для WYSIWYG-броадкаста.
    func sendToOtherNodes(_ text: String) {
        guard let active = activeTab else { return }
        let bytes = Array(text.utf8)[...]
        var visited: Set<UUID> = [active.sessionID, Self.localSessionID]
        for tab in tabs where !visited.contains(tab.sessionID) {
            guard connections[tab.sessionID]?.status == .connected else { continue }
            channel(for: tab)?.send(bytes)
            visited.insert(tab.sessionID)
        }
    }

    /// Шелл сообщил папку (заголовок «user@host: путь» или OSC 7) —
    /// панель файлов ноды идёт следом, если включено и вкладка активна.
    func noteTerminalCwd(tabID: UUID, sessionID: UUID, raw: String, osc7: Bool) {
        guard activeTabID == tabID else { return }
        browsers[sessionID]?.followTerminal(raw: raw, osc7: osc7)
    }

    // MARK: - Горячие клавиши

    func performHotkey(_ id: String) {
        switch id {
        case "git": showGitCommands = true
        case "snippets": showSnippetEditor = true
        case "journal": showCommandLog = true
        case "clear": clearActiveTerminal(includeScrollback: false)
        case "clearAll": clearActiveTerminal(includeScrollback: true)
        case "broadcast": broadcastMode = broadcastMode == .off ? .allNodes : .off
        case "reconnect":
            if let tab = activeTab, tab.sessionID != Self.localSessionID {
                connections[tab.sessionID]?.reconnect()
            }
        case "files": showFiles.toggle()
        case "dup": duplicateActiveTab()
        case "close": closeActiveTab()
        case "next": cycleTab(+1)
        case "prev": cycleTab(-1)
        case "local": openLocalTab()
        case "newnode": showAddSession = true
        case "sync": Task { await syncEngine.syncNow() }
        case "qeditor": editor.focusEditor()
        case "hotkeys":
            UserDefaults.standard.set("hotkeys", forKey: "settingsTab")
            _ = NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default:
            if id.hasPrefix("tab"), let n = Int(id.dropFirst(3)), (1...9).contains(n) {
                selectTab(index: n - 1)
                return
            }
            return
        }
        if ["clear", "clearAll", "broadcast", "reconnect", "files", "dup", "next", "prev"].contains(id) {
            focusActiveTerminal()
        }
    }

    // MARK: - Вейлт

    func loadVault() {
        cmdTracker.onLineStart = { [weak self] in self?.anchorInputLine() }
        cmdTracker.onCommand = { [weak self] typed, dirty in
            self?.commitCommand(typed: typed, dirty: dirty)
        }
        cmdTracker.onStateChange = { [weak self] p, dirty in
            guard let self else { return }
            if trackerDirty != dirty { trackerDirty = dirty }
            if cmdPrefix != p {
                if p.isEmpty { crossScopeShown = false }
                cmdPrefix = p
                suggestionSelection = -1
                suggestionsSuppressed = false
            }
        }
        do {
            let vault = try store.initializeIfNeeded()
            sessions = vault.sessions
            snippets = vault.snippets ?? []
            gitCommands = vault.gitCommands ?? []
            sshKeys = vault.sshKeys ?? []
            cmdHistory = vault.cmdHistory ?? [:]
            cmdScopes = vault.cmdHistoryScopes ?? [:]
            cmdDictUser = vault.cmdDictUser ?? [:]
            vaultError = nil
            sanitizeJournals()
        } catch {
            vaultError = "Не удалось открыть хранилище: \(error)"
        }
    }

    struct CommandSuggestion { let text: String; let personal: Bool }

    var isLocalTab: Bool { activeTab?.sessionID == Self.localSessionID }
    /// Скоуп журнала активной вкладки: локальная — "mac", SSH — сервер (легаси).
    var activeScopeIsMac: Bool { isLocalTab }
    var otherScopeName: String { activeScopeIsMac ? "серверов" : "мака" }

    private func history(mac: Bool) -> [String: CmdStat] {
        mac ? (cmdScopes["mac"] ?? [:]) : cmdHistory
    }

    private func builtinDict(mac: Bool) -> [String] {
        mac ? CommandDict.mac : CommandDict.common
    }

    /// Словарь скоупа: встроенный минус скрытые + пользовательские записи.
    private func effectiveDict(mac: Bool) -> [String] {
        let scopeName = mac ? "mac" : "server"
        var set = Set(builtinDict(mac: mac))
        for (cmd, e) in cmdDictUser {
            let inScope = (e.scope ?? "both") == "both" || e.scope == scopeName
            if e.deleted == true {
                set.remove(cmd)
            } else if inScope {
                set.insert(cmd)
            }
        }
        return Array(set)
    }

    func openLocalTab() {
        let tab = Tab(id: UUID(), sessionID: Self.localSessionID)
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Клик по строке «Mac» в сайдбаре: перейти к существующей локальной
    /// вкладке или открыть первую. Двойной клик не плодит дубли —
    /// новые вкладки через ⌘L или «Дублировать».
    func focusOrOpenLocalTab() {
        if let existing = tabs.last(where: { $0.sessionID == Self.localSessionID }) {
            activeTabID = existing.id
        } else {
            openLocalTab()
        }
    }

    /// Терминал вкладки независимо от типа (для панели подсказок).
    func anyTerminal(for tab: Tab) -> TerminalView? {
        if tab.sessionID == Self.localSessionID { return localTerminals[tab.id] }
        return terminals[tab.id]
    }

    func terminalGrid(for tab: Tab) -> (cols: Int, rows: Int) {
        if tab.sessionID == Self.localSessionID,
           let t = localTerminals[tab.id]?.getTerminal() {
            return (t.cols, t.rows)
        }
        if let ch = channel(for: tab) { return (ch.cols, ch.rows) }
        return (80, 24)
    }

    /// Похоже ли на shell-команду. Отсекает ввод в интерактивные программы:
    /// пункты меню («28»), y/n-ответы, числа, пароли из спецсимволов.
    // MARK: - Что пускать в журнал

    /// Запись отвергается: не похоже на команду, похоже на секрет, или это
    /// кусок кода/портянки (слишком длинно).
    static func journalRejects(_ cmd: String) -> Bool {
        cmd.count > 250 || !isLikelyCommand(cmd) || looksSensitive(cmd)
    }

    /// Секреты в командной строке: пароли/токены в аргументах, ключи,
    /// ссылки прокси с учётками, длинные «случайные» строки.
    static func looksSensitive(_ cmd: String) -> Bool {
        if cmd.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return true }
        let lower = cmd.lowercased()
        if lower.contains("private key") || lower.contains("-----begin") { return true }
        let patterns = [
            // pass=…, password: …, token=…, api_key=…, secret=…
            #"(?i)(pass(word|wd|phrase)?|pwd|token|secret|api[_-]?key|access[_-]?key|private[_-]?key|auth[a-z_-]*|bearer|cookie)\s*[=:]\s*\S"#,
            #"(?i)\bbearer\s+\S{8,}"#,
            #"(?i)authorization\s*:"#,
            // mysql -pСЕКРЕТ, sshpass, echo … | chpasswd
            #"(?i)\b(mysql|mariadb|mysqladmin|mysqldump|mysqlsh)\b.*\s-p\S"#,
            #"(?i)\bsshpass\b"#,
            #"(?i)\|\s*(sudo\s+)?(chpasswd|passwd)\b"#,
            // --password X, --token=X, openssl -pass pass:X
            #"(?i)--(password|passwd|pass|token|secret|api-key|apikey|auth-key|private-key)[= ]\S"#,
            #"(?i)-pass(in|out)?\s+(pass|env|file):"#,
            // export SOME_TOKEN=…
            #"(?i)\bexport\s+\w*(key|token|secret|pass|pwd)\w*\s*="#,
            // схема://user:pass@host и ссылки прокси (в них UUID/ключи — это учётки)
            #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"#,
            #"(?i)\b(vless|vmess|trojan|ss|ssr|hysteria2?|hy2|tuic|anytls)://"#,
            // JWT
            #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
        ]
        for p in patterns where cmd.range(of: p, options: .regularExpression) != nil { return true }
        // Длинные случайные токены: base64-ключи WG/Reality, пароли, bot-токены.
        // Hex-хэши (строчные) и пути не трогаем.
        for word in cmd.split(whereSeparator: { " \t'\"=,;".contains($0) }) where word.count >= 16 {
            if word.hasPrefix("/") || word.hasPrefix("~") || word.hasPrefix("./") || word.contains(".") { continue }
            // Читаемые имена режутся дефисами/подчёркиваниями на короткие куски
            // (QTermAndroid-icons-v2), ключи и токены — сплошные.
            for part in word.split(whereSeparator: { "-_".contains($0) }) where part.count >= 16 {
                let upper = part.contains(where: \.isUppercase)
                let lowerCase = part.contains(where: \.isLowercase)
                let digit = part.contains(where: \.isNumber)
                if upper && lowerCase && digit { return true }
                // Длинный hex (секреты MTProxy, ключи): хэши коммитов в журнале
                // тоже ни к чему — повторять их не придётся.
                if part.count >= 32 && part.allSatisfy(\.isHexDigit) { return true }
            }
        }
        return false
    }

    // MARK: - Сверка команды с экраном

    /// Где на экране начался ввод строки: абсолютная строка буфера,
    /// колонка и текст промпта перед ней.
    private struct LineAnchor {
        let tabID: UUID
        let row: Int
        let col: Int
        let prompt: String
    }
    private var lineAnchor: LineAnchor?

    /// Абсолютная (с учётом обрезанного скроллбека) строка курсора. Число строк
    /// буфера SwiftTerm не публикует — находим последнюю поиском; активный
    /// экран — последние rows строк.
    private static func cursorInvariantRow(_ t: Terminal) -> Int {
        let base = t.buffer.totalLinesTrimmed
        var lo = base
        var hi = base + t.rows
        var step = 256
        while t.getScrollInvariantLine(row: hi) != nil {
            lo = hi
            hi += step
            step *= 2
        }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if t.getScrollInvariantLine(row: mid) != nil { lo = mid } else { hi = mid }
        }
        return lo - (t.rows - 1) + t.buffer.y
    }

    /// Первый байт новой строки: запоминаем, где стоит курсор (конец промпта).
    private func anchorInputLine() {
        guard let tab = activeTab, let tv = anyTerminal(for: tab) else { lineAnchor = nil; return }
        let t = tv.getTerminal()
        guard !t.isCurrentBufferAlternate else { lineAnchor = nil; return }
        let row = Self.cursorInvariantRow(t)
        let col = t.buffer.x
        let prompt = t.getScrollInvariantLine(row: row)?
            .translateToString(trimRight: false, startCol: 0, endCol: col) ?? ""
        lineAnchor = LineAnchor(tabID: tab.id, row: row, col: col, prompt: prompt)
    }

    private struct SeenLine {
        let prompt: String
        /// От якоря до курсора — то, что эхом вернул шелл.
        let toCursor: String
        /// Вся строка ввода (переносы склеены, правый промпт отрезан).
        let line: String
        /// Строка ввода из нескольких экранных строк без переноса —
        /// многострочный буфер (heredoc, продолжение).
        let multiLine: Bool
    }

    /// Видимая командная строка активной вкладки (WYSIWYG-броадкаст):
    /// от якоря начала ввода (переносы склеены, RPROMPT отрезан), а без
    /// якоря — как на винде: строка курсора с переносами, промпт срезается
    /// по последнему «# »/«$ »/«% ». Пустая, alt-screen (vim/mc) — nil.
    func visibleCommandLine() -> String? {
        guard let tab = activeTab, let tv = anyTerminal(for: tab) else { return nil }
        let t = tv.getTerminal()
        guard !t.isCurrentBufferAlternate else { return nil }
        if let a = lineAnchor, a.tabID == tab.id,
           let seen = readInputLine(a, t), seen.prompt == a.prompt {
            return seen.line.isEmpty ? nil : seen.line
        }
        var row = Self.cursorInvariantRow(t)
        while row > t.buffer.totalLinesTrimmed,
              let l = t.getScrollInvariantLine(row: row), l.isWrapped { row -= 1 }
        var text = ""
        while let l = t.getScrollInvariantLine(row: row) {
            guard let next = t.getScrollInvariantLine(row: row + 1), next.isWrapped else {
                text += l.translateToString(trimRight: true)
                break
            }
            text += l.translateToString(trimRight: false)
            row += 1
        }
        text = text.replacingOccurrences(of: "\u{0}", with: "")
        guard let m = text.range(of: #"^[\s\S]*[#$%]\s+"#, options: .regularExpression) else { return nil }
        let cmd = text[m.upperBound...].trimmingCharacters(in: .whitespaces)
        return cmd.isEmpty ? nil : cmd
    }

    private func readInputLine(_ a: LineAnchor, _ t: Terminal) -> SeenLine? {
        let curRow = Self.cursorInvariantRow(t)
        let curCol = t.buffer.x
        guard curRow >= a.row, curRow - a.row <= 50,
              let first = t.getScrollInvariantLine(row: a.row) else { return nil }
        let prompt = first.translateToString(trimRight: false, startCol: 0, endCol: a.col)
        var toCursor = ""
        var line = ""
        var multiLine = false
        var r = a.row
        while let bl = t.getScrollInvariantLine(row: r) {
            let start = r == a.row ? a.col : 0
            if r < curRow {
                toCursor += bl.translateToString(trimRight: false, startCol: start)
            } else if r == curRow {
                toCursor += bl.translateToString(trimRight: false, startCol: start, endCol: max(start, curCol))
            }
            guard let next = t.getScrollInvariantLine(row: r + 1),
                  r + 1 <= curRow || next.isWrapped, r + 1 - a.row <= 50 else {
                line += bl.translateToString(trimRight: true, startCol: start)
                break
            }
            if !next.isWrapped { multiLine = true }
            line += bl.translateToString(trimRight: false, startCol: start)
            r += 1
        }
        // Правый промпт (RPROMPT zsh) — короткий хвост после длинной пустоты.
        if let gap = line.range(of: "    ", options: .backwards) {
            let tail = line[gap.upperBound...].trimmingCharacters(in: .whitespaces)
            if tail.count <= 40 { line = String(line[..<gap.lowerBound]) }
        }
        line = line.replacingOccurrences(of: "\u{0}", with: "")
        return SeenLine(prompt: prompt, toCursor: toCursor,
                        line: line.trimmingCharacters(in: .whitespaces), multiLine: multiLine)
    }

    /// Промпт шелла, а не запрос программы: пустой (ввод в cat/heredoc без
    /// PS2), запросы учёток и вопросов, строки продолжения — не шелл.
    static func isShellPrompt(_ prompt: String) -> Bool {
        let p = prompt.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        let lower = p.lowercased()
        let credentialWords = ["password", "passphrase", "пароль", "passcode", "token", "secret", "verification", "otp"]
        if credentialWords.contains(where: { lower.contains($0) }) { return false }
        if let last = p.last, ":?".contains(last) { return false }
        let questionMarks = ["[y/n]", "(y/n)", "[yes/no]", "(yes/no", "[д/н]"]
        if questionMarks.contains(where: { lower.contains($0) }) { return false }
        // "> ", "quote> ", "heredoc> ", ">>> " — продолжение строки / REPL.
        if p.range(of: #"^[A-Za-z ]*>+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    private static func squeeze(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !CharacterSet.whitespaces.contains($0) && $0.value != 0
        }))
    }

    /// Enter: решаем, что писать в журнал — по экрану, а не по нажатиям.
    /// Пароль не отображается эхом → на экране пусто/звёздочки → мимо.
    /// Строка, правленая стрелками/историей, берётся с экрана как есть.
    private func commitCommand(typed: String, dirty: Bool) {
        let anchor = lineAnchor
        lineAnchor = nil
        guard let tab = activeTab, let tv = anyTerminal(for: tab),
              let a = anchor, a.tabID == tab.id else { return }
        let t = tv.getTerminal()
        guard !t.isCurrentBufferAlternate,                 // vim, less, mc, htop
              let seen = readInputLine(a, t),
              seen.prompt == a.prompt,                     // экран не уехал/не очищен
              Self.isShellPrompt(a.prompt) else { return }
        let cmd: String
        if dirty {
            guard !seen.multiLine, !seen.line.isEmpty else { return }
            cmd = seen.line
        } else {
            let shown = Self.squeeze(seen.toCursor)
            guard !shown.isEmpty, Self.squeeze(typed).hasPrefix(shown) else { return }
            cmd = typed
        }
        recordCommand(cmd.trimmingCharacters(in: .whitespaces))
    }

    /// Прогон журналов фильтрами. Мусор, попавший раньше (пароли, ключи,
    /// код, ответы в меню TUI), уходит в tombstone — удаление уедет синком
    /// на остальные устройства. Tombstone'ы старше 30 дней вычищаются,
    /// чтобы удалённое не хранилось вечно. Зовётся на каждой загрузке
    /// вейлта (в т.ч. после синка) — мусор с других устройств не приживётся.
    @discardableResult
    func sanitizeJournals() -> Int {
        let now = Self.nowISO()
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86_400))
        var removed = 0
        func clean(_ j: [String: CmdStat]) -> [String: CmdStat] {
            var out = j
            for (cmd, st) in j {
                if st.deleted == true {
                    if (st.lastUsed ?? "") < cutoff { out.removeValue(forKey: cmd) }
                } else if Self.journalRejects(cmd) {
                    out[cmd] = CmdStat(count: 0, lastUsed: now, deleted: true)
                    removed += 1
                }
            }
            return out
        }
        let server = clean(cmdHistory)
        var scopes = cmdScopes
        for (k, v) in scopes { scopes[k] = clean(v) }
        guard server != cmdHistory || scopes != cmdScopes else { return 0 }
        cmdHistory = server
        cmdScopes = scopes
        do {
            try store.save(cmdHistory: cmdHistory)
            try store.save(cmdHistoryScopes: cmdScopes)
        } catch {
            vaultError = "Не удалось сохранить журнал команд: \(error)"
        }
        if removed > 0 { syncEngine.schedulePush() }
        return removed
    }

    static func isLikelyCommand(_ cmd: String) -> Bool {
        guard cmd.count >= 2 else { return false }
        guard let first = cmd.split(separator: " ").first else { return false }
        // Первое слово начинается с буквы, точки, / или ~ (имя программы/путь)…
        guard let head = first.first,
              head.isLetter || head == "." || head == "/" || head == "~" else { return false }
        // …и состоит из символов, встречающихся в именах команд.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:+/~-")
        guard first.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Односложные подтверждения — не команды.
        let stopWords: Set<String> = ["y", "n", "yes", "no", "q", "да", "нет"]
        if stopWords.contains(cmd.lowercased()) { return false }
        return true
    }

    /// Enter в терминале: команда — в журнал. Пуша на каждый Enter нет
    /// (как на Android) — уедет со следующим обычным синком.
    func recordCommand(_ cmd: String) {
        guard !Self.journalRejects(cmd) else { return }
        let mac = activeScopeIsMac
        var journal = history(mac: mac)
        var stat = journal[cmd] ?? CmdStat()
        if stat.deleted == true { stat = CmdStat() } // воскрешение после удаления
        stat.count += 1
        stat.lastUsed = Self.nowISO()
        journal[cmd] = stat
        if journal.count > 500 {
            let sorted = journal.sorted { ($0.value.lastUsed ?? "") > ($1.value.lastUsed ?? "") }
            journal = Dictionary(uniqueKeysWithValues: sorted.prefix(500).map { ($0.key, $0.value) })
        }
        saveJournal(journal, mac: mac)
    }

    private func saveJournal(_ journal: [String: CmdStat], mac: Bool) {
        if mac {
            cmdScopes["mac"] = journal
            do { try store.save(cmdHistoryScopes: cmdScopes) }
            catch { vaultError = "Не удалось сохранить журнал команд: \(error)" }
        } else {
            cmdHistory = journal
            do { try store.save(cmdHistory: cmdHistory) }
            catch { vaultError = "Не удалось сохранить журнал команд: \(error)" }
        }
    }

    /// Удалить команду из журнала скоупа (tombstone — уедет синком).
    func deleteCommand(_ cmd: String, macScope: Bool? = nil) {
        let mac = macScope ?? activeScopeIsMac
        var journal = history(mac: mac)
        journal[cmd] = CmdStat(count: 0, lastUsed: Self.nowISO(), deleted: true)
        saveJournal(journal, mac: mac)
        syncEngine.schedulePush()
    }

    /// Очистить журнал скоупа (tombstone на каждую запись).
    func clearCommandLog(macScope: Bool) {
        let now = Self.nowISO()
        var journal = history(mac: macScope)
        for key in journal.keys where journal[key]?.deleted != true {
            journal[key] = CmdStat(count: 0, lastUsed: now, deleted: true)
        }
        saveJournal(journal, mac: macScope)
        syncEngine.schedulePush()
    }

    /// Живые записи журнала скоупа (для инструмента правки).
    func visibleCmdHistory(macScope: Bool) -> [(cmd: String, stat: CmdStat)] {
        history(mac: macScope)
            .filter { $0.value.deleted != true }
            .map { (cmd: $0.key, stat: $0.value) }
            .sorted {
                if $0.stat.count != $1.stat.count { return $0.stat.count > $1.stat.count }
                return ($0.stat.lastUsed ?? "") > ($1.stat.lastUsed ?? "")
            }
    }

    /// Подсказки: свои (частота, свежесть) первыми, затем словарь; до 8.
    /// Скоуп — по активной вкладке; ⇄ подмешивает журнал другого мира.
    func commandSuggestions(for prefix: String) -> [CommandSuggestion] {
        let mac = activeScopeIsMac
        func personal(from journal: [String: CmdStat]) -> [CommandSuggestion] {
            journal
                .filter { $0.value.deleted != true && $0.key.hasPrefix(prefix) && $0.key != prefix }
                .sorted {
                    if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
                    return ($0.value.lastUsed ?? "") > ($1.value.lastUsed ?? "")
                }
                .map { CommandSuggestion(text: $0.key, personal: true) }
        }
        var list = personal(from: history(mac: mac))
        if crossScopeShown {
            list += personal(from: history(mac: !mac))
        }
        let dict = effectiveDict(mac: mac)
            .filter { $0.hasPrefix(prefix) && $0 != prefix }
            .sorted()
            .map { CommandSuggestion(text: $0, personal: false) }
        var seen = Set<String>()
        return (list + dict).filter { seen.insert($0.text).inserted }.prefix(8).map { $0 }
    }

    // MARK: Пользовательский словарь

    func addDictEntry(_ cmd: String, scope: String) {
        cmdDictUser[cmd] = DictEntry(scope: scope, updatedAt: Self.nowISO(), deleted: nil)
        persistDict()
    }

    /// Строки словаря скоупа для UI: встроенные (минус скрытые) + свои.
    func dictionaryRows(macScope: Bool) -> [(cmd: String, custom: Bool)] {
        let scopeName = macScope ? "mac" : "server"
        let builtin = macScope ? CommandDict.mac : CommandDict.common
        var out: [(String, Bool)] = []
        for cmd in builtin where cmdDictUser[cmd]?.deleted != true {
            out.append((cmd, false))
        }
        for (cmd, e) in cmdDictUser {
            guard e.deleted != true else { continue }
            let inScope = (e.scope ?? "both") == "both" || e.scope == scopeName
            if inScope && !builtin.contains(cmd) { out.append((cmd, true)) }
        }
        return out.sorted { $0.0 < $1.0 }.map { (cmd: $0.0, custom: $0.1) }
    }

    /// Удалить СВОЮ запись словаря (tombstone для синка).
    func removeDictEntry(_ cmd: String) {
        cmdDictUser[cmd] = DictEntry(scope: cmdDictUser[cmd]?.scope, updatedAt: Self.nowISO(), deleted: true)
        persistDict()
    }

    /// Скрыть команду словаря (работает и для встроенных).
    func hideDictEntry(_ cmd: String) {
        cmdDictUser[cmd] = DictEntry(scope: cmdDictUser[cmd]?.scope, updatedAt: Self.nowISO(), deleted: true)
        persistDict()
    }

    private func persistDict() {
        do { try store.save(cmdDictUser: cmdDictUser) }
        catch { vaultError = "Не удалось сохранить словарь: \(error)" }
        syncEngine.schedulePush()
    }

    /// Панель видна и готова принимать клавиши.
    var suggestionsActive: Bool {
        !suggestionsSuppressed && cmdPrefix.count >= 1
            && !commandSuggestions(for: cmdPrefix).isEmpty
    }

    /// Перехват клавиш при открытой панели: стрелки/Enter/Tab/Esc.
    /// true = проглочено, в канал и трекер не отправлять.
    func handleSuggestionKey(_ data: ArraySlice<UInt8>) -> Bool {
        guard suggestionsActive else { return false }
        let bytes = Array(data)
        let items = Array(commandSuggestions(for: cmdPrefix).prefix(6))
        let isDown = bytes == [0x1b, 0x5b, 0x42] || bytes == [0x1b, 0x4f, 0x42]
        let isUp   = bytes == [0x1b, 0x5b, 0x41] || bytes == [0x1b, 0x4f, 0x41]
        if isDown {
            suggestionSelection = min(suggestionSelection + 1, items.count - 1)
            return true
        }
        if isUp {
            if suggestionSelection <= -1 { return true } // выше некуда — но в шелл не отдаём
            suggestionSelection -= 1
            return true
        }
        if bytes == [0x1b] { // Esc — закрыть до следующего ввода
            suggestionsSuppressed = true
            suggestionSelection = -1
            return true
        }
        if (bytes == [0x0d] || bytes == [0x09]), suggestionSelection >= 0,
           suggestionSelection < items.count {
            // Enter/Tab по выделенной: вставить остаток, НЕ выполнять.
            let chosen = items[suggestionSelection].text
            suggestionSelection = -1
            sendSuggestionRemainder(chosen, typedPrefix: cmdPrefix)
            return true
        }
        return false
    }

    /// Клик по чипу: дослать ОСТАТОК команды в активную вкладку.
    func sendSuggestionRemainder(_ full: String, typedPrefix: String) {
        guard let tab = activeTab else { return }
        let remainder = String(full.dropFirst(typedPrefix.count))
        let bytes = Array(remainder.utf8)
        if tab.sessionID == Self.localSessionID {
            // Локальная вкладка: остаток — прямо в PTY процесса.
            guard let lt = localTerminals[tab.id] else { return }
            lt.process.send(data: bytes[...])
            cmdTracker.feed(bytes[...])
            lt.window?.makeFirstResponder(lt)
        } else {
            guard let ch = channel(for: tab) else { return }
            ch.send(bytes[...])
            cmdTracker.feed(bytes[...])
            // Клик по панели увёл фокус из терминала — вернуть.
            if let tv = terminals[tab.id] {
                tv.window?.makeFirstResponder(tv)
            }
        }
    }

    // MARK: - Команды с Git

    var visibleGitCommands: [GitCommand] {
        gitCommands.filter { $0.deleted != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func gitCommand(_ id: UUID) -> GitCommand? {
        gitCommands.first { $0.id == id && $0.deleted != true }
    }

    /// Добавить/обновить по id; updatedAt = сейчас → уедет синком.
    func saveGitCommand(_ g: GitCommand) {
        var g = g
        g.updatedAt = Self.nowISO()
        g.deleted = nil
        if let i = gitCommands.firstIndex(where: { $0.id == g.id }) {
            gitCommands[i] = g
        } else {
            gitCommands.append(g)
        }
        persistGitCommands()
    }

    /// Удаление — tombstone (уедет на все устройства).
    func deleteGitCommand(_ id: UUID) {
        guard let i = gitCommands.firstIndex(where: { $0.id == id }) else { return }
        gitCommands[i].deleted = true
        gitCommands[i].updatedAt = Self.nowISO()
        persistGitCommands()
    }

    private func persistGitCommands() {
        do { try store.save(gitCommands: gitCommands) }
        catch { vaultError = "Не удалось сохранить команды Git: \(error)" }
        syncEngine.schedulePush()
    }

    /// Текст в терминал: в активную вкладку (SSH или Mac), а при «Во все
    /// ноды» — целиком во все (канон Windows SendToActive). false — некуда.
    @discardableResult
    func sendText(_ text: String, toAll: Bool = false) -> Bool {
        let bytes = Array(text.utf8)[...]
        if toAll || broadcastMode != .off {
            let any = tabs.contains { connections[$0.sessionID]?.status == .connected }
            sendToAllConnected(bytes)
            return any
        }
        guard let tab = activeTab else { return false }
        if tab.sessionID == Self.localSessionID {
            guard let lt = localTerminals[tab.id] else { return false }
            lt.process.send(data: bytes)
            return true
        }
        guard connections[tab.sessionID]?.status == .connected,
              let ch = channel(for: tab) else { return false }
        ch.send(bytes)
        return true
    }

    /// Вернуть фокус терминалу активной вкладки (после шитов/окон).
    func focusActiveTerminal() {
        guard let tab = activeTab, let tv = anyTerminal(for: tab) else { return }
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
    }

    func addSnippet(title: String, command: String) {
        snippets.append(Snippet(title: title, command: command, updatedAt: Self.nowISO()))
        persistSnippets()
    }

    func deleteSnippet(_ snippet: Snippet) {
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[i].deleted = true
            snippets[i].updatedAt = Self.nowISO()
        }
        persistSnippets()
    }

    private func persistSnippets() {
        do { try store.save(snippets: snippets) }
        catch { vaultError = "Не удалось сохранить сниппеты: \(error)" }
        syncEngine.schedulePush()
    }

    func persist() {
        do {
            try store.save(sessions: sessions)
        } catch {
            vaultError = "Не удалось сохранить хранилище: \(error)"
        }
        syncEngine.schedulePush()
    }

    func upsert(_ session: Session) {
        var stamped = session
        stamped.updatedAt = Self.nowISO()
        stamped.deleted = nil
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = stamped
        } else {
            sessions.append(stamped)
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
        browsers[session.id]?.stopWatchers()
        browsers.removeValue(forKey: session.id)
        // Tombstone вместо физического удаления — иначе синк воскресит запись
        // с устройства, не знавшего об удалении.
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i].deleted = true
            sessions[i].updatedAt = Self.nowISO()
        }
        secrets.deleteAll(for: session.id)
        persist()
    }

    func connection(for session: Session) -> SSHConnection {
        if let existing = connections[session.id] { return existing }
        let id = session.id
        let conn = SSHConnection(sessionProvider: { [weak self] in
            self?.sessions.first(where: { $0.id == id }) ?? session
        }, secrets: secrets, keyProvider: { [weak self] keyID in
            self?.sshKeys.first(where: { $0.id == keyID })
        })
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

    // MARK: - Импорт/экспорт

    func importFromMoba() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.message = "Выбери экспорт MobaXterm (.mobaconf / MobaXterm.ini)"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }

        let imported = MobaImport.parse(text)
        guard !imported.isEmpty else {
            Dialogs.error("В файле не нашлось SSH-сессий ([Bookmarks])")
            return
        }

        var added = 0, skipped = 0
        for item in imported {
            let exists = sessions.contains {
                $0.host == item.host && $0.port == item.port && $0.username == item.username
            }
            if exists { skipped += 1; continue }

            var extra: [String: String] = [:]
            var keyPath: String? = nil
            if let guessed = MobaImport.guessLocalKey(for: item.mobaKeyPath) {
                keyPath = guessed
            } else if let moba = item.mobaKeyPath {
                extra["mobaKeyPath"] = moba // подсказка: какой ключ был в мобе
            }

            let session = Session(
                name: item.name,
                host: item.host,
                port: item.port,
                username: item.username,
                authMethod: .privateKey,
                privateKeyPath: keyPath,
                extra: extra
            )
            sessions.append(session)
            added += 1
        }
        persist()
        Dialogs.info("Импортировано: \(added), пропущено (уже есть): \(skipped).\nСессиям без назначенного ключа укажи ключ через Изменить — исходный .ppk из мобы записан в подсказке.")
    }

    func exportToMoba() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QTerm-sessions.mobaconf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = MobaImport.export(sessions: sessions)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            Dialogs.info("Экспортировано сессий: \(sessions.count).\nПути ключей в мобе замени на соответствующие .ppk.")
        } catch {
            Dialogs.error("Не удалось записать файл: \(error.localizedDescription)")
        }
    }

    func exportVaultToFile() {
        guard let password = Dialogs.askPassword(title: "Пароль для файла экспорта", confirm: true) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "qterm-vault-\(Self.dateStamp()).qtvault"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let vault = try store.load()
            var payload = VaultFile.Payload(
                sessions: vault.sessions,
                snippets: vault.snippets ?? [],
                secrets: (vault.secrets ?? [:]).filter { !$0.key.hasPrefix("sync.") },
                sshKeys: vault.sshKeys ?? []
            )
            payload.cmdHistory = vault.cmdHistory
            payload.cmdHistoryScopes = vault.cmdHistoryScopes
            payload.cmdDictUser = vault.cmdDictUser
            payload.gitCommands = vault.gitCommands
            let data = try VaultFile.encrypt(payload, password: password)
            try data.write(to: url, options: .atomic)
            Dialogs.info("Экспортировано: \(payload.sessions.count) сессий, \(payload.snippets.count) сниппетов, секреты включены.")
        } catch {
            Dialogs.error("Экспорт не удался: \(error.localizedDescription)")
        }
    }

    func importVaultFromFile() {
        let panel = NSOpenPanel()
        panel.message = "Выбери файл .qtvault"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        guard let password = Dialogs.askPassword(title: "Пароль файла", confirm: false) else { return }
        do {
            let payload = try VaultFile.decrypt(data, password: password)
            var vault = try store.load()
            var addedSessions = 0, updatedSessions = 0, skippedSessions = 0

            var secrets = vault.secrets ?? [:]
            for s in payload.sessions {
                if let i = vault.sessions.firstIndex(where: { $0.id == s.id }) {
                    // Виндовая семантика: обновление по id, локальный
                    // hostkey (доверие) приоритетнее импортированного.
                    var merged = s
                    if let localHostkey = vault.sessions[i].extra["hostkey"] {
                        merged.extra["hostkey"] = localHostkey
                    }
                    if vault.sessions[i] != merged {
                        vault.sessions[i] = merged
                        updatedSessions += 1
                    } else {
                        skippedSessions += 1
                    }
                } else if vault.sessions.contains(where: {
                    $0.host == s.host && $0.port == s.port && $0.username == s.username
                }) {
                    skippedSessions += 1
                    continue
                } else {
                    vault.sessions.append(s)
                    addedSessions += 1
                }
                // Секреты сессии: локальные приоритетнее (putIfAbsent).
                for kind in ["password", "privateKeyPassphrase"] {
                    let key = "\(s.id.uuidString).\(kind)"
                    if secrets[key] == nil, let v = payload.secrets[key] { secrets[key] = v }
                }
            }

            // Ключи: дедуп по содержимому; секреты key:/path: переносим целиком
            var keys = vault.sshKeys ?? []
            for k in (payload.sshKeys ?? []) where !keys.contains(where: { $0.privateKey == k.privateKey }) {
                keys.append(k)
            }
            for (k, v) in payload.secrets where k.hasPrefix("key:") || k.hasPrefix("path:") {
                if secrets[k] == nil { secrets[k] = v }
            }

            var snippets = vault.snippets ?? []
            var addedSnippets = 0
            for sn in payload.snippets {
                if !snippets.contains(where: { $0.title == sn.title && $0.command == sn.command }) {
                    snippets.append(sn)
                    addedSnippets += 1
                }
            }

            // Журнал команд из файла — тем же merge, что и синк.
            let mergedHistory = SyncMerge.mergeCmdHistory(
                local: vault.cmdHistory ?? [:],
                remote: payload.cmdHistory ?? [:]
            )
            var scopes = vault.cmdHistoryScopes ?? [:]
            for (name, imported) in payload.cmdHistoryScopes ?? [:] {
                scopes[name] = SyncMerge.mergeCmdHistory(local: scopes[name] ?? [:], remote: imported)
            }
            let dict = SyncMerge.mergeDict(local: vault.cmdDictUser ?? [:], remote: payload.cmdDictUser ?? [:])

            // Команды Git: обновление по id (как на Windows).
            var git = vault.gitCommands ?? []
            for g in payload.gitCommands ?? [] {
                if let i = git.firstIndex(where: { $0.id == g.id }) { git[i] = g } else { git.append(g) }
            }

            try store.save(sessions: vault.sessions, snippets: snippets, secrets: secrets, sshKeys: keys,
                           cmdHistory: mergedHistory, cmdHistoryScopes: scopes, cmdDictUser: dict,
                           gitCommands: git)
            loadVault()
            Dialogs.info("Импортировано: \(addedSessions) новых, обновлено \(updatedSessions), пропущено: \(skippedSessions) (+\(addedSnippets) сниппетов). Секреты и журнал команд слиты, локальные приоритетнее.")
        } catch {
            Dialogs.error(error.localizedDescription)
        }
    }

    // MARK: - Ключи в вейлте

    /// Импорт файла ключа В хранилище: содержимое копируется в вейлт,
    /// исходный файл больше не нужен. Файл можно брать откуда угодно.
    @discardableResult
    func importKeyFile() -> SSHKey? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.message = "Выбери файл приватного ключа (OpenSSH) — из любой папки"
        guard panel.runModal() == .OK, let url = panel.url,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var content = raw
        var name = url.lastPathComponent

        // .ppk конвертируем на месте — без puttygen и прочих внешних утилит.
        if PPKConverter.isPPK(raw) {
            guard let phrase = Dialogs.askPassword(
                title: "Passphrase ключа \(url.lastPathComponent)",
                confirm: false
            ) else { return nil }
            do {
                let result = try PPKConverter.convert(text: raw, passphrase: phrase)
                content = result.openSSH
                name = (url.deletingPathExtension().lastPathComponent)
                Dialogs.info("Ключ \(result.keyType) сконвертирован из PuTTY.\nВ хранилище он лежит уже расшифрованным (сам вейлт под Touch ID), так что passphrase больше не понадобится.")
            } catch {
                Dialogs.error("Конвертация .ppk не удалась:\n\(error.localizedDescription)")
                return nil
            }
        }

        guard content.contains("BEGIN OPENSSH PRIVATE KEY") else {
            Dialogs.error("Не OpenSSH и не PuTTY-формат — такой ключ пока не поддерживается")
            return nil
        }
        if let existing = sshKeys.first(where: { $0.privateKey == content }) {
            Dialogs.info("Такой ключ уже в хранилище: «\(existing.name)»")
            return existing
        }
        let key = SSHKey(name: name, privateKey: content)
        sshKeys.append(key)
        persistKeys()
        return key
    }

    /// Гигиена ноды (перенос с винды): убрать сохранённый пароль.
    /// Отвязать ключи от ноды (канон Windows): ключ из хранилища и путь к файлу.
    func unlinkKeys(for session: Session) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i].keyID = nil
        sessions[i].privateKeyPath = nil
        sessions[i].updatedAt = Self.nowISO()
        persist()
    }

    func forgetPassword(for session: Session) {
        try? secrets.delete(for: session.id, kind: .password)
    }

    /// Гигиена ноды: сбросить доверие hostkey (TOFU заново при подключении).
    func resetTrust(for session: Session) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i].extra.removeValue(forKey: "hostkey")
        sessions[i].updatedAt = Self.nowISO()
        persist()
    }

    func deleteKey(_ key: SSHKey) {
        if let i = sshKeys.firstIndex(where: { $0.id == key.id }) {
            sshKeys[i].deleted = true
            sshKeys[i].updatedAt = Self.nowISO()
        }
        secrets.deletePassphrase(forKeyID: key.id)
        persistKeys()
    }

    /// Ручной порядок нод (drag&drop в сайдбаре). Порядок — локальный для
    /// устройства: merge синка сохраняет свой порядок на каждой стороне,
    /// updatedAt записей не трогаем (иначе перестановка перебила бы правки).
    func moveSessions(from offsets: IndexSet, to destination: Int) {
        var visible = visibleSessions
        visible.move(fromOffsets: offsets, toOffset: destination)
        let tombstones = sessions.filter { $0.deleted == true }
        sessions = visible + tombstones
        persist()
    }

    func moveSession(id: UUID, before targetID: UUID) {
        guard id != targetID else { return }
        var visible = visibleSessions
        guard let from = visible.firstIndex(where: { $0.id == id }),
              let to = visible.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = visible.remove(at: from)
        let insertAt = visible.firstIndex(where: { $0.id == targetID }) ?? to
        visible.insert(moved, at: from < to ? min(insertAt + 1, visible.count) : insertAt)
        let tombstones = sessions.filter { $0.deleted == true }
        sessions = visible + tombstones
        persist()
    }

    func sessionsUsing(_ key: SSHKey) -> [Session] {
        visibleSessions.filter { $0.keyID == key.id }
    }

    func renameKey(_ key: SSHKey, to newName: String) {
        guard let i = sshKeys.firstIndex(where: { $0.id == key.id }) else { return }
        sshKeys[i].name = newName
        sshKeys[i].updatedAt = Self.nowISO()
        persistKeys()
    }

    /// Удаление ключа с отвязкой от нод (иначе повиснут битые keyID).
    func deleteKeyAndDetach(_ key: SSHKey) {
        var changed = false
        for i in sessions.indices where sessions[i].keyID == key.id {
            sessions[i].keyID = nil
            changed = true
        }
        if changed { persist() }
        deleteKey(key)
    }

    func persistKeysPublic() { persistKeys() }

    private func persistKeys() {
        defer { syncEngine.schedulePush() }
        do { try store.save(sshKeys: sshKeys) }
        catch { vaultError = "Не удалось сохранить ключи: \(error)" }
    }

    /// Меню «Данные»: назначить ключ всем нодам-сиротам (без ключа) разом.
    func assignKeyToOrphans() {
        let orphans = sessions.filter {
            $0.authMethod == .privateKey && $0.keyID == nil && ($0.privateKeyPath ?? "").isEmpty
        }
        guard !orphans.isEmpty else {
            Dialogs.info("Нод без ключа нет")
            return
        }
        let key: SSHKey?
        if sshKeys.isEmpty {
            key = importKeyFile()
        } else if let chosen = Dialogs.chooseKey(names: sshKeys.map(\.name) + ["Импортировать файл…"]) {
            key = chosen < sshKeys.count ? sshKeys[chosen] : importKeyFile()
        } else {
            key = nil
        }
        guard let key else { return }
        for orphan in orphans {
            if let i = sessions.firstIndex(where: { $0.id == orphan.id }) {
                sessions[i].keyID = key.id
            }
        }
        persist()
        Dialogs.info("Ключ «\(key.name)» назначен \(orphans.count) нодам.\nPassphrase (если есть) спросится один раз — при первом коннекте, либо задай сразу в Данные → Ключи.")
    }

    /// Задать passphrase ключа заранее (один раз на ключ).
    func setKeyPassphrase() {
        guard !sshKeys.isEmpty else { Dialogs.info("В хранилище нет ключей"); return }
        guard let idx = Dialogs.chooseKey(names: sshKeys.map(\.name)) else { return }
        guard let phrase = Dialogs.askPassword(title: "Passphrase ключа «\(sshKeys[idx].name)»", confirm: false) else { return }
        try? secrets.setPassphrase(phrase, forKeyID: sshKeys[idx].id)
        Dialogs.info("Passphrase сохранена — все ноды с этим ключом будут подключаться без вопросов.")
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    /// Активная вкладка сменилась — её нода считается просмотренной.
    func didActivateTab() {
        markSeen(activeTab?.sessionID)
    }

    /// Очистка активного терминала: локально, работает и при обрыве.
    /// includeScrollback = false — только видимый экран (как clear),
    /// true — экран и весь скроллбек.
    func clearActiveTerminal(includeScrollback: Bool) {
        // Локальная вкладка живёт в своём реестре — раньше очистка её не видела.
        guard let tab = activeTab, let tv = anyTerminal(for: tab) else { return }
        // Очистка шлёт \n в канал мимо трекера — сбрасываем его буфер,
        // иначе дальнейший ввод клеится к недонабранному хвосту.
        cmdTracker.reset()
        let terminal = tv.getTerminal()
        if includeScrollback {
            // ESC[3J вычищает скроллбек, ESC[2J — экран, ESC[H — курсор домой.
            terminal.feed(text: "\u{1B}[3J\u{1B}[2J\u{1B}[H")
        } else {
            terminal.feed(text: "\u{1B}[2J\u{1B}[H")
        }
        tv.needsDisplay = true
        // Промпт перерисовать сразу — иначе остаётся чёрный экран до Enter.
        if tab.sessionID == Self.localSessionID {
            localTerminals[tab.id]?.process.send(data: Array("\n".utf8)[...])
        } else if connections[tab.sessionID]?.status == .connected {
            channel(for: tab)?.send(Array("\n".utf8)[...])
        }
    }
}
