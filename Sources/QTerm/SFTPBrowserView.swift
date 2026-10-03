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
    var owner: String = ""
    var modified: Date?
    /// Строка «..» — вверх (как у мобы).
    var isParent = false

    var isLink: Bool { permissions.hasPrefix("l") }
    var isHidden: Bool { !isParent && name.hasPrefix(".") }

    // Ключи сортировки колонок таблицы.
    var sortName: String { name.lowercased() }
    var sortSize: UInt64 { isDirectory ? 0 : size }
    var sortDate: Double { modified?.timeIntervalSince1970 ?? 0 }

    var sizeText: String {
        guard !isDirectory, !isParent else { return "" }
        switch size {
        case ..<1024: return "\(size) Б"
        case ..<(1024 * 1024): return String(format: "%.1f КБ", Double(size) / 1024)
        case ..<(1024 * 1024 * 1024): return String(format: "%.1f МБ", Double(size) / 1_048_576)
        default: return String(format: "%.2f ГБ", Double(size) / 1_073_741_824)
        }
    }

    var modifiedText: String {
        guard let modified else { return "" }
        return Self.displayFormatter.string(from: modified)
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yy HH:mm"
        return f
    }()

    private static let lsFormatters: [DateFormatter] = ["MMM d HH:mm", "MMM d yyyy"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    /// Строка ls -l / longname SFTP: perms links owner group size Mon DD time|year name.
    static func parse(longname: String, name: String, path: String, size: UInt64?) -> RemoteEntry {
        let tokens = longname.split(separator: " ", omittingEmptySubsequences: true)
        let perms = String(longname.prefix(10))
        var owner = ""
        var date: Date?
        var parsedSize = size ?? 0
        if tokens.count >= 8 {
            owner = String(tokens[2])
            if size == nil { parsedSize = UInt64(tokens[4]) ?? 0 }
            date = parseLsDate("\(tokens[5]) \(tokens[6]) \(tokens[7])")
        }
        return RemoteEntry(name: name, path: path, isDirectory: perms.hasPrefix("d"),
                           size: parsedSize, permissions: perms, details: longname,
                           owner: owner, modified: date)
    }

    /// «Sep 28 12:01» (текущий год; из будущего — прошлый) или «Sep 28 2024».
    static func parseLsDate(_ s: String) -> Date? {
        for f in lsFormatters {
            guard let d = f.date(from: s) else { continue }
            if f.dateFormat.hasSuffix("HH:mm") {
                let cal = Calendar.current
                var comps = cal.dateComponents([.month, .day, .hour, .minute], from: d)
                comps.year = cal.component(.year, from: Date())
                guard var full = cal.date(from: comps) else { return nil }
                if full > Date().addingTimeInterval(86_400) {
                    full = cal.date(byAdding: .year, value: -1, to: full) ?? full
                }
                return full
            }
            return d
        }
        return nil
    }
}

/// Ключи настроек проводника (вне MainActor — для @AppStorage).
enum FSKeys {
    static let showHidden = "fsShowHidden"
    static let follow = "fsFollowTerminal"
    static let externalEditor = "externalEditorApp"
}

/// Логика проводника: листинг, навигация, CRUD, скачивание/заливка,
/// правка через временный файл (download → open → watch → upload).
@MainActor
final class SFTPBrowser: ObservableObject {
    @Published var currentPath: String = "/root"
    @Published var entries: [RemoteEntry] = []
    @Published var busy = false
    @Published var errorText: String?
    /// Текст прогресса длинной операции («Скачивание 12/40: name»), nil — нет операции.
    @Published var progressText: String?
    /// Строка состояния (режим, число элементов, итог операции).
    @Published var statusText = ""
    /// Недавние папки (новые сверху), по ноде, переживают перезапуск.
    @Published private(set) var history: [String] = []
    /// Домашняя папка на сервере (для «~» и меню недавних).
    @Published private(set) var homeDir = ""
    /// Первый листинг после подключения уже был — повторно не дёргаем.
    var didInitialList = false
    /// Один авторетрай первого листинга (гонка с подъёмом shell-каналов).
    private var didRetryInitial = false

    private weak var connection: SSHConnection?
    private let sessionID: UUID
    private var editWatchers: [String: DispatchSourceFileSystemObject] = [:]

