import SwiftUI
import AppKit

/// Мост к отдельному приложению QTermEditor.app.
///
/// Редактор — самостоятельное приложение (своя иконка в доке, ⌘Tab, окна),
/// но SSH оно не знает: файл читает и заливает QTerm, а редактор только
/// показывает текст и просит сохранить. Обмен — EditorIPC.
@MainActor
final class EditorBridge: ObservableObject {

    weak var app: AppState?
    /// Открытые в редакторе файлы: docID → (нода, путь).
    private var routes: [String: (sessionID: UUID, path: String, node: String)] = [:]
    private var token: NSObjectProtocol?

    /// Файлы больше лимита в редактор не открываем — только скачивание.
    static let maxEditableSize: UInt64 = 2 * 1024 * 1024

    enum OpenError: LocalizedError {
        case binary
        case editorMissing
        var errorDescription: String? {
            switch self {
            case .binary: return "Похоже на бинарный файл — открой через скачивание или внешний редактор"
            case .editorMissing: return "QTermEditor.app не найден внутри QTerm.app — пересобери приложение"
            }
        }
    }

    init() {
        EditorIPC.sweep()
        token = EditorIPC.listen(EditorIPC.toHost) { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
    }

    // MARK: Путь к приложению и запуск

    /// QTermEditor.app лежит внутри бандла хоста.
    private var editorAppURL: URL? {
        let embedded = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/QTermEditor.app")
        if FileManager.default.fileExists(atPath: embedded.path) { return embedded }
        // Запуск из .build (разработка): рядом с бинарём.
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("QTermEditor.app")
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
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
        let head = data.prefix(8192)
        let utf16BOM = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        if !utf16BOM, head.contains(0) { throw OpenError.binary }
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
            break
        default:
            break
        }
    }

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
