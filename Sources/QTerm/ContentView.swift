import SwiftUI
import SessionVaultKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var editingSession: Session?
    @State private var showAdd = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, maxWidth: 300)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showAdd) {
            EditSessionView(session: nil) { state.upsert($0) }
                .environmentObject(state)
        }
        .sheet(item: $editingSession) { s in
            EditSessionView(session: s) { state.upsert($0) }
                .environmentObject(state)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $state.selectedSessionID) {
                ForEach(state.sessions) { session in
                    HStack {
                        statusDot(for: session)
                        VStack(alignment: .leading) {
                            Text(session.name).fontWeight(.medium)
                            Text("\(session.username)@\(session.host):\(String(session.port))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if state.unseenActivity.contains(session.id) {
                            Circle().fill(.blue).frame(width: 7, height: 7)
                        }
                    }
                    .tag(session.id)
                    .contextMenu {
                        Button("Изменить") { editingSession = session }
                        Button("Отключить") { state.connections[session.id]?.disconnect() }
                        Button("Удалить", role: .destructive) { state.delete(session) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: state.selectedSessionID) { _, newID in
                state.markSeen(newID)
            }

            Divider()
            HStack {
                Button(action: { showAdd = true }) {
                    Label("Добавить", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
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

    @ViewBuilder
    private var detail: some View {
        if let id = state.selectedSessionID,
           let session = state.sessions.first(where: { $0.id == id }) {
            let conn = state.connection(for: session)
            SessionDetailView(connection: conn, onTrustHostKey: { b64 in
                var updated = session
                updated.extra["hostkey"] = b64
                state.upsert(updated)
            })
            .id(session.id)
            .onAppear {
                DispatchQueue.main.async {
                    if let tv = state.terminals[session.id] {
                        tv.window?.makeFirstResponder(tv)
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "Выбери сессию",
                systemImage: "terminal",
                description: Text("Или добавь новую — «+» внизу слева")
            )
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
}

/// Терминал + проводник + строка состояния соединения (видимые ошибки
/// вместо молчаливой серой точки).
struct SessionDetailView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var connection: SSHConnection
    var onTrustHostKey: ((String) -> Void)?
    @State private var showSnippetEditor = false

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            statusBar
            HSplitView {
                TerminalHostView(connection: connection)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                SFTPBrowserView(connection: connection)
                    .frame(minWidth: 240, idealWidth: 320)
            }
        }
        .sheet(isPresented: $showSnippetEditor) {
            SnippetEditorView().environmentObject(state)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $state.broadcastInput) {
                Label("Во все", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .help("Сквозной ввод: печать уходит во все подключённые сессии")

            Menu {
                if state.snippets.isEmpty {
                    Text("Пусто — добавь команду")
                }
                ForEach(state.snippets) { snip in
                    Menu(snip.title) {
                        Button("→ В текущую") { send(snip, toAll: false) }
                        Button("⇉ Во все подключённые") { send(snip, toAll: true) }
                    }
                }
                Divider()
                Button("Изменить сниппеты…") { showSnippetEditor = true }
            } label: {
                Label("Команды", systemImage: "text.badge.star").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if state.broadcastInput {
                Text("СКВОЗНОЙ ВВОД: печать уходит во все подключённые ноды")
                    .font(.caption2).bold().foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func send(_ snip: Snippet, toAll: Bool) {
        let bytes = Array((snip.command + "\n").utf8)[...]
        if toAll {
            state.sendToAllConnected(bytes)
        } else {
            connection.sendToShell(bytes)
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        switch connection.status {
        case .connecting, .failed, .closed:
            LiveStatusBar(connection: connection)
        case .awaitingTrust(let fp):
            VStack(alignment: .leading, spacing: 6) {
                Text("Новый сервер. Отпечаток ключа:").font(.caption)
                Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Доверять и подключиться") {
                        connection.trustPendingHostKey { b64 in onTrustHostKey?(b64) }
                    }
                    Button("Отмена", role: .cancel) { connection.disconnect() }
                }.font(.caption)
            }
            .padding(8)
            .background(.yellow.opacity(0.12))
        case .connected, .idle:
            EmptyView()
        }
    }

    private func barText(_ s: String, _ c: Color) -> some View {
        HStack { Text(s).font(.caption).foregroundStyle(c); Spacer() }.padding(6)
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

    /// Кнопка есть всегда, когда соединения нет — включая «ни разу не подключались».
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
                ForEach(state.snippets) { snip in
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