    /// Временная папка перетаскивания наружу (дроп из неё в себя — игнор).
    static let dragRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("qterm-drag", isDirectory: true)

    init(connection: SSHConnection) {
        self.connection = connection
        self.sessionID = connection.session.id
        // Стартовый путь проводника из настроек сессии.
        if let start = connection.session.extra["sftpPath"]?.trimmingCharacters(in: .whitespaces),
           !start.isEmpty {
            currentPath = start
        }
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    private var historyKey: String { "fsHistory.\(sessionID.uuidString)" }
    var startPath: String? {
        let s = connection?.session.extra["sftpPath"]?.trimmingCharacters(in: .whitespaces)
        return (s?.isEmpty ?? true) ? nil : s
    }

    private var sftp: SFTPClient? { connection?.sftp }
    /// Командный режим: соединение живо, SFTP нет — работаем через exec.
    var execMode: Bool { connection?.status == .connected && connection?.sftp == nil }
    /// Проводнику есть чем работать (любой из бэкендов).
    private var backendReady: Bool { sftp != nil || execMode }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

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
                let size = component.attributes.size.map { UInt64($0) }
                result.append(RemoteEntry.parse(longname: component.longname, name: fname,
                                                path: Self.join(path, fname), size: size))
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
            result.append(RemoteEntry.parse(longname: String(line), name: name,
                                            path: join(path, name), size: nil))
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
            if homeDir.isEmpty { await loadHomeDir() }
            do {
                let result = try await listEntries(at: path)
                self.entries = result
                self.currentPath = path
                self.errorText = nil
                self.remember(path)
                self.statusText = "Режим: \(self.sftp != nil ? "SFTP" : "команды (exec)") · элементов: \(result.count)"
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

    private func loadHomeDir() async {
        guard let connection else { return }
        if let out = try? await connection.exec("printf '%s' \"$HOME\""),
           out.hasPrefix("/") {
            homeDir = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func remember(_ path: String) {
        var h = history.filter { $0 != path }
        h.insert(path, at: 0)
        if h.count > 15 { h = Array(h.prefix(15)) }
        guard h != history else { return }
        history = h
        UserDefaults.standard.set(h, forKey: historyKey)
    }

    /// Путь из строки ввода: «~» → домашняя.
    func navigate(typed: String) {
        var p = typed.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        if p.hasPrefix("~"), !homeDir.isEmpty {
            p = homeDir.hasSuffix("/") ? String(homeDir.dropLast()) + p.dropFirst() : homeDir + p.dropFirst()
        }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        list(path: p)
    }

    func enter(_ entry: RemoteEntry) {
        guard entry.isDirectory else { return }
        list(path: entry.path)
    }

    func goUp() {
        guard currentPath != "/" else { return }
        list(path: Self.parent(currentPath))
    }

    /// Симлинк: сначала пробуем как папку, не вышло — это файл.
    func linkIsDirectory(_ entry: RemoteEntry) async -> Bool {
        (try? await listEntries(at: entry.path)) != nil
    }

    // MARK: - Следовать за папкой терминала (заголовок «user@host: путь» / OSC 7)

    func followTerminal(raw: String, osc7: Bool) {
        guard UserDefaults.standard.bool(forKey: FSKeys.follow), !busy, backendReady else { return }
        var path: String?
        if osc7 {
            if let u = URL(string: raw), u.isFileURL { path = u.path }
            else if raw.hasPrefix("/") { path = raw }
        } else if let m = raw.range(of: #"^[^@\s:]+@[^:\s]+\s*:\s*"#, options: .regularExpression) {
            var p = String(raw[m.upperBound...]).trimmingCharacters(in: .whitespaces)
            if p == "~" { p = homeDir }
            else if p.hasPrefix("~/"), !homeDir.isEmpty { p = Self.join(homeDir, String(p.dropFirst(2))) }
            path = p
        }
        guard var p = path, p.hasPrefix("/") else { return }
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        guard p != currentPath else { return }
        list(path: p)
    }

    // MARK: - CRUD

    func mkdir(name: String) {
        let path = Self.join(currentPath, name)
        Task {
            do {
                if let sftp {
                    try await sftp.createDirectory(atPath: path)
                } else if let connection, execMode {
                    _ = try await connection.exec("mkdir \(SSHConnection.shellEscape(path))")
                }
                statusText = "Создана папка \(name)"
                refresh()
            }
            catch { errorText = "mkdir: \(error)" }
        }
    }

    /// Пустой файл в текущей папке (дальше — в редактор).
    func newFile(name: String) async -> String? {
        guard let connection else { return nil }
        if entries.contains(where: { $0.name == name }) {
            errorText = "«\(name)» уже есть"
            return nil
        }
        let path = Self.join(currentPath, name)
        do {
            try await connection.writeFile(path: path, data: Data())
            statusText = "Создан \(name)"
            refresh()
            return path
        } catch {
            errorText = "Новый файл: \(error)"
            return nil
        }
    }

    func delete(_ targets: [RemoteEntry]) {
        guard backendReady, !targets.isEmpty else { return }
        busy = true
        Task {
            do {
                for entry in targets {
                    if sftp != nil {
                        if entry.isDirectory {
                            try await deleteRecursively(entry.path)
                        } else {
                            try await sftp?.remove(at: entry.path)
                        }
                    } else if let connection {
                        _ = try await connection.exec("rm -rf \(SSHConnection.shellEscape(entry.path))")
                    }
                }
                statusText = "Удалено: \(targets.count)"
            } catch { errorText = "Удаление: \(error)" }
            busy = false
            refresh()
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
        let newPath = Self.join(currentPath, newName)
        Task {
            do {
                if let sftp {
                    try await sftp.rename(at: entry.path, to: newPath)
                } else if let connection {
                    _ = try await connection.exec(
                        "mv \(SSHConnection.shellEscape(entry.path)) \(SSHConnection.shellEscape(newPath))")
                }
                statusText = "\(entry.name) → \(newName)"
                refresh()
            }
            catch { errorText = "Переименование: \(error)" }
        }
    }

    /// chmod через exec-канал соединения (busybox chmod есть везде).
    func chmod(_ targets: [RemoteEntry], octal: String) {
        guard let connection, !targets.isEmpty else { return }
        Task {
            do {
                let paths = targets.map { SSHConnection.shellEscape($0.path) }.joined(separator: " ")
                let out = try await connection.exec("chmod \(octal) \(paths) 2>&1")
                let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                errorText = trimmed.isEmpty ? nil : "chmod: \(trimmed)"
                if trimmed.isEmpty { statusText = "chmod \(octal): \(targets.count)" }
                refresh()
            } catch { errorText = "chmod: \(error)" }
        }
    }

    // MARK: - Transfer

    /// Скачать выделенное в локальную папку (файлы и папки рекурсивно).
    func download(_ targets: [RemoteEntry], toDirectory dir: URL) {
        guard backendReady, !targets.isEmpty else { return }
        busy = true
        Task {
            do {
                var done = 0
                for entry in targets {
                    try await downloadEntry(entry, to: dir.appendingPathComponent(entry.name), done: &done)
                }
                self.progressText = nil
                self.errorText = nil
                self.statusText = "Скачано в \(dir.path): \(done)"
            } catch {
                self.progressText = nil
                self.errorText = "Скачивание: \(error)"
            }
            self.busy = false
        }
    }

    /// Один объект по выбранному пути (сохранение через NSSavePanel).
    func download(_ entry: RemoteEntry, to localURL: URL) {
        guard backendReady else { return }
        busy = true
        Task {
            do {
                var done = 0
                try await downloadEntry(entry, to: localURL, done: &done)
                self.progressText = nil
                self.errorText = nil
            } catch {
                self.progressText = nil
                self.errorText = "Скачивание: \(error)"
            }
            self.busy = false
        }
    }

    private func downloadEntry(_ entry: RemoteEntry, to localURL: URL, done: inout Int) async throws {
        if entry.isDirectory {
            try await downloadRecursively(entry, to: localURL, done: &done)
        } else {
            done += 1
            progressText = "Скачивание \(done): \(entry.name)"
            try await downloadFile(remotePath: entry.path, to: localURL)
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

    /// Перетаскивание наружу: копия во временной папке (её и отдаём Finder'у).
    func downloadForDrag(_ entry: RemoteEntry) async throws -> URL {
        let dir = Self.dragRoot.appendingPathComponent(UUID().uuidString.prefix(8).description, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent(entry.name)
        var done = 0
        try await downloadEntry(entry, to: local, done: &done)
        progressText = nil
        statusText = "Перетащено: \(entry.name)"
        return local
    }

    func upload(localURL: URL) {
        upload([localURL], to: currentPath)
    }

    /// Файлы/папки с диска → в удалённую папку (папки рекурсивно).
    func upload(_ urls: [URL], to remoteDir: String) {
        // Дроп нашего же перетаскивания обратно в панель — не заливаем копию.
        let dragPrefix = Self.dragRoot.standardizedFileURL.path
        let items = urls.filter { !$0.standardizedFileURL.path.hasPrefix(dragPrefix) }
        guard backendReady, !items.isEmpty else { return }
        busy = true
        Task {
            do {
                var done = 0
                for url in items {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    let remote = Self.join(remoteDir, url.lastPathComponent)
                    if isDir.boolValue {
                        try await uploadRecursively(localURL: url, remotePath: remote, done: &done)
                    } else {
                        done += 1
                        progressText = "Заливка \(done): \(url.lastPathComponent)"
                        try await uploadFile(localURL: url, remotePath: remote)
                    }
                }
                self.progressText = nil
                self.statusText = "Залито: \(done)"
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
            let childRemote = Self.join(remotePath, child.lastPathComponent)
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

    // MARK: - Внешний редактор (download → open → watch → upload)

    /// Внешний редактор из настроек (nil — программа по умолчанию).
    static var externalEditor: URL? {
        guard let p = UserDefaults.standard.string(forKey: FSKeys.externalEditor), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// app == nil — программой по умолчанию.
    func edit(_ entry: RemoteEntry, app: URL? = nil) {
        guard !entry.isDirectory, let connection else { return }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qterm-edit", isDirectory: true)
            .appendingPathComponent(String(entry.path.hashValue & 0xFFFFFF, radix: 16), isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let localURL = tmpDir.appendingPathComponent(entry.name)
        Task {
            do {
                let data = try await connection.readFile(path: entry.path)
                try data.write(to: localURL)
            } catch {
                errorText = "Открытие \(entry.name): \(error)"
                return
            }
            watch(localURL: localURL, remotePath: entry.path)
            if let app {
                let cfg = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([localURL], withApplicationAt: app, configuration: cfg) { _, err in
                    if let err {
                        Task { @MainActor in self.errorText = "Открытие: \(err.localizedDescription)" }
                    }
                }
            } else {
                NSWorkspace.shared.open(localURL)
            }
            statusText = "Правка \(entry.name): сохранение в редакторе заливает на сервер"
        }
    }

    /// Сохранение в редакторе → заливка. Редакторы с атомарной записью
    /// (VS Code, BBEdit: пишут новый файл и переименовывают) рвут vnode-
    /// наблюдатель старого файла — на rename/delete переустанавливаем его
    /// на новый файл по тому же пути, иначе вторая правка терялась.
    private func watch(localURL: URL, remotePath: String) {
        editWatchers[remotePath]?.cancel()
        editWatchers[remotePath] = nil
        let fd = open(localURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let src = self.editWatchers[remotePath] else { return }
                let replaced = !src.data.intersection([.rename, .delete]).isEmpty
                if replaced {
                    // Дать редактору дописать новый файл, затем залить и следить за ним.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        MainActor.assumeIsolated {
                            guard FileManager.default.fileExists(atPath: localURL.path) else { return }
                            self.pushEdited(localURL: localURL, remotePath: remotePath)
                            self.watch(localURL: localURL, remotePath: remotePath)
                        }
                    }
                } else {
                    self.pushEdited(localURL: localURL, remotePath: remotePath)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        editWatchers[remotePath] = source
    }

    private func pushEdited(localURL: URL, remotePath: String) {
        guard let connection else { return }
        Task {
            do {
                let data = try Data(contentsOf: localURL)
                try await connection.writeFile(path: remotePath, data: data)
                statusText = "Залито: \((remotePath as NSString).lastPathComponent)"
            } catch {
                errorText = "Автозаливка \((remotePath as NSString).lastPathComponent): \(error)"
            }
        }
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
    private var connectionStatus: SSHConnection.Status { connection.status }

    @AppStorage(FSKeys.showHidden) private var showHidden = true
    @AppStorage(FSKeys.follow) private var follow = false
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\RemoteEntry.sortName)]
    @State private var pathDraft = ""

    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var newFileName = ""
    @State private var showNewFile = false
    /// Диалог прав: образец (первый выделенный) + все цели.
    @State private var permEntry: RemoteEntry?
    @State private var permTargets: [RemoteEntry] = []
    /// Файл в диалоге переименования + вводимое имя.
    @State private var renameEntry: RemoteEntry?
    @State private var renameText = ""

    // MARK: Строки таблицы

    private var rows: [RemoteEntry] {
        var items = browser.entries
        if !showHidden { items = items.filter { !$0.isHidden } }
        let dirs = items.filter(\.isDirectory).sorted(using: sortOrder)
        let files = items.filter { !$0.isDirectory }.sorted(using: sortOrder)
        var out: [RemoteEntry] = []
        if browser.currentPath != "/" {
            out.append(RemoteEntry(name: "..", path: SFTPBrowser.parent(browser.currentPath) + "\u{0}..",
                                   isDirectory: true, size: 0, permissions: "", details: "", isParent: true))
        }
        return out + dirs + files
    }

    private func entries(_ ids: Set<String>) -> [RemoteEntry] {
        browser.entries.filter { ids.contains($0.id) }
    }

    private var selected: [RemoteEntry] { entries(selection) }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            pathBar
            table
            footer
            if connectionStatus == .connected && connection.sftp == nil {
                Divider()
                execModeBanner
            }
        }
        .onAppear {
            pathDraft = browser.currentPath
            if !browser.didInitialList { browser.refresh() }
        }
        .onChange(of: browser.currentPath) { _, p in
            pathDraft = p
            selection.removeAll()
        }
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
                let n = newFolderName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { browser.mkdir(name: n) }
                newFolderName = ""
            }
            Button("Отмена", role: .cancel) { newFolderName = "" }
        }
        .alert("Новый файл", isPresented: $showNewFile) {
            TextField("Имя", text: $newFileName)
            Button("Создать") {
                let n = newFileName.trimmingCharacters(in: .whitespaces)
                newFileName = ""
                guard !n.isEmpty else { return }
                createFile(n)
            }
            Button("Отмена", role: .cancel) { newFileName = "" }
        } message: {
            Text("Пустой файл в \(browser.currentPath) — сразу откроется в редакторе")
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
            PermissionsSheet(entry: entry, count: permTargets.count) { octal in
                browser.chmod(permTargets, octal: octal)
            }
        }
    }

    // MARK: Тулбар (порядок мобы)

    private var toolbar: some View {
        FlowLayout(spacing: 2) {
            tool("arrow.up", .blue, "Вверх (⌫)") { browser.goUp() }
                .disabled(browser.currentPath == "/")
            tool("square.and.arrow.down", .blue, "Скачать выделенное (файлы и папки)") { pickAndDownload(selected) }
                .disabled(selected.isEmpty)
            tool("square.and.arrow.up", .green, "Залить файлы/папки сюда (или перетащи из Finder)") { pickAndUpload() }
            tool("arrow.clockwise", .green, "Обновить (F5)") { browser.refresh() }
            tool("folder.badge.plus", .orange, "Новая папка") { showNewFolder = true }
            tool("doc.badge.plus", .secondary, "Новый файл (откроется в редакторе)") { showNewFile = true }
            tool("trash", .red, "Удалить выделенное (⌘⌫)") { confirmDelete(selected) }
                .disabled(selected.isEmpty)
            tool("lock.shield", .orange, "Права (chmod)") { openPermissions(selected) }
                .disabled(selected.isEmpty)
            tool("pencil.and.outline", .blue, "Открыть в редакторе (↩)") {
                for e in selected where !e.isDirectory { openInEditor(e) }
            }
            .disabled(!selected.contains { !$0.isDirectory })
            tool(showHidden ? "eye" : "eye.slash", .purple,
                 showHidden ? "Скрытые файлы (.dot) показаны — спрятать" : "Скрытые файлы (.dot) спрятаны — показать") {
                showHidden.toggle()
            }
            tool("house", .orange, "Сделать текущую папку стартовой для ноды (синкается)") { setAsStartPath() }
            tool("terminal", .secondary, "Перейти в терминале в эту папку (cd)") { cdHere() }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
    }

    private func tool(_ symbol: String, _ color: Color, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: Путь + недавние

    private var pathBar: some View {
        HStack(spacing: 4) {
            TextField("Путь — ↩ для перехода", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .onSubmit { browser.navigate(typed: pathDraft) }
            Menu {
                ForEach(browser.history, id: \.self) { p in
                    Button {
                        browser.list(path: p)
                    } label: {
                        if p == browser.currentPath { Label(p, systemImage: "checkmark") } else { Text(p) }
                    }
                }
                if !browser.history.isEmpty { Divider() }
                if !browser.homeDir.isEmpty {
                    Button("Домашняя папка  \(browser.homeDir)") { browser.list(path: browser.homeDir) }
                }
                Button("Корень  /") { browser.list(path: "/") }
                if let start = browser.startPath {
                    Button("Стартовая папка  \(start)") { browser.list(path: start) }
                }
                Divider()
                Button("Скопировать путь") { copyToPasteboard(browser.currentPath) }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Недавние папки")
        }
        .padding(6)
    }

    // MARK: Таблица

    private var table: some View {
        Table(of: RemoteEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Имя", value: \RemoteEntry.sortName) { e in nameCell(e) }
                .width(min: 110, ideal: 170)
            TableColumn("Размер", value: \RemoteEntry.sortSize) { e in
                Text(e.sizeText).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 64)
            TableColumn("Дата", value: \RemoteEntry.sortDate) { e in
                Text(e.modifiedText).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 100)
            TableColumn("Права", value: \RemoteEntry.permissions) { e in
                Text(e.permissions).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 82)
            TableColumn("Владелец", value: \RemoteEntry.owner) { e in
                Text(e.owner).foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 64)
        } rows: {
            ForEach(rows) { e in
                TableRow(e)
                    .itemProvider { e.isParent ? nil : dragProvider(e) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            openItems(ids)
        }
        .onKeyPress(keys: [.return, .delete, .deleteForward, Self.f2, Self.f5]) { press in
            handleKey(press)
        }
        .onCopyCommand {
            let paths = selectedPathsOrCurrent()
            return [NSItemProvider(object: paths.joined(separator: "\n") as NSString)]
        }
        .dropDestination(for: URL.self) { urls, _ in
            browser.upload(urls, to: browser.currentPath)
            return !urls.isEmpty
        }
    }

    private func nameCell(_ e: RemoteEntry) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon(e))
                .foregroundStyle(iconColor(e))
                .frame(width: 16)
            Text(e.name + (e.isLink ? " →" : ""))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .opacity(e.isHidden ? 0.6 : 1)
        .help(e.isParent ? "Вверх" : e.details)
    }

    private func icon(_ e: RemoteEntry) -> String {
        if e.isParent { return "arrow.turn.left.up" }
        if e.isLink { return "link" }
        if e.isDirectory { return "folder.fill" }
        let ext = (e.name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh", "py", "js", "ts", "go", "rs", "swift", "kt", "c", "h", "cpp", "rb", "pl", "php": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "conf", "cfg", "ini", "xml": return "gearshape"
        case "log", "txt", "md": return "doc.text"
        case "zip", "gz", "tgz", "xz", "bz2", "tar", "7z", "ipk", "deb", "rpm": return "archivebox"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico": return "photo"
        case "pem", "key", "crt", "pub", "cer": return "key"
        default: return e.permissions.contains("x") ? "gearshape.2" : "doc"
        }
    }

    private func iconColor(_ e: RemoteEntry) -> Color {
        if e.isParent { return .secondary }
        if e.isLink { return .teal }
        if e.isDirectory { return .blue }
        return .secondary
    }

    // MARK: Клавиатура

    private static let f2 = KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
    private static let f5 = KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!))

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let cmd = press.modifiers.contains(.command)
        switch press.key {
        case .return:
            openItems(selection)
        case .delete where cmd, .deleteForward:
            confirmDelete(selected)
        case .delete:
            browser.goUp()
        case Self.f2:
            if let one = selected.first, selected.count == 1 { startRename(one) }
        case Self.f5:
            browser.refresh()
        default:
            return .ignored
        }
        return .handled
    }

    // MARK: Контекстное меню (порядок мобы)

    @ViewBuilder
    private func rowMenu(_ ids: Set<String>) -> some View {
        let sel = entries(ids)
        let one = sel.count == 1 ? sel.first : nil
        let files = sel.filter { !$0.isDirectory }
        if !sel.isEmpty {
            Button(one?.isDirectory == true ? "Открыть папку" : "Открыть") { openItems(ids) }
            if !files.isEmpty {
                Button("Открыть во внешнем редакторе") {
                    for f in files { browser.edit(f, app: SFTPBrowser.externalEditor) }
                }
                if let one, !one.isDirectory {
                    Button("Открыть с помощью…") { openWith(one) }
                }
                Button("Открыть программой по умолчанию") {
                    for f in files { browser.edit(f) }
                }
            }
            Divider()
            Button(sel.count == 1 ? "Скачать…" : "Скачать (\(sel.count))…") { pickAndDownload(sel) }
            Divider()
            Button(sel.count == 1 ? "Удалить" : "Удалить (\(sel.count))", role: .destructive) { confirmDelete(sel) }
            Button("Переименовать…") { if let one { startRename(one) } }
                .disabled(one == nil)
            Divider()
            Button(sel.count == 1 ? "Копировать путь" : "Копировать пути") {
                copyToPasteboard(sel.map(\.path).joined(separator: "\n"))
            }
            Button("Копировать имя") { copyToPasteboard(sel.map(\.name).joined(separator: "\n")) }
            Button("Путь в терминал") { pathsToTerminal(sel.map(\.path)) }
            if let one, one.isDirectory {
                Button("Перейти в терминале (cd)") { sendToTerminal("cd \(shellQuote(one.path))\n") }
            }
            Divider()
            Button("Свойства") { if let one { showProperties(one) } }
                .disabled(one == nil)
            Button("Права (chmod)…") { openPermissions(sel) }
            Divider()
        }
        Button("Обновить") { browser.refresh() }
        Button("Новая папка…") { showNewFolder = true }
        Button("Новый файл…") { showNewFile = true }
        Button("Залить сюда…") { pickAndUpload() }
        if sel.isEmpty {
            Divider()
            Button("Копировать путь папки") { copyToPasteboard(browser.currentPath) }
            Button("Перейти в терминале (cd)") { cdHere() }
            Button("Сделать стартовой папкой ноды") { setAsStartPath() }
        }
    }

    // MARK: Низ: следовать за терминалом + статус

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle("Следовать за папкой терминала", isOn: $follow)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Панель переходит туда, куда ты сделал cd (по заголовку окна шелла «user@host: путь» или OSC 7)")
            if let progress = browser.progressText {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let err = browser.errorText {
                Text(err)
                    .font(.caption2).foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if !browser.statusText.isEmpty {
                Text(browser.statusText)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

    // MARK: Действия

    /// Двойной клик / ↩: папка — войти, «..» — вверх, симлинк — как папку,
    /// не вышло — как файл; файлы — в редактор (несколько — все).
    private func openItems(_ ids: Set<String>) {
        if rows.contains(where: { $0.isParent && ids.contains($0.id) }) {
            browser.goUp()
            return
        }
        let sel = entries(ids)
        if sel.count == 1, let e = sel.first {
            if e.isDirectory { browser.enter(e); return }
            if e.isLink {
                Task {
                    if await browser.linkIsDirectory(e) { browser.list(path: e.path) } else { openInEditor(e) }
                }
                return
            }
        }
        for e in sel where !e.isDirectory { openInEditor(e) }
    }

    private func startRename(_ e: RemoteEntry) {
        renameText = e.name
        renameEntry = e
    }

    private func openPermissions(_ sel: [RemoteEntry]) {
        guard let first = sel.first else { return }
        permTargets = sel
        permEntry = first
    }

    private func confirmDelete(_ sel: [RemoteEntry]) {
        guard !sel.isEmpty else { return }
        let what: String
        if sel.count == 1, let e = sel.first {
            what = "\(e.isDirectory ? "папку" : "файл") «\(e.name)»\(e.isDirectory ? " со всем содержимым" : "")"
        } else {
            let list = sel.prefix(12).map { "  " + $0.name + ($0.isDirectory ? "/" : "") }.joined(separator: "\n")
            what = "\(sel.count) объектов:\n\(list)\(sel.count > 12 ? "\n  …" : "")"
        }
        let alert = NSAlert()
        alert.messageText = "Удалить \(what)?"
        alert.informativeText = "На сервере \(connection.session.name), без корзины."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        browser.delete(sel)
    }

    private func createFile(_ name: String) {
        let session = connection.session
        Task {
            guard let path = await browser.newFile(name: name) else { return }
            do {
                try state.editor.open(remotePath: path, data: Data(),
                                      sessionID: session.id, nodeName: session.name)
            } catch {
                browser.errorText = "Редактор: \(error.localizedDescription)"
            }
        }
    }

    private func openWith(_ e: RemoteEntry) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Открыть"
        panel.message = "Программа для «\(e.name)» (сохранение в ней заливает файл на сервер)"
        if panel.runModal() == .OK, let app = panel.url {
            browser.edit(e, app: app)
        }
    }

    private func dragProvider(_ e: RemoteEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = e.name
        let type = e.isDirectory ? UTType.folder : UTType.data
        let browser = browser
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                            fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    let url = try await browser.downloadForDrag(e)
                    completion(url, false, nil)
                } catch {
                    browser.errorText = "Перетаскивание: \(error.localizedDescription)"
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    private func selectedPathsOrCurrent() -> [String] {
        let sel = selected
        return sel.isEmpty ? [browser.currentPath] : sel.map(\.path)
    }

    private func shellQuote(_ p: String) -> String {
        p.range(of: #"^[A-Za-z0-9_./@%+=:,\-]+$"#, options: .regularExpression) != nil
            ? p : SSHConnection.shellEscape(p)
    }

    private func pathsToTerminal(_ paths: [String]) {
        sendToTerminal(paths.map(shellQuote).joined(separator: " ") + " ")
    }

    private func cdHere() {
        let target: String
        if selected.count == 1, let one = selected.first, one.isDirectory { target = one.path } else { target = browser.currentPath }
        sendToTerminal("cd \(shellQuote(target))\n")
        browser.statusText = "Терминал: cd \(target)"
    }

    /// Вставка текста в терминал этой ноды (активная её вкладка, иначе первая).
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
        browser.statusText = text.contains("\n") ? "Скопировано путей: \(text.split(separator: "\n").count)" : "Скопировано: \(text)"
    }

    /// Свойства: полная строка ls -l с сервера.
    private func showProperties(_ entry: RemoteEntry) {
        Dialogs.info("""
        \(entry.name)

        Путь: \(entry.path)
        Размер: \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
        Владелец: \(entry.owner)
        Изменён: \(entry.modifiedText)

        \(entry.details)
        """)
    }

    /// Текущий каталог проводника → стартовый путь этой сессии (сохраняется в вейлт).
    private func setAsStartPath() {
        var s = connection.session
        s.extra["sftpPath"] = browser.currentPath
        state.upsert(s)
        browser.statusText = "Стартовая папка ноды: \(browser.currentPath)"
    }

    /// Файл: скачиваем в память → вкладка в окне редактора.
    private func openInEditor(_ entry: RemoteEntry) {
        guard entry.size <= EditorBridge.maxEditableSize else {
            browser.errorText = "«\(entry.name)» больше 2 МБ — открой через скачивание или внешний редактор"
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
                browser.errorText = nil
            } catch {
                browser.errorText = "Редактор: \(error.localizedDescription)"
            }
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true // папки — целиком, рекурсивно
        panel.prompt = "Залить"
        if panel.runModal() == .OK {
            browser.upload(panel.urls, to: browser.currentPath)
        }
    }

    private func pickAndDownload(_ sel: [RemoteEntry]) {
        guard !sel.isEmpty else { return }
        if sel.count == 1, let entry = sel.first, !entry.isDirectory {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            if panel.runModal() == .OK, let url = panel.url {
                browser.download(entry, to: url)
            }
            return
        }
        // Несколько объектов или папка: выбираем локальный каталог-назначение.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Скачать сюда"
        if panel.runModal() == .OK, let dir = panel.url {
            browser.download(sel, toDirectory: dir)
        }
    }
}

// MARK: - Диалог прав (как в мобе: чекбоксы rwx + октал)

struct PermissionsSheet: View {
    let entry: RemoteEntry
    /// Сколько объектов получат права (выделение).
    var count: Int = 1
    let apply: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 9 бит: [u_r, u_w, u_x, g_r, g_w, g_x, o_r, o_w, o_x]
    @State private var bits: [Bool]
    @State private var octal: String

    init(entry: RemoteEntry, count: Int = 1, apply: @escaping (String) -> Void) {
        self.entry = entry
        self.count = count
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
            Text(count > 1 ? "Права: \(count) объектов" : "Права: \(entry.name)")
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
