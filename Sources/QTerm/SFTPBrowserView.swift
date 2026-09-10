import SwiftUI
import AppKit
import Citadel
import NIOCore
import UniformTypeIdentifiers

/// Модель одной строки проводника.
struct RemoteEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let permissions: String
    /// Полная строка ls -l (права, владелец, группа, размер, дата).
    let details: String
}

/// Логика проводника: листинг, навигация, CRUD, скачивание/заливка,
/// правка через временный файл (download → open → watch mtime → upload).
@MainActor
final class SFTPBrowser: ObservableObject {
    @Published var currentPath: String = "/root"
    @Published var entries: [RemoteEntry] = []
    @Published var busy = false
    @Published var errorText: String?
    /// Текст прогресса длинной операции («Скачивание 12/40: name»), nil — нет операции.
    @Published var progressText: String?
    /// Первый листинг после подключения уже был — повторно не дёргаем.
    var didInitialList = false
    /// Хотя бы один листинг удался (для фолбэка стартового пути).
    private var hasListedOnce = false
    /// Один авторетрай первого листинга (гонка с подъёмом shell-каналов).
    private var didRetryInitial = false

    private weak var connection: SSHConnection?
    private var editWatchers: [String: DispatchSourceFileSystemObject] = [:]

    init(connection: SSHConnection) {
        self.connection = connection
        // Стартовый путь проводника из настроек сессии.
        if let start = connection.session.extra["sftpPath"]?.trimmingCharacters(in: .whitespaces),
           !start.isEmpty {
            currentPath = start
        }
    }

    private var sftp: SFTPClient? { connection?.sftp }
    /// Командный режим: соединение живо, SFTP нет — работаем через exec.
    var execMode: Bool { connection?.status == .connected && connection?.sftp == nil }
    /// Проводнику есть чем работать (любой из бэкендов).
    private var backendReady: Bool { sftp != nil || execMode }

    /// Листинг каталога -> [RemoteEntry] (общий для UI и рекурсивных операций).
    private func listEntries(at path: String) async throws -> [RemoteEntry] {
        if sftp != nil { return try await listEntriesSFTP(at: path) }
        if let connection, execMode { return try await Self.listEntriesExec(at: path, connection: connection) }
        return []
    }

    private func listEntriesSFTP(at path: String) async throws -> [RemoteEntry] {
        guard let sftp else { return [] }
        let raw = try await sftp.listDirectory(atPath: path)
        var result: [RemoteEntry] = []
        for nameMsg in raw {
            for component in nameMsg.components {
                let fname = component.filename
                if fname == "." || fname == ".." { continue }
                let full = path.hasSuffix("/") ? path + fname : path + "/" + fname
                let longname = component.longname
                result.append(RemoteEntry(
                    name: fname,
                    path: full,
                    isDirectory: longname.hasPrefix("d"),
                    size: UInt64(component.attributes.size ?? 0),
                    permissions: String(longname.prefix(10)),
                    details: longname
                ))
            }
        }
        return result
    }

