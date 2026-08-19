import SwiftUI
import AppKit
import NIOCore
import Citadel
import CodeEditSourceEditor
import CodeEditLanguages

// MARK: - Документ редактора (один удалённый файл)

/// Открытый в редакторе удалённый файл. Содержимое живёт в памяти,
/// ⌘S заливает обратно по SFTP той ноды, с которой файл скачан.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    let id = UUID()
    let sessionID: UUID
    let nodeName: String
    let remotePath: String
    let language: CodeLanguage

    var fileName: String { (remotePath as NSString).lastPathComponent }

    @Published var text: String {
        didSet { isDirty = text != savedText }
    }
    @Published private(set) var isDirty = false
    /// Строка статуса под редактором («Сохранено 12:41» / ошибка).
    @Published var statusText: String?
    @Published var statusIsError = false
    @Published var cursorPositions: [CursorPosition] = []

    /// Последнее содержимое, совпадающее с сервером.
    private(set) var savedText: String

    init(sessionID: UUID, nodeName: String, remotePath: String, content: String) {
        self.sessionID = sessionID
        self.nodeName = nodeName
        self.remotePath = remotePath
        self.text = content
        self.savedText = content
        self.language = CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: remotePath))
    }

    /// Успешная заливка: текущий текст стал эталоном.
    func markSaved(_ uploaded: String) {
        savedText = uploaded
        isDirty = text != uploaded
    }

    /// Обновить содержимое с сервера (повторное открытие незагрязнённого файла).
    func replaceContent(_ fresh: String) {
        text = fresh
        savedText = fresh
        isDirty = false
    }
}

// MARK: - Состояние окна редактора

@MainActor
final class EditorState: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var activeDocumentID: UUID?
    /// Окно редактора сейчас ключевое (для маршрутизации ⌘W из меню).
    @Published var isKeyWindow = false

    weak var app: AppState?

    /// Файлы больше лимита в редактор не открываем — только скачивание.
    static let maxEditableSize: UInt64 = 2 * 1024 * 1024

    enum OpenError: LocalizedError {
        case notUTF8
        var errorDescription: String? {
            "Файл не в UTF-8 (или бинарный) — открой через скачивание"
        }
    }

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    /// Открыть файл (или активировать уже открытый). Кидает OpenError.notUTF8.
    func open(remotePath: String, data: Data, sessionID: UUID, nodeName: String) throws {
        if let existing = documents.first(where: {
            $0.sessionID == sessionID && $0.remotePath == remotePath
        }) {
            // Уже открыт: если правок нет — обновим содержимое с сервера.
            if !existing.isDirty, let fresh = String(data: data, encoding: .utf8) {
                existing.replaceContent(fresh)
            }
            activeDocumentID = existing.id
            return
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw OpenError.notUTF8
        }
        let doc = EditorDocument(
            sessionID: sessionID, nodeName: nodeName,
            remotePath: remotePath, content: content
        )
        documents.append(doc)
        activeDocumentID = doc.id
    }

    // MARK: Сохранение

    func save(_ doc: EditorDocument, thenClose: Bool = false) {
        guard let conn = app?.connections[doc.sessionID], conn.status == .connected else {
            doc.statusText = "Нода «\(doc.nodeName)» не подключена — открой её вкладку и сохрани ещё раз"
            doc.statusIsError = true
            return
        }
        let uploading = doc.text
        doc.statusText = "Сохранение…"
        doc.statusIsError = false
        Task {
            do {
                try await conn.writeFile(path: doc.remotePath, data: Data(uploading.utf8))
                doc.markSaved(uploading)
                doc.statusText = "Сохранено \(Self.timeStamp()) → \(doc.nodeName)"
                doc.statusIsError = false
                if thenClose { self.close(doc) }
            } catch {
                doc.statusText = "Ошибка сохранения: \(error)"
                doc.statusIsError = true
            }
        }
    }

    func saveActive() {
        if let doc = activeDocument { save(doc) }
    }

    // MARK: Закрытие

    /// Закрыть вкладку с проверкой несохранённого (модальный вопрос).
    func requestClose(_ doc: EditorDocument) {
        guard doc.isDirty else { close(doc); return }
        let alert = NSAlert()
        alert.messageText = "«\(doc.fileName)» не сохранён"
        alert.informativeText = "Сохранить изменения на «\(doc.nodeName)» перед закрытием?"
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(doc, thenClose: true)
        case .alertSecondButtonReturn: close(doc)
        default: break
        }
    }

    func closeActiveDocument() {
        if let doc = activeDocument { requestClose(doc) }
    }

    private func close(_ doc: EditorDocument) {
        let idx = documents.firstIndex { $0.id == doc.id }
        documents.removeAll { $0.id == doc.id }
        if activeDocumentID == doc.id {
            let next = min(idx ?? 0, max(documents.count - 1, 0))
            activeDocumentID = documents.indices.contains(next) ? documents[next].id : nil
        }
    }

    private static func timeStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - Окно редактора

