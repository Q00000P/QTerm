import SwiftUI
import SessionVaultKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var editingSession: Session?
    @State private var showAdd = false
    @State private var showSnippetEditor = false
    @State private var stripHeight: CGFloat = 30
    /// Ширина проводника — запоминается между запусками.
    @AppStorage("browserWidth") private var browserWidth: Double = 310
    @State private var dragStartWidth: Double?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showAdd) {
            EditSessionView(session: nil) { state.upsert($0) }
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showKeyManager) {
            KeyManagerView()
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showSyncSettings) {
            SyncSettingsView(engine: state.syncEngine)
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showCommandLog) {
            CommandLogView()
                .environmentObject(state)
        }
        .task { state.syncEngine.pullOnLaunch() }
        .onChange(of: state.activeTabID) { _, _ in state.noteActiveTabChanged() }
        .sheet(item: $editingSession) { s in
            EditSessionView(session: s) { state.upsert($0) }
                .environmentObject(state)
        }
        .sheet(isPresented: $showSnippetEditor) {
            SnippetEditorView().environmentObject(state)
        }
    }

    // MARK: - Сайдбар: список нод (что открыть), не переключатель экрана

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Локальный терминал мака — прибит НАД списком, не скроллится.
            Button {
                state.focusOrOpenLocalTab()
            } label: {
                HStack {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(.cyan)
                        .frame(width: 14)
                    VStack(alignment: .leading) {
                        Text("Mac").fontWeight(.semibold)
                        Text("локальный терминал · ⌘L")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let openLocal = state.tabs.filter { $0.sessionID == AppState.localSessionID }.count
                    if openLocal > 0 {
                        Text("\(openLocal)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.gray.opacity(0.25)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            List {
                ForEach(state.visibleSessions) { session in
                    let isActiveNode = state.activeSessionID == session.id
                    HStack {
                        statusDot(for: session)
                        VStack(alignment: .leading) {
                            Text(session.name).fontWeight(isActiveNode ? .semibold : .medium)
                            Text("\(session.username)@\(session.host):\(String(session.port))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let openTabs = state.tabs.filter { $0.sessionID == session.id }.count
                        if openTabs > 0 {
                            Text("\(openTabs)")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.gray.opacity(0.25)))
                        }
                        if state.unseenActivity.contains(session.id) {
                            Circle().fill(.blue).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isActiveNode ? Color.accentColor.opacity(0.25)
                                  : (state.selectedSessionID == session.id ? Color.gray.opacity(0.18) : Color.clear))
                    )
                    .contentShape(Rectangle())
                    .help("\(session.username)@\(session.host):\(String(session.port))")
                    .onTapGesture { state.focusNode(session) }
                    .onTapGesture(count: 2) { state.openTab(for: session) }
                    .onDrag { NSItemProvider(object: session.id.uuidString as NSString) }
                    .onDrop(of: [.text], delegate: SessionDropDelegate(target: session, state: state))
                    .contextMenu {
                        Button("Открыть в новой вкладке") { state.openTab(for: session) }
                        Divider()
                        Button("Изменить") { editingSession = session }
                        Button("Забыть пароль") { state.forgetPassword(for: session) }
                        Button("Сбросить доверие (ключ сервера)") { state.resetTrust(for: session) }
                        Button("Отключить (вкладки остаются)") {
                            state.connections[session.id]?.disconnect()
                        }
                        Button("Закрыть все вкладки ноды") {
                            state.closeAllTabs(for: session.id)
                        }
                        Divider()
                        Button("Удалить", role: .destructive) { state.delete(session) }
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Button(action: { showAdd = true }) {
                    Label("Добавить", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    if let id = state.selectedSessionID,
                       let s = state.sessions.first(where: { $0.id == id }) {
                        state.openTab(for: s)
                    }
                } label: {
                    Label("Открыть", systemImage: "play.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(state.selectedSessionID == nil)
            }
            .padding(8)

            if let err = state.vaultError {
                VStack(spacing: 4) {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(3)
                    Button("Повторить") { state.loadVault() }.font(.caption)
                }
                .padding(6)
            }
        }
    }

    private func statusDot(for session: Session) -> some View {
        let conn = state.connections[session.id]
        let color: Color
        switch conn?.status {
        case .connected: color = .green
        case .connecting: color = .yellow
        case .awaitingTrust: color = .orange
        case .failed, .closed: color = conn?.autoPausedUntil != nil ? .orange : .red
        default: color = .gray.opacity(0.4)
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: - Рабочая область: лента вкладок + терминалы + проводник

    @ViewBuilder
    private var workspace: some View {
        if state.tabs.isEmpty {
            ContentUnavailableView(
                "Нет открытых вкладок",
                systemImage: "terminal",
                description: Text("Двойной клик по ноде слева — открыть терминал")
            )
        } else {
            VStack(spacing: 0) {
                controlBar
                    .frame(height: 34)
                Divider()
                tabStrip
                    .padding(.top, 4)
                Divider()
                statusBar
                // Свой сплит вместо HSplitView: тот делит место пропорционально
                // и раздувает проводник. Здесь ширина проводника фиксирована,
                // запоминается и таскается за разделитель; терминал — всё остальное.
                HStack(spacing: 0) {
                    terminalArea
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                    if !state.isLocalTab {
                        browserSplitter
                        browserArea
                            .frame(width: browserWidth)
                    }
                }
            }
        }
    }

    /// Разделитель терминал/проводник: тянется, ширина проводника 240–600.
    private var browserSplitter: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: 3)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = browserWidth }
                        let proposed = (dragStartWidth ?? browserWidth) - value.translation.width
                        browserWidth = min(600, max(240, proposed))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    /// Все терминалы живут одновременно; показывается активная вкладка.
    private var terminalArea: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.tabs) { tab in
                if tab.sessionID == AppState.localSessionID {
                    LocalTerminalHostView(tab: tab, isActive: tab.id == state.activeTabID)
                        .opacity(tab.id == state.activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == state.activeTabID)
                } else if let conn = state.connections[tab.sessionID],
                          let ch = state.channel(for: tab) {
                    TerminalHostView(connection: conn, channel: ch, isActive: tab.id == state.activeTabID)
                        .opacity(tab.id == state.activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == state.activeTabID)
                }
            }
            SuggestionOverlay()
        }
    }

    /// Проводник следует за НОДОЙ активной вкладки: прыжки между вкладками
    /// одной ноды его не дёргают (см. SFTPBrowserView — листинг по событию).
    @ViewBuilder
    private var browserArea: some View {
        if let tab = state.activeTab, let conn = state.connections[tab.sessionID] {
            SFTPBrowserView(connection: conn, browser: state.browser(for: conn))
                .id(tab.sessionID)
        } else {
            Color.clear
        }
    }

    // MARK: - Лента вкладок
    //
    // Растёт до 3 рядов (перенос), дальше — вертикальный скролл внутри трёх
    // рядов; при большом количестве основной способ навигации — меню «⌄»
    // со всеми вкладками, сгруппированными по нодам.

    private var tabStrip: some View {
        HStack(alignment: .top, spacing: 6) {
            ScrollView(.vertical, showsIndicators: true) {
                FlowLayout(spacing: 4) {
                    ForEach(state.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.horizontal, 8)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: TabStripHeightKey.self, value: geo.size.height)
                    }
                )
            }
            // Высота по факту содержимого: один ряд — одна строка; максимум три.
            .frame(height: min(stripHeight, 3 * 30))
            .onPreferenceChange(TabStripHeightKey.self) { h in
                stripHeight = max(h, 30)
            }

            Button {
                if let tab = state.activeTab, let s = state.session(for: tab) {
                    state.openTab(for: s)
                }
            } label: {
                Image(systemName: "plus").font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Ещё одна вкладка текущей ноды (⌘T)")

            Menu {
                ForEach(state.visibleSessions) { session in
                    let nodeTabs = state.tabs.filter { $0.sessionID == session.id }
                    if !nodeTabs.isEmpty {
                        Section(session.name) {
                            ForEach(nodeTabs) { tab in
                                Button {
                                    state.activeTabID = tab.id
                                    state.markSeen(tab.sessionID)
                                } label: {
                                    let mark = state.unseenActivity.contains(tab.sessionID) ? " ●" : ""
                                    Text(state.title(for: tab) + mark)
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Все вкладки списком")
        }
        .padding(.trailing, 8)
        .padding(.bottom, 6)
    }

    private func tabChip(_ tab: Tab) -> some View {
        let isActive = tab.id == state.activeTabID
        return HStack(spacing: 7) {
            Circle()
                .fill(dotColor(for: tab))
                .frame(width: 7, height: 7)
            Text(state.title(for: tab))
                .font(.callout)
                .lineLimit(1)
            Button {
                state.close(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)   // зона клика, а не квест
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Закрыть вкладку (⌘W)")
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.28) : Color.gray.opacity(0.12))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.activeTabID = tab.id
            state.markSeen(tab.sessionID)
        }
        .onDrag {
            NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(target: tab, state: state))
        .contextMenu {
            Button("Дублировать вкладку") {
                if tab.sessionID == AppState.localSessionID {
                    state.openLocalTab()
                } else if let s = state.session(for: tab) {
                    state.openTab(for: s)
                }
            }
            Button("Закрыть", role: .destructive) { state.close(tab) }
        }
    }

    private func dotColor(for tab: Tab) -> Color {
        let conn = state.connections[tab.sessionID]
        switch conn?.status {
        case .connected:
            return (state.channel(for: tab)?.isRunning ?? false) ? .green : .yellow
        case .connecting: return .yellow
        case .awaitingTrust: return .orange
        case .failed, .closed: return .red
        default: return .gray.opacity(0.4)
        }
    }

    // MARK: - Панель управления

    private var controlBar: some View {
        HStack(spacing: 12) {
            // Переподключить активную ноду без потери терминала: скроллбек
            // остаётся, новый shell продолжает в том же экране.
            if let tab = state.activeTab, let conn = state.connections[tab.sessionID] {
                Button {
                    conn.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(conn.status == .connected ? Color.secondary : Color.orange)
                }
                .buttonStyle(.borderless)
                .help("Переподключить ноду (терминал и вывод сохраняются)")
            }

            // Быстрый подъём окна редактора (в доке своей иконки у него нет).
            if state.editor.isEditorRunning {
                Button {
                    state.editor.focusEditor()
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("Окно редактора (⌘⇧E)")
            }

            Picker("", selection: $state.broadcastMode) {
                ForEach(BroadcastMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Куда уходит ввод с клавиатуры")

            if let tab = state.activeTab,
               let note = state.connections[tab.sessionID]?.authFallbackNote {
                Text("⚠︎ \(note)")
                    .font(.caption2).foregroundStyle(.yellow)
                    .help("Проверь ключ ноды: сервер его отклонил")
            }

            // Диагностика трекера подсказок: что он видит прямо сейчас.
            if state.trackerDirty {
                Text("⌫ строка неизвестна — Enter/^C/^U вернёт подсказки")
                    .font(.caption2).foregroundStyle(.orange)
            } else if !state.cmdPrefix.isEmpty {
                Text("⌨ \(state.cmdPrefix)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Menu {
                if state.snippets.isEmpty {
                    Text("Пусто — добавь команду")
                }
                ForEach(state.visibleSnippets) { snip in
                    Menu(snip.title) {
                        Button("→ В эту вкладку") { send(snip, toAll: false) }
                        Button("⇉ Во все ноды") { send(snip, toAll: true) }
                    }
                }
                Divider()
                Button("Изменить сниппеты…") { showSnippetEditor = true }
            } label: {
                Label("Команды", systemImage: "text.badge.star").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 14)

            Button {
                state.clearActiveTerminal(includeScrollback: false)
            } label: {
                Image(systemName: "eraser").font(.body)
            }
            .buttonStyle(.borderless)
            .help("Очистить экран (скроллбек остаётся)")

            Button {
                state.clearActiveTerminal(includeScrollback: true)
            } label: {
                Image(systemName: "trash").font(.body)
            }
            .buttonStyle(.borderless)
            .help("Очистить экран и весь скроллбек этой вкладки")

            Button {
                state.confirmCloseAllTabs()
            } label: {
                Image(systemName: "xmark.rectangle.portrait").font(.body)
            }
            .buttonStyle(.borderless)
            .help("Закрыть все вкладки всех нод (соединения рвутся)")
            .disabled(state.tabs.isEmpty)

            if state.broadcastMode == .allNodes {
                Text("СКВОЗНОЙ ВВОД: печать уходит во все подключённые ноды")
                    .font(.caption2).bold().foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func send(_ snip: Snippet, toAll: Bool) {
        let bytes = Array((snip.command + "\n").utf8)[...]
        if toAll {
            state.sendToAllConnected(bytes)
        } else if let tab = state.activeTab {
            state.channel(for: tab)?.send(bytes)
        }
    }

    // MARK: - Статус активной вкладки

    @ViewBuilder
    private var statusBar: some View {
        if let tab = state.activeTab, let conn = state.connections[tab.sessionID] {
            switch conn.status {
            case .connecting, .failed, .closed:
                LiveStatusBar(connection: conn)
            case .awaitingTrust(let fp):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Новый сервер. Отпечаток ключа:").font(.caption)
                    Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Доверять и подключиться") {
                            conn.trustPendingHostKey { b64 in
                                guard var s = state.session(for: tab) else { return }
                                s.extra["hostkey"] = b64
                                state.upsert(s)
                            }
                        }
                        Button("Отмена", role: .cancel) { conn.disconnect() }
                    }.font(.caption)
                }
                .padding(8)
                .background(.yellow.opacity(0.12))
            case .connected, .idle:
                EmptyView()
            }
        }
    }
}

/// Единственный источник правды о состоянии соединения: тикающая строка
/// с живым отсчётом. Скроллбек фиксирует события, эта строка — состояние.
struct LiveStatusBar: View {
    @ObservedObject var connection: SSHConnection
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer()
            if showButton {
                Button(buttonTitle) { connection.retryNow() }
                    .font(.caption)
            }
        }
        .padding(6)
        .background(background)
        .onReceive(tick) { now = $0 }
    }

    private var showButton: Bool {
        switch connection.status {
        case .connected, .awaitingTrust: return false
        default: return true
        }
    }

    private var buttonTitle: String {
        if case .connecting = connection.status { return "Заново" }
        return "Подключить сейчас"
    }

    private var secondsLeft: Int? {
        let target = connection.autoPausedUntil ?? connection.nextRetryAt
        guard let target, target > now else { return nil }
        return Int(target.timeIntervalSince(now).rounded(.up))
    }

    private var text: String {
        switch connection.status {
        case .connecting:
            var s = "Подключение…"
            if connection.attemptNumber > 1 { s += " (попытка \(connection.attemptNumber)" }
            if let started = connection.attemptStartedAt {
                let sec = Int(now.timeIntervalSince(started))
                s += connection.attemptNumber > 1 ? ", \(sec)с)" : " \(sec)с"
            } else if connection.attemptNumber > 1 {
                s += ")"
            }
            if let until = connection.autoPausedUntil, until > now {
                s += "  ·  ручной режим \(Int(until.timeIntervalSince(now).rounded(.up)))с"
            }
            return s + "  ·  R — начать заново"
        case .failed(let msg):
            if let until = connection.autoPausedUntil, until > now {
                return "Не удалось: \(msg)  ·  ручной режим \(Int(until.timeIntervalSince(now).rounded(.up)))с  ·  R — попытка"
            }
            if let left = secondsLeft {
                return "Не удалось: \(msg)  ·  повтор через \(left)с  ·  R — сейчас"
            }
            return "Не удалось: \(msg)  ·  R — попытка"
        case .closed:
            if let until = connection.autoPausedUntil, until > now {
                return "Ручной режим \(Int(until.timeIntervalSince(now).rounded(.up)))с  ·  R — попытка, авто-реконнект ждёт"
            }
            if let left = secondsLeft {
                return "Обрыв. Следующая попытка через \(left)с  ·  R — сейчас"
            }
            return "Соединение закрыто  ·  R — подключить"
        default:
            return ""
        }
    }

    private var color: Color {
        switch connection.status {
        case .failed: return .red
        case .closed: return connection.autoPausedUntil != nil ? .orange : .yellow
        default: return .yellow
        }
    }

    private var background: Color {
        if case .failed = connection.status { return .red.opacity(0.1) }
        return .clear
    }
}

/// Редактор избранных команд. Хранятся в вейлте — уедут в синк вместе с сессиями.
struct SnippetEditorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""
    @State private var newCommand = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сниппеты").font(.headline)

            List {
                ForEach(state.visibleSnippets) { snip in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(snip.title).fontWeight(.medium)
                            Text(snip.command)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            state.deleteSnippet(snip)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 180)

            Divider()
            Text("Добавить").font(.subheadline)
            TextField("Название", text: $newTitle)
            TextField("Команда", text: $newCommand)
                .font(.system(.body, design: .monospaced))
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                Button("Добавить") {
                    state.addSnippet(title: newTitle.isEmpty ? String(newCommand.prefix(24)) : newTitle,
                                     command: newCommand)
                    newTitle = ""; newCommand = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newCommand.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480, height: 400)
    }
}

// MARK: - Перенос вкладок на следующий ряд

/// Простой wrap-лейаут: вкладки переносятся на новый ряд, когда кончается
/// ширина. Ограничение по высоте задаёт вызывающая сторона (3 ряда + скролл).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Перетаскивание нод в сайдбаре: порядок локальный, синк его не трогает.
struct SessionDropDelegate: DropDelegate {
    let target: Session
    let state: AppState

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let str = item as? String, let dragged = UUID(uuidString: str) else { return }
            Task { @MainActor in
                state.moveSession(id: dragged, before: target.id)
            }
        }
        return true
    }

    func dropEntered(info: DropInfo) {}
    func validateDrop(info: DropInfo) -> Bool { true }
}

/// Перетаскивание вкладок: перекладываем в state.tabs, терминалы не трогаем.
struct TabDropDelegate: DropDelegate {
    let target: Tab
    let state: AppState

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let str = item as? String, let dragged = UUID(uuidString: str) else { return }
            Task { @MainActor in
                state.moveTab(id: dragged, before: target.id)
            }
        }
        return true
    }

    func dropEntered(info: DropInfo) {}
    func validateDrop(info: DropInfo) -> Bool { true }
}


/// Фактическая высота ленты вкладок — чтобы не резать место у терминала.
struct TabStripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 30
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
