import SwiftUI
import AppKit
import CoreServices

/// Мост к отдельному приложению QEditor.app (своё репо: github.com/Q00000P/QEditor).
///
/// Редактор — самостоятельное приложение (своя иконка в доке, ⌘Tab, окна),
/// но SSH оно не знает: файл читает и заливает QTerm, а редактор только
/// показывает текст и просит сохранить. Обмен — EditorIPC (копия файла в обоих
/// репо, версия протокола сверяется по ready).
@MainActor
final class EditorBridge: ObservableObject {

    weak var app: AppState?
    /// Открытые в редакторе файлы: docID → (нода, путь).
    private var routes: [String: (sessionID: UUID, path: String, node: String)] = [:]
    private var token: NSObjectProtocol?

    /// Файлы больше лимита в редактор не открываем — только скачивание.
    static let maxEditableSize: UInt64 = 2 * 1024 * 1024
    /// PDF (волна 19): вкладка-просмотрщик, байты не декодируются — лимит выше.
    static let maxPDFSize: UInt64 = 64 * 1024 * 1024

    static func isPDFName(_ name: String) -> Bool { name.lowercased().hasSuffix(".pdf") }
    /// Документы (DOCX/ODT — zip, бинарные): QEditor открывает их вкладкой «Документ».
    static func isDocName(_ name: String) -> Bool { [".docx", ".odt"].contains { name.lowercased().hasSuffix($0) } }

    static func maxEditableSize(for name: String) -> UInt64 {
        isPDFName(name) || isDocName(name) ? maxPDFSize : maxEditableSize
    }

    static func maxEditableText(for name: String) -> String {
        isPDFName(name) || isDocName(name) ? "64 МБ" : "2 МБ"
    }

    enum OpenError: LocalizedError {
        case binary
        case editorMissing
        var errorDescription: String? {
            switch self {
            case .binary: return "Похоже на бинарный файл — открой через скачивание или внешний редактор"
            case .editorMissing: return "QEditor.app не найден внутри QTerm.app — собери QEditor (../QEditor/macos/make-app.sh) и пересобери QTerm"
            }
        }
    }

    init() {
        EditorIPC.sweep()
        token = EditorIPC.listen(EditorIPC.toHost) { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        // вложенный редактор — в LaunchServices: Finder предлагает его для любых файлов (и без расширения)
        if let url = editorAppURL {
            DispatchQueue.global(qos: .utility).async { _ = LSRegisterURL(url as CFURL, true) }
        }
    }

    // MARK: Путь к приложению и запуск

    /// QEditor.app: вложенный в бандл хоста (make-app.sh кладёт его из ../QEditor/macos/build) или
    /// поставленный отдельно — самообновление редактора ставит новые версии в ~/Applications/QEditor.app
    /// (бандл QTerm не трогает, чтобы не ломать его подпись). Берём самый новый из найденных.
    private var editorAppURL: URL? {
        let fm = FileManager.default
        var found: [URL] = []
        let lib = Bundle.main.bundleURL.appendingPathComponent("Contents/Library")
        for name in ["QEditor.app", "QTermEditor.app"] {
            let u = lib.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { found.append(u); break }
        }
        for u in [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/QEditor.app"), URL(fileURLWithPath: "/Applications/QEditor.app")]
        where fm.fileExists(atPath: u.appendingPathComponent("Contents/MacOS/QEditor").path) {
            found.append(u)
        }
        // Запуск из .build (разработка): готовая сборка соседнего репо QEditor.
        if found.isEmpty {
            let dev = Bundle.main.bundleURL.deletingLastPathComponent()
            for rel in ["QEditor.app", "../../../../QEditor/macos/build/QEditor.app", "../../../QEditor/macos/build/QEditor.app"] {
                let u = dev.appendingPathComponent(rel).standardizedFileURL
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        return found.max { Self.editorVersion($0).lexicographicallyPrecedes(Self.editorVersion($1)) }
    }

    /// Версия бандла редактора: X.Y.Z и номер билда (у CI-сборок — номер прогона) для сравнения.
    private static func editorVersion(_ app: URL) -> [Int] {
        // Info.plist читаем напрямую: Bundle(url:) кеширует и после обновления отдал бы старую версию
        let info = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]) ?? [:]
        var v = (info["CFBundleShortVersionString"] as? String ?? "0").split(separator: ".").compactMap { Int($0) }
        while v.count < 3 { v.append(0) }
        let ci = (info["QEditorChannel"] as? String) == "ci"
        v = Array(v.prefix(3)) + [ci ? Int(info["CFBundleVersion"] as? String ?? "0") ?? 0 : 0]
        return v
    }

    var isEditorRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: EditorIPC.editorBundleID).isEmpty
    }

