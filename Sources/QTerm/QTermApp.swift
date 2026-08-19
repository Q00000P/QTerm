import SwiftUI
import AppKit
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
            CommandMenu("Данные") {
                Button("Импорт из MobaXterm…") { state.importFromMoba() }
                Button("Экспорт в MobaXterm…") { state.exportToMoba() }
                Divider()
                Button("Импортировать ключ в хранилище…") { state.importKeyFile() }
                Button("Назначить ключ нодам без ключа…") { state.assignKeyToOrphans() }
                Button("Задать passphrase ключа…") { state.setKeyPassphrase() }
                Divider()
                Button("Экспорт вейлта в файл…") { state.exportVaultToFile() }
                Button("Импорт вейлта из файла…") { state.importVaultFromFile() }
            }
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
    /// Приватные ключи из вейлта.
    @Published var sshKeys: [SSHKey] = []

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
            sshKeys = vault.sshKeys ?? []
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
            let payload = VaultFile.Payload(
                sessions: vault.sessions,
                snippets: vault.snippets ?? [],
                secrets: vault.secrets ?? [:],
                sshKeys: vault.sshKeys ?? []
            )
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
            var addedSessions = 0, skippedSessions = 0

            var secrets = vault.secrets ?? [:]
            for s in payload.sessions {
                let exists = vault.sessions.contains {
                    $0.host == s.host && $0.port == s.port && $0.username == s.username
                }
                if exists { skippedSessions += 1; continue }
                vault.sessions.append(s)
                addedSessions += 1
                // Секреты импортированной сессии
                for kind in ["password", "privateKeyPassphrase"] {
                    let key = "\(s.id.uuidString).\(kind)"
                    if let v = payload.secrets[key] { secrets[key] = v }
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

            try store.save(sessions: vault.sessions, snippets: snippets, secrets: secrets, sshKeys: keys)
            loadVault()
            Dialogs.info("Импортировано: \(addedSessions) сессий (+\(addedSnippets) сниппетов), пропущено дублей: \(skippedSessions). Секреты новых сессий перенесены.")
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

    func deleteKey(_ key: SSHKey) {
        sshKeys.removeAll { $0.id == key.id }
        secrets.deletePassphrase(forKeyID: key.id)
        persistKeys()
    }

    func persistKeysPublic() { persistKeys() }

    private func persistKeys() {
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