struct EditorWindowView: View {
    @ObservedObject var editor: EditorState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if editor.documents.isEmpty {
                emptyState
            } else {
                tabBar
                Divider()
                if let doc = editor.activeDocument {
                    EditorPane(doc: doc, theme: colorScheme == .dark ? .qtermDark : .qtermLight)
                        .id(doc.id) // свой undo-стек и скролл на документ
                    Divider()
                    EditorStatusBar(doc: doc) { editor.save(doc) }
                }
            }
        }
        .background(WindowKeyObserver { editor.isKeyWindow = $0 })
        // Кнопки-невидимки для шорткатов окна (меню их не перехватывает).
        .background {
            Group {
                Button("") { editor.saveActive() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Открой файл двойным кликом в проводнике ноды")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(editor.documents) { doc in
                    EditorTabButton(
                        doc: doc,
                        isActive: doc.id == editor.activeDocumentID,
                        activate: { editor.activeDocumentID = doc.id },
                        close: { editor.requestClose(doc) }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }
}

/// Статус-бар редактора. Отдельная вьюха с @ObservedObject на документ:
/// isDirty/statusText меняются в документе, и кнопка «Сохранить» должна
/// перерисовываться сразу, а не по внешнему пинку окна.
private struct EditorStatusBar: View {
    @ObservedObject var doc: EditorDocument
    let save: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(doc.nodeName):\(doc.remotePath)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let status = doc.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(doc.statusIsError ? .red : .secondary)
                    .lineLimit(1)
            }
            Button(action: save) {
                Label("Сохранить", systemImage: "arrow.up.doc")
            }
            .disabled(!doc.isDirty)
            .help("⌘S — залить на \(doc.nodeName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// Вкладка файла в ленте редактора.
private struct EditorTabButton: View {
    @ObservedObject var doc: EditorDocument
    let isActive: Bool
    let activate: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(doc.fileName)
                .lineLimit(1)
            if doc.isDirty {
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.12))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .help("\(doc.nodeName):\(doc.remotePath)")
    }
}

/// Сам редактор (CodeEditSourceEditor поверх tree-sitter).
private struct EditorPane: View {
    @ObservedObject var doc: EditorDocument
    let theme: EditorTheme

    var body: some View {
        CodeEditSourceEditor(
            $doc.text,
            language: doc.language,
            theme: theme,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            tabWidth: 4,
            indentOption: .spaces(count: 4),
            lineHeight: 1.2,
            wrapLines: false,
            cursorPositions: $doc.cursorPositions,
            showMinimap: false,
            reformatAtColumn: 80,
            showReformattingGuide: false
        )
    }
}

// MARK: - Наблюдение «окно стало/перестало быть ключевым»

/// Роутинг ⌘W из главного меню: когда ключевое окно — редактор,
/// закрывается вкладка редактора, а не терминала.
private struct WindowKeyObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens.removeAll()
            guard let window else {
                onChange?(false)
                return
            }
            onChange?(window.isKeyWindow)
            let center = NotificationCenter.default
            tokens.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onChange?(true) })
            tokens.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onChange?(false) })
            tokens.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onChange?(false) })
        }

        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

// MARK: - Темы (палитры Xcode Default / Xcode Dark)

extension EditorTheme {

    static let qtermLight = EditorTheme(
        text: .init(color: NSColor(hex: 0x000000)),
        insertionPoint: NSColor(hex: 0x000000),
        invisibles: .init(color: NSColor(hex: 0xD6D6D6)),
        background: NSColor(hex: 0xFFFFFF),
        lineHighlight: NSColor(hex: 0xECF5FF),
        selection: NSColor(hex: 0xB2D7FF),
        keywords: .init(color: NSColor(hex: 0x9B2393), bold: true),
        commands: .init(color: NSColor(hex: 0x326D74)),
        types: .init(color: NSColor(hex: 0x3900A0)),
        attributes: .init(color: NSColor(hex: 0x815F03)),
        variables: .init(color: NSColor(hex: 0x0F68A0)),
        values: .init(color: NSColor(hex: 0x6C36A9)),
        numbers: .init(color: NSColor(hex: 0x1C00CF)),
        strings: .init(color: NSColor(hex: 0xC41A16)),
        characters: .init(color: NSColor(hex: 0x1C00CF)),
        comments: .init(color: NSColor(hex: 0x5D6C79))
    )

    static let qtermDark = EditorTheme(
        text: .init(color: NSColor(hex: 0xFFFFFF)),
        insertionPoint: NSColor(hex: 0xFFFFFF),
        invisibles: .init(color: NSColor(hex: 0x424D5B)),
        background: NSColor(hex: 0x1F1F24),
        lineHighlight: NSColor(hex: 0x23252B),
        selection: NSColor(hex: 0x515B70),
        keywords: .init(color: NSColor(hex: 0xFC5FA3), bold: true),
        commands: .init(color: NSColor(hex: 0x67B7A4)),
        types: .init(color: NSColor(hex: 0x5DD8FF)),
        attributes: .init(color: NSColor(hex: 0xBF8555)),
        variables: .init(color: NSColor(hex: 0x41A1C0)),
        values: .init(color: NSColor(hex: 0xA167E6)),
        numbers: .init(color: NSColor(hex: 0xD0BF69)),
        strings: .init(color: NSColor(hex: 0xFC6A5D)),
        characters: .init(color: NSColor(hex: 0xD0BF69)),
        comments: .init(color: NSColor(hex: 0x6C7986))
    )
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