    /// Командный режим: `ls -la` + парсинг busybox-формата.
    /// perms links owner group size Mon DD time/year name[ -> target]
    static func listEntriesExec(at path: String, connection: SSHConnection) async throws -> [RemoteEntry] {
        let out = try await connection.exec("ls -la \(SSHConnection.shellEscape(path)) 2>&1")
        if out.contains("No such file or directory") || out.contains("not found") {
            throw SFTPBrowser.BrowserError.execListing(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var result: [RemoteEntry] = []
        for line in out.split(separator: "\n") {
            guard let first = line.first, "-dlcbsp".contains(first) else { continue } // total и мусор
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 9 else { continue }
            var name = tokens[8...].joined(separator: " ")
            if first == "l", let range = name.range(of: " -> ") {
                name = String(name[..<range.lowerBound])
            }
            if name == "." || name == ".." { continue }
            let full = path.hasSuffix("/") ? path + name : path + "/" + name
            result.append(RemoteEntry(
                name: name,
                path: full,
                isDirectory: first == "d",
                size: UInt64(tokens[4]) ?? 0,
                permissions: String(tokens[0].prefix(10)),
                details: String(line)
            ))
        }
        return result
    }

    // MARK: - Listing / navigation

    func refresh() {
        // Бэкенд ещё не готов — не помечаем листинг сделанным, иначе
        // onChange(.connected) его больше не запустит (гонка при старте).
        guard backendReady else { return }
        didInitialList = true
        list(path: currentPath)
    }

    func list(path: String) {
        guard backendReady else { return }
        busy = true
        Task {
            do {
                let result = try await listEntries(at: path)
                self.entries = result.sorted {
                    ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased())
                }
                self.currentPath = path
                self.errorText = nil
            } catch {
                if !didRetryInitial {
                    // Первый листинг мог совпасть с подъёмом shell-каналов
                    // (dropbear) или стартовый каталог отсутствует — один
                    // ретрай через секунду, при отсутствии каталога — в "/".
                    didRetryInitial = true
                    let msg = String(describing: error)
                    let missingDir = msg.contains("No such file") || msg.contains("not found")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    self.busy = false
                    self.list(path: missingDir ? "/" : path)
                    return
                }
                self.errorText = "Листинг \(path): \(error.localizedDescription)"
            }
            self.busy = false
        }
    }

    func enter(_ entry: RemoteEntry) {
        guard entry.isDirectory else { return }
        list(path: entry.path)
    }

    func goUp() {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        list(path: parent.isEmpty ? "/" : parent)
    }

    // MARK: - CRUD

    func mkdir(name: String) {
        let path = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
        Task {
            do {
                if let sftp {
                    try await sftp.createDirectory(atPath: path)
                } else if let connection, execMode {
                    _ = try await connection.exec("mkdir \(SSHConnection.shellEscape(path))")
                }
                refresh()
            }
            catch { errorText = "mkdir: \(error)" }
        }
    }

    func delete(_ entry: RemoteEntry) {
        guard backendReady else { return }
        Task {
            do {
                if sftp != nil {
                    if entry.isDirectory {
                        try await deleteRecursively(entry.path)
                    } else {
                        try await sftp?.remove(at: entry.path)
                    }
                } else if let connection {
                    _ = try await connection.exec("rm -rf \(SSHConnection.shellEscape(entry.path))")
                }
                refresh()
            } catch { errorText = "Удаление: \(error)" }
        }
    }

    private func deleteRecursively(_ path: String) async throws {
        for child in try await listEntries(at: path) {
            if child.isDirectory {
                try await deleteRecursively(child.path)
            } else {
                try await sftp?.remove(at: child.path)
            }
        }
        try await sftp?.rmdir(at: path)
    }

    func rename(_ entry: RemoteEntry, to newName: String) {
        guard backendReady else { return }
        let newPath = (currentPath as NSString).appendingPathComponent(newName)
        Task {
            do {
                if let sftp {
                    try await sftp.rename(at: entry.path, to: newPath)
                } else if let connection {
                    _ = try await connection.exec(
                        "mv \(SSHConnection.shellEscape(entry.path)) \(SSHConnection.shellEscape(newPath))")
                }
                refresh()
            }
            catch { errorText = "Переименование: \(error)" }
        }
    }

    /// chmod через exec-канал соединения (busybox chmod есть везде).
    func chmod(_ entry: RemoteEntry, octal: String) {
        guard let connection else { return }
        Task {
            do {
                let escaped = entry.path.replacingOccurrences(of: "'", with: "'\\''")
                let out = try await connection.exec("chmod \(octal) '\(escaped)' 2>&1")
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    errorText = "chmod: \(trimmed)"
                } else {
                    errorText = nil
                }
                refresh()
            } catch { errorText = "chmod: \(error)" }
        }
    }

    // MARK: - Transfer

    func download(_ entry: RemoteEntry, to localURL: URL) {
        guard backendReady else { return }
        busy = true
        Task {
            do {
                if entry.isDirectory {
                    var done = 0
                    try await downloadRecursively(entry, to: localURL, done: &done)
                    self.progressText = nil
                } else {
                    try await downloadFile(remotePath: entry.path, to: localURL)
                }
                self.errorText = nil
            } catch {
                self.progressText = nil
                self.errorText = "Скачивание: \(error)"
            }
            self.busy = false
        }
    }

    private func downloadFile(remotePath: String, to localURL: URL) async throws {
        guard let connection else { return }
        let data = try await connection.readFile(path: remotePath)
        try data.write(to: localURL)
    }

    private func downloadRecursively(_ entry: RemoteEntry, to localURL: URL, done: inout Int) async throws {
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        for child in try await listEntries(at: entry.path) {
            let childLocal = localURL.appendingPathComponent(child.name)
            if child.isDirectory {
                try await downloadRecursively(child, to: childLocal, done: &done)
            } else {
                done += 1
                progressText = "Скачивание \(done): \(child.name)"
                try await downloadFile(remotePath: child.path, to: childLocal)
            }
        }
    }