    /// Поднять редактор на передний план (или запустить, если не запущен).
    @discardableResult
    func focusEditor() -> Bool {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: EditorIPC.editorBundleID).first {
            running.activate(options: [.activateAllWindows])
            return true
        }
        return launch()
    }

    @discardableResult
    private func launch() -> Bool {
        guard let url = editorAppURL else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        return true
    }

    // MARK: Открытие файла

    /// Отправить файл в редактор (запустив его при необходимости).
    func open(remotePath: String, data: Data, sessionID: UUID, nodeName: String) throws {
        // Кодировку (UTF-8/1251/KOI8-R/UTF-16…) определяет редактор по байтам;
        // здесь отсекаем только бинарники: NUL в начале без UTF-16 BOM.
        // PDF — бинарник, но редактор открывает его своей вкладкой (PDFKit).
        let head = data.prefix(8192)
        let isPDF = data.prefix(1024).range(of: Data("%PDF".utf8)) != nil
        let utf16BOM = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        if !isPDF, !Self.isDocName(remotePath), !utf16BOM, head.contains(0) { throw OpenError.binary }
        guard editorAppURL != nil else { throw OpenError.editorMissing }

        // Один и тот же файл на той же ноде — тот же docID (редактор обновит).
        let docID = routes.first {
            $0.value.sessionID == sessionID && $0.value.path == remotePath
        }?.key ?? UUID().uuidString
        routes[docID] = (sessionID, remotePath, nodeName)

        if !isEditorRunning { launch() }
        EditorIPC.send(.init(
            kind: .open, docID: docID,
            sessionID: sessionID.uuidString, nodeName: nodeName,
            remotePath: remotePath, bytes: data.base64EncodedString()
        ), to: EditorIPC.toEditor)
        focusEditor()
    }

    // MARK: Приём от редактора

    private func handle(_ m: EditorIPC.Message) {
        switch m.kind {
        case .save:
            upload(m)
        case .reload:
            reload(m)
        case .closed:
            routes.removeValue(forKey: m.docID)
        case .ready:
            // Репо разные: несовпадение протокола — сказать один раз, а не молчать.
            if let v = m.proto, v != EditorIPC.protocolVersion, !protoWarned {
                protoWarned = true
                let a = NSAlert()
                a.messageText = "QEditor собран с другой версией протокола"
                a.informativeText = "QEditor: v\(v), QTerm: v\(EditorIPC.protocolVersion). Обнови тот, что старее, иначе часть команд редактора будет молча теряться."
                a.runModal()
            }
        default:
            break
        }
    }

    private var protoWarned = false

    private func upload(_ m: EditorIPC.Message) {
        guard let route = routes[m.docID] ?? routeFrom(m) else { return }
        // Байты в кодировке документа (редактор кодирует сам); старый
        // формат — текст, пишем UTF-8.
        let data = m.bytes.flatMap { Data(base64Encoded: $0) } ?? Data((m.text ?? "").utf8)
        guard let conn = app?.connections[route.sessionID], conn.status == .connected else {
            EditorIPC.send(.init(
                kind: .saved, docID: m.docID, ok: false,
                error: "Нода «\(route.node)» не подключена — открой её вкладку и сохрани ещё раз"
            ), to: EditorIPC.toEditor)
            return
        }
        Task {
            do {
                try await conn.writeFile(path: route.path, data: data)
                EditorIPC.send(.init(
                    kind: .saved, docID: m.docID, ok: true
                ), to: EditorIPC.toEditor)
            } catch {
                EditorIPC.send(.init(
                    kind: .saved, docID: m.docID, ok: false,
                    error: "Ошибка сохранения: \(error.localizedDescription)"
                ), to: EditorIPC.toEditor)
            }
        }
    }

    /// «Перечитать»: свежие байты с ноды → open с force.
    private func reload(_ m: EditorIPC.Message) {
        guard let route = routes[m.docID] ?? routeFrom(m) else { return }
        guard let conn = app?.connections[route.sessionID], conn.status == .connected else {
            EditorIPC.send(.init(
                kind: .saved, docID: m.docID, ok: false,
                error: "Нода «\(route.node)» не подключена — перечитать нельзя"
            ), to: EditorIPC.toEditor)
            return
        }
        Task {
            do {
                let data = try await conn.readFile(path: route.path)
                EditorIPC.send(.init(
                    kind: .open, docID: m.docID,
                    sessionID: route.sessionID.uuidString, nodeName: route.node,
                    remotePath: route.path, bytes: data.base64EncodedString(), force: true
                ), to: EditorIPC.toEditor)
            } catch {
                EditorIPC.send(.init(
                    kind: .saved, docID: m.docID, ok: false,
                    error: "Перечитать: \(error.localizedDescription)"
                ), to: EditorIPC.toEditor)
            }
        }
    }

    /// Редактор мог пережить перезапуск хоста — восстановим маршрут из сообщения.
    private func routeFrom(_ m: EditorIPC.Message) -> (sessionID: UUID, path: String, node: String)? {
        guard let sid = m.sessionID, let uuid = UUID(uuidString: sid),
              let path = m.remotePath else { return nil }
        let route = (sessionID: uuid, path: path, node: m.nodeName ?? "")
        routes[m.docID] = route
        return route
    }
}
