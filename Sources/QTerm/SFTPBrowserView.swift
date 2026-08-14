import SwiftUI
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

    private weak var connection: SSHConnection?
    private var editWatchers: [String: DispatchSourceFileSystemObject] = [:]

    init(connection: SSHConnection) {
        self.connection = connection
    }

    private var sftp: SFTPClient? { connection?.sftp }

    /// Листинг каталога -> [RemoteEntry] (общий для UI и рекурсивных операций).
    private func listEntries(at path: String) async throws -> [RemoteEntry] {
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
                    permissions: String(longname.prefix(10))
                ))
            }
        }
        return result
    }

    // MARK: - Listing / navigation

    func refresh() {
        list(path: currentPath)
    }

    func list(path: String) {
        guard sftp != nil else { return }
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
                self.errorText = "Листинг \(path): \(error)"
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
        guard let sftp else { return }
        let path = currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
        Task {
            do { try await sftp.createDirectory(atPath: path); refresh() }
            catch { errorText = "mkdir: \(error)" }
        }
    }

    func delete(_ entry: RemoteEntry) {
        guard sftp != nil else { return }
        Task {
            do {
                if entry.isDirectory {
                    try await deleteRecursively(entry.path)
                } else {
                    try await sftp?.remove(at: entry.path)
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
        guard let sftp else { return }
        let newPath = (currentPath as NSString).appendingPathComponent(newName)
        Task {
            do { try await sftp.rename(at: entry.path, to: newPath); refresh() }
            catch { errorText = "Переименование: \(error)" }
        }
    }

    // MARK: - Transfer

    func download(_ entry: RemoteEntry, to localURL: URL) {
        guard sftp != nil else { return }
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
        guard let sftp else { return }
        let data = try await sftp.withFile(filePath: remotePath, flags: .read) { file in
            try await file.readAll()
        }
        try Data(buffer: data).write(to: localURL)
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
        guard sftp != nil else { return }
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
        guard let sftp else { return }
        let data = try Data(contentsOf: localURL)
        try await sftp.withFile(
            filePath: remotePath,
            flags: [.write, .create, .truncate]
        ) { file in
            try await file.write(ByteBuffer(data: data), at: 0)
        }
    }

    private func uploadRecursively(localURL: URL, remotePath: String, done: inout Int) async throws {
        guard let sftp else { return }
        // Каталог может уже существовать — это не ошибка.
        try? await sftp.createDirectory(atPath: remotePath)
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
            guard let self, let sftp = self.sftp else { return }
            Task {
                do {
                    let data = try Data(contentsOf: localURL)
                    try await sftp.withFile(
                        filePath: entry.path,
                        flags: [.write, .create, .truncate]
                    ) { file in
                        try await file.write(ByteBuffer(data: data), at: 0)
                    }
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
    @StateObject var browser: SFTPBrowser
    private var connectionStatus: SSHConnection.Status { connection.status }
    @State private var newFolderName = ""
    @State private var showNewFolder = false

    init(connection: SSHConnection) {
        self.connection = connection
        _browser = StateObject(wrappedValue: SFTPBrowser(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: browser.goUp) { Image(systemName: "arrow.up") }
                    .disabled(browser.currentPath == "/")
                Text(browser.currentPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
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
                    entry.isDirectory ? browser.enter(entry) : browser.edit(entry)
                }
                .contextMenu {
                    if !entry.isDirectory {
                        Button("Редактировать") { browser.edit(entry) }
                    }
                    Button(entry.isDirectory ? "Скачать папку…" : "Скачать…") { pickAndDownload(entry) }
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
        }
        .onAppear { browser.refresh() }
        .onChange(of: connectionStatus) { _, st in
            if st == .connected { browser.refresh() }
        }
        .onDisappear { browser.stopWatchers() }
        .alert("Новая папка", isPresented: $showNewFolder) {
            TextField("Имя", text: $newFolderName)
            Button("Создать") {
                browser.mkdir(name: newFolderName)
                newFolderName = ""
            }
            Button("Отмена", role: .cancel) {}
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