    func upload(localURL: URL) {
        guard backendReady else { return }
        busy = true
        Task {
            do {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
                if isDir.boolValue {
                    var done = 0
                    let remoteBase = (currentPath as NSString).appendingPathComponent(localURL.lastPathComponent)
                    try await uploadRecursively(localURL: localURL, remotePath: remoteBase, done: &done)
                    self.progressText = nil
                } else {
                    let remotePath = (currentPath as NSString).appendingPathComponent(localURL.lastPathComponent)
                    try await uploadFile(localURL: localURL, remotePath: remotePath)
                }
                refresh()
            } catch {
                self.progressText = nil
                self.errorText = "Заливка: \(error)"
            }
            self.busy = false
        }
    }

    private func uploadFile(localURL: URL, remotePath: String) async throws {
        guard let connection else { return }
        let data = try Data(contentsOf: localURL)
        try await connection.writeFile(path: remotePath, data: data)
    }

    private func uploadRecursively(localURL: URL, remotePath: String, done: inout Int) async throws {
        // Каталог может уже существовать — это не ошибка.
        if let sftp {
            try? await sftp.createDirectory(atPath: remotePath)
        } else if let connection, execMode {
            _ = try? await connection.exec("mkdir -p \(SSHConnection.shellEscape(remotePath))")
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: localURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let childRemote = (remotePath as NSString).appendingPathComponent(child.lastPathComponent)
            if isDir {
                try await uploadRecursively(localURL: child, remotePath: childRemote, done: &done)
            } else {
                done += 1
                progressText = "Заливка \(done): \(child.lastPathComponent)"
                try await uploadFile(localURL: child, remotePath: childRemote)
            }
        }
    }

    // MARK: - Чтение в память (для встроенного редактора)

    enum BrowserError: LocalizedError {
        case notConnected
        case execListing(String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Нода не подключена"
            case .execListing(let out): return out
            }
        }
    }

    /// Скачивает файл в память. Размер проверяет вызывающий (по entry.size).
    func readFileData(_ entry: RemoteEntry) async throws -> Data {
        guard let connection else { throw BrowserError.notConnected }
        return try await connection.readFile(path: entry.path)
    }

    // MARK: - Edit-in-place (download → open in default editor → autoupload on save)

    func edit(_ entry: RemoteEntry) {
        guard !entry.isDirectory else { return }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qterm-edit", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let localURL = tmpDir.appendingPathComponent(entry.name)

        download(entry, to: localURL)

        // Наблюдаем за записью файла; каждое сохранение — upload обратно.
        // MVP-версия: vnode-watcher, без дебаунса. Редакторы, пишущие
        // atomic-rename (VS Code), потребуют пересоздания watcher'а — known issue.
        let fd = open(localURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let connection = self.connection else { return }
            Task {
                do {
                    let data = try Data(contentsOf: localURL)
                    try await connection.writeFile(path: entry.path, data: data)
                } catch {
                    self.errorText = "Автозаливка \(entry.name): \(error)"
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        editWatchers[entry.path]?.cancel()
        editWatchers[entry.path] = source

        NSWorkspace.shared.open(localURL)
    }

    func stopWatchers() {
        editWatchers.values.forEach { $0.cancel() }
        editWatchers.removeAll()
    }
}

// MARK: - View

struct SFTPBrowserView: View {
    @ObservedObject var connection: SSHConnection
    /// Живёт в AppState.browsers (по ноде) — путь переживает переключения.
    @ObservedObject var browser: SFTPBrowser
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    private var connectionStatus: SSHConnection.Status { connection.status }
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    /// Файл, для которого открыт диалог прав (sheet).
    @State private var permEntry: RemoteEntry?
    /// Файл в диалоге переименования + вводимое имя.
    @State private var renameEntry: RemoteEntry?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: browser.goUp) { Image(systemName: "arrow.up") }
                    .disabled(browser.currentPath == "/")
                Text(browser.currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .contextMenu {
                        Button("Скопировать путь") { copyToPasteboard(browser.currentPath) }
                        Button("Сделать стартовым путём проводника") { setAsStartPath() }
                    }
                Button {
                    copyToPasteboard(browser.currentPath)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Скопировать путь")
                Spacer()
                Button(action: browser.refresh) { Image(systemName: "arrow.clockwise") }
                Button(action: { showNewFolder = true }) { Image(systemName: "folder.badge.plus") }
                Button(action: pickAndUpload) { Image(systemName: "square.and.arrow.up") }
            }
            .padding(6)

            Divider()

            List(browser.entries) { entry in
                HStack {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                    Text(entry.name)
                    Spacer()
                    if !entry.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button {
                        pickAndDownload(entry)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help(entry.isDirectory ? "Скачать папку" : "Скачать файл")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    entry.isDirectory ? browser.enter(entry) : openInEditor(entry)
                }
                .contextMenu {
                    if !entry.isDirectory {
                        Button("Редактировать") { openInEditor(entry) }
                        Button("Открыть во внешнем редакторе") { browser.edit(entry) }
                        Divider()
                    }
                    Button(entry.isDirectory ? "Скачать папку…" : "Скачать…") { pickAndDownload(entry) }
                    Divider()
                    Button("Переименовать…") {
                        renameText = entry.name
                        renameEntry = entry
                    }
                    Button("Права…") { permEntry = entry }
                    Divider()
                    Button("Скопировать путь") { copyToPasteboard(entry.path) }
                    Button("Скопировать имя") { copyToPasteboard(entry.name) }
                    Button("Путь → в терминал") { sendPathToTerminal(entry) }
                    Divider()
                    Button("Свойства") { showProperties(entry) }
                    Button("Удалить", role: .destructive) { browser.delete(entry) }
                }
            }
            .listStyle(.plain)

            if let progress = browser.progressText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .padding(4)
            }

            if let err = browser.errorText {
                Text(err)
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(2).padding(4)
            }

            if connectionStatus == .connected && connection.sftp == nil {
                Divider()
                execModeBanner
            }
        }
        .onAppear { if !browser.didInitialList { browser.refresh() } }
        .onChange(of: connectionStatus) { _, st in
            // Первый листинг после подключения ноды — дальше только вручную
            // или после собственных операций (см. refresh() в CRUD).
            if st == .connected && !browser.didInitialList { browser.refresh() }
        }
        .onChange(of: connection.sftp == nil) { _, missing in
            // SFTP поднялся позже коннекта (кнопка «Повторить» после установки
            // sftp-server) — делаем первый листинг.
            if !missing && !browser.didInitialList { browser.refresh() }
        }
        .alert("Новая папка", isPresented: $showNewFolder) {
            TextField("Имя", text: $newFolderName)
            Button("Создать") {
                browser.mkdir(name: newFolderName)
                newFolderName = ""
            }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Переименовать", isPresented: Binding(
            get: { renameEntry != nil },
            set: { if !$0 { renameEntry = nil } }
        )) {
            TextField("Новое имя", text: $renameText)
            Button("Переименовать") {
                if let entry = renameEntry, !renameText.isEmpty, renameText != entry.name {
                    browser.rename(entry, to: renameText)
                }
                renameEntry = nil
            }
            Button("Отмена", role: .cancel) { renameEntry = nil }
        }
        .sheet(item: $permEntry) { entry in
            PermissionsSheet(entry: entry) { octal in
                browser.chmod(entry, octal: octal)
            }
        }
    }

    private static let sftpInstallCommand = "opkg update && opkg install openssh-sftp-server"

    /// Соединение живо, SFTP нет — проводник работает в командном режиме
    /// (ls/cat/base64 через exec). Баннер с подсказкой поставить sftp-server.
    private var execModeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.yellow)
            Text("Командный режим — SFTP на сервере нет, будет медленнее")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Поставить sftp") { sendToTerminal(Self.sftpInstallCommand) }
                .font(.caption)
                .help("Вставить в терминал: \(Self.sftpInstallCommand)")
            Button("Повторить SFTP") { connection.retrySFTP() }
                .font(.caption)
                .help("Переоткрыть SFTP после установки — без реконнекта")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.yellow.opacity(0.08))
    }

    /// Вставка текста в терминал этой ноды (без Enter).
    private func sendToTerminal(_ text: String) {
        let sid = connection.session.id
        let tab = state.tabs.first { $0.id == state.activeTabID && $0.sessionID == sid }
            ?? state.tabs.first { $0.sessionID == sid }
        guard let tab, let ch = state.channel(for: tab) else { return }
        ch.send(Array(text.utf8)[...])
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Вставка пути в терминал этой ноды (активная её вкладка, иначе первая).
    private func sendPathToTerminal(_ entry: RemoteEntry) {
        sendToTerminal(entry.path)
    }

    /// Свойства: полная строка ls -l с сервера.
    private func showProperties(_ entry: RemoteEntry) {
        Dialogs.info("""
        \(entry.name)

        Путь: \(entry.path)
        Размер: \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))

        \(entry.details)
        """)
    }

    /// Текущий каталог проводника → стартовый путь этой сессии (сохраняется в вейлт).
    private func setAsStartPath() {
        var s = connection.session
        s.extra["sftpPath"] = browser.currentPath
        state.upsert(s)
    }

    /// Двойной клик по файлу: скачиваем в память → вкладка в окне редактора.
    private func openInEditor(_ entry: RemoteEntry) {
        guard entry.size <= EditorBridge.maxEditableSize else {
            browser.errorText = "«\(entry.name)» больше 2 МБ — открой через скачивание"
            return
        }
        let session = connection.session
        Task {
            do {
                let data = try await browser.readFileData(entry)
                try state.editor.open(
                    remotePath: entry.path,
                    data: data,
                    sessionID: session.id,
                    nodeName: session.name
                )
                openWindow(id: "editor")
                browser.errorText = nil
            } catch {
                browser.errorText = "Редактор: \(error.localizedDescription)"
            }
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true // папку — целиком, рекурсивно
        if panel.runModal() == .OK, let url = panel.url {
            browser.upload(localURL: url)
        }
    }

    private func pickAndDownload(_ entry: RemoteEntry) {
        if entry.isDirectory {
            // Папка: выбираем локальный каталог-назначение, качаем рекурсивно внутрь.
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Скачать сюда"
            if panel.runModal() == .OK, let dir = panel.url {
                browser.download(entry, to: dir.appendingPathComponent(entry.name))
            }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            if panel.runModal() == .OK, let url = panel.url {
                browser.download(entry, to: url)
            }
        }
    }
}

// MARK: - Диалог прав (как в мобе: чекбоксы rwx + октал)

struct PermissionsSheet: View {
    let entry: RemoteEntry
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 9 бит: [u_r, u_w, u_x, g_r, g_w, g_x, o_r, o_w, o_x]
    @State private var bits: [Bool]
    @State private var octal: String

    init(entry: RemoteEntry, apply: @escaping (String) -> Void) {
        self.entry = entry
        self.apply = apply
        // permissions: "-rw-r--r--" → биты из символов 1..9
        let chars = Array(entry.permissions.dropFirst().prefix(9))
        var b = [Bool](repeating: false, count: 9)
        for (i, ch) in chars.enumerated() where i < 9 {
            b[i] = ch != "-"
        }
        _bits = State(initialValue: b)
        _octal = State(initialValue: Self.octalString(from: b))
    }

    private static func octalString(from bits: [Bool]) -> String {
        var digits = ""
        for group in 0..<3 {
            let v = (bits[group * 3] ? 4 : 0)
                  + (bits[group * 3 + 1] ? 2 : 0)
                  + (bits[group * 3 + 2] ? 1 : 0)
            digits += String(v)
        }
        return digits
    }

    private static func bitsFrom(octal: String) -> [Bool]? {
        let digits = Array(octal.suffix(3))
        guard digits.count == 3 else { return nil }
        var b = [Bool](repeating: false, count: 9)
        for (group, ch) in digits.enumerated() {
            guard let v = Int(String(ch)), (0...7).contains(v) else { return nil }
            b[group * 3] = v & 4 != 0
            b[group * 3 + 1] = v & 2 != 0
            b[group * 3 + 2] = v & 1 != 0
        }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Права: \(entry.name)")
                .font(.headline)
            Text(entry.permissions)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    Text("Чтение").font(.caption)
                    Text("Запись").font(.caption)
                    Text("Выполнение").font(.caption)
                }
                permRow("Владелец", 0)
                permRow("Группа", 3)
                permRow("Остальные", 6)
            }

            HStack {
                Text("Октал:")
                TextField("644", text: $octal)
                    .frame(width: 64)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: octal) { _, newValue in
                        guard newValue != Self.octalString(from: bits),
                              let parsed = Self.bitsFrom(octal: newValue) else { return }
                        bits = parsed
                    }
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Применить") {
                    apply(Self.octalString(from: bits))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func permRow(_ title: String, _ offset: Int) -> some View {
        GridRow {
            Text(title)
            ForEach(0..<3, id: \.self) { i in
                Toggle("", isOn: Binding(
                    get: { bits[offset + i] },
                    set: { bits[offset + i] = $0; octal = Self.octalString(from: bits) }
                ))
                .labelsHidden()
            }
        }
    }
}
