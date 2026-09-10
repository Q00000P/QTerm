import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages

// MARK: - Отдельное приложение-редактор QTermEditor
//
// Своя иконка в доке, свои окна, ⌘Tab — всё как у обычного приложения.
// SSH оно не знает: файлы приходят от QTerm.app и уходят обратно на заливку
// через EditorIPC (файловый обмен + distributed notifications).

// MARK: - Документ редактора (один удалённый файл)

/// Открытый в редакторе удалённый файл. Содержимое живёт в памяти,
/// ⌘S заливает обратно по SFTP той ноды, с которой файл скачан.
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    let id: UUID
    let sessionID: String
    let nodeName: String
    let remotePath: String
    let language: CodeLanguage
    /// Локальный документ (скрапбук): живёт на диске, а не на ноде.
    var localURL: URL?
    var isLocal: Bool { sessionID == "local" }

    var fileName: String { (remotePath as NSString).lastPathComponent }
    /// Строка местоположения для статус-бара.
    var locationText: String {
        if isLocal { return localURL?.path ?? "не сохранён — ⌘S запишет на диск" }
        return "\(nodeName):\(remotePath)"
    }

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

    init(id: UUID = UUID(), sessionID: String, nodeName: String, remotePath: String, content: String) {
        self.id = id
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

    /// Откатить несохранённые правки к последнему сохранённому состоянию.
    func revert() {
        guard isDirty else { return }
        text = savedText
        statusText = "Изменения отменены"
        statusIsError = false
    }

    /// Обновить содержимое с сервера (повторное открытие незагрязнённого файла).
    func replaceContent(_ fresh: String) {
        text = fresh
        savedText = fresh
        isDirty = false
    }
}


// MARK: - Состояние приложения-редактора

@MainActor
final class EditorAppState: ObservableObject {
    @Published var documents: [EditorDocument] = []
    @Published var activeDocumentID: UUID?
    /// Хост не отвечает — предупредим, что сохранять некуда.
    @Published var hostSeen = true

    private var token: NSObjectProtocol?

    init() {
        token = EditorIPC.listen(EditorIPC.toEditor) { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        EditorIPC.drainPending { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        EditorIPC.send(.init(kind: .ready), to: EditorIPC.toHost)
    }

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    // MARK: Приём от хоста

    private func handle(_ m: EditorIPC.Message) {
        switch m.kind {
        case .open:
            guard let path = m.remotePath, let text = m.text,
                  let session = m.sessionID, let node = m.nodeName else { return }
            if let existing = documents.first(where: {
                $0.sessionID == session && $0.remotePath == path
            }) {
                if !existing.isDirty { existing.replaceContent(text) }
                activeDocumentID = existing.id
            } else {
                let id = UUID(uuidString: m.docID) ?? UUID()
                let doc = EditorDocument(
                    id: id, sessionID: session, nodeName: node,
                    remotePath: path, content: text
                )
                documents.append(doc)
                activeDocumentID = doc.id
            }
            NSApp.activate(ignoringOtherApps: true)
        case .saved:
            guard let doc = documents.first(where: { $0.id.uuidString == m.docID }) else { return }
            if m.ok == true {
                doc.markSaved(m.text ?? doc.text)
                doc.statusText = "Сохранено \(Self.timeStamp()) → \(doc.nodeName)"
                doc.statusIsError = false
            } else {
                doc.statusText = m.error ?? "Ошибка сохранения"
                doc.statusIsError = true
            }
        case .ping:
            hostSeen = true
        default:
            break
        }
    }

    // MARK: Действия

    private var untitledCounter = 0

    /// Пустая вкладка-скрапбук (кусок текста/кода, потом ⌘S на диск).
    func newDocument() {
        untitledCounter += 1
        let doc = EditorDocument(
            sessionID: "local", nodeName: "",
            remotePath: untitledCounter == 1 ? "Без имени" : "Без имени \(untitledCounter)",
            content: ""
        )
        documents.append(doc)
        activeDocumentID = doc.id
    }

    /// Открыть файл с диска.
    func openFromDisk() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            if let existing = documents.first(where: { $0.localURL == url }) {
                if !existing.isDirty { existing.replaceContent(text) }
                activeDocumentID = existing.id
                continue
            }
            let doc = EditorDocument(
                sessionID: "local", nodeName: "",
                remotePath: url.lastPathComponent, content: text
            )
            doc.localURL = url
            documents.append(doc)
            activeDocumentID = doc.id
        }
    }

    func save(_ doc: EditorDocument) {
        if doc.isLocal {
            guard let url = doc.localURL else { saveAs(doc); return }
            writeToDisk(doc, url: url)
            return
        }
        doc.statusText = "Сохранение…"
        doc.statusIsError = false
        EditorIPC.send(.init(
            kind: .save, docID: doc.id.uuidString,
            sessionID: doc.sessionID, nodeName: doc.nodeName,
            remotePath: doc.remotePath, text: doc.text
        ), to: EditorIPC.toHost)
    }

    /// «Сохранить как…»: копия на диск. Работает и для файлов с ноды —
    /// быстрый способ утащить кусок конфига в txt.
    func saveAs(_ doc: EditorDocument) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.isLocal && doc.localURL == nil
            ? "\(doc.fileName).txt"
            : doc.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if doc.isLocal {
            writeToDisk(doc, url: url)
        } else {
            // Удалённый док: пишем копию, вкладка остаётся привязанной к ноде.
            do {
                try Data(doc.text.utf8).write(to: url, options: .atomic)
                doc.statusText = "Копия сохранена: \(url.lastPathComponent)"
                doc.statusIsError = false
            } catch {
                doc.statusText = "Не записалось: \(error.localizedDescription)"
                doc.statusIsError = true
            }
        }
    }

    func saveAsActive() { if let doc = activeDocument { saveAs(doc) } }

    private func writeToDisk(_ doc: EditorDocument, url: URL) {
        do {
            try Data(doc.text.utf8).write(to: url, options: .atomic)
            doc.localURL = url
            doc.markSaved(doc.text)
            doc.statusText = "Сохранено \(Self.timeStamp()) → \(url.lastPathComponent)"
            doc.statusIsError = false
        } catch {
            doc.statusText = "Не записалось: \(error.localizedDescription)"
            doc.statusIsError = true
        }
    }

    func saveActive() { if let doc = activeDocument { save(doc) } }
    func revertActive() { activeDocument?.revert() }

    func requestClose(_ doc: EditorDocument) {
        if doc.isDirty {
            let alert = NSAlert()
            alert.messageText = "«\(doc.fileName)» не сохранён"
            alert.informativeText = doc.isLocal
                ? "Сохранить на диск перед закрытием?"
                : "Сохранить изменения на «\(doc.nodeName)» перед закрытием?"
            alert.addButton(withTitle: "Сохранить")
            alert.addButton(withTitle: "Не сохранять")
            alert.addButton(withTitle: "Отмена")
            switch alert.runModal() {
            case .alertFirstButtonReturn: save(doc); return
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        close(doc)
    }

    func close(_ doc: EditorDocument) {
        EditorIPC.send(.init(kind: .closed, docID: doc.id.uuidString), to: EditorIPC.toHost)
        documents.removeAll { $0.id == doc.id }
        if activeDocumentID == doc.id { activeDocumentID = documents.last?.id }
    }

    func closeActive() { if let doc = activeDocument { requestClose(doc) } }

    /// Копия вкладки того же файла (смотреть два места файла одновременно).
    /// Сохранение любой копии льёт в тот же путь на ноде.
    func duplicate(_ doc: EditorDocument) {
        let copy = EditorDocument(
            id: UUID(), sessionID: doc.sessionID, nodeName: doc.nodeName,
            remotePath: doc.remotePath, content: doc.text
        )
        documents.append(copy)
        activeDocumentID = copy.id
    }

    static func timeStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - Приложение

@main
struct QTermEditorApp: App {
    @StateObject private var editor = EditorAppState()

    var body: some Scene {
        WindowGroup("Редактор — QTerm") {
            EditorRootView(editor: editor)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая вкладка") { editor.newDocument() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Открыть с диска…") { editor.openFromDisk() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Закрыть вкладку") { editor.closeActive() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Сохранить") { editor.saveActive() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Сохранить как…") { editor.saveAsActive() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Отменить правки файла") { editor.revertActive() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
            }
        }
    }
}

// MARK: - Окно редактора

struct EditorRootView: View {
    @ObservedObject var editor: EditorAppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if editor.documents.isEmpty {
                emptyState
            } else {
                tabBar
                Divider()
                // Все панели живут одновременно: переключение вкладки не
                // пересоздаёт редактор, поэтому скролл, выделение и undo-стек
                // каждого файла остаются на месте.
                //
                // GeometryReader ОБЯЗАТЕЛЕН: intrinsic-ширина CodeEdit равна
                // самой длинной строке файла и распирает VStack шире окна —
                // контент (включая ленту вкладок) вылезал за левый край.
                // GeometryReader всегда равен предложенному размеру и гасит
                // это распирание.
                GeometryReader { geo in
                    ZStack {
                        ForEach(editor.documents) { doc in
                            EditorPane(doc: doc, theme: colorScheme == .dark ? .qtermDark : .qtermLight)
                                .id(doc.id)
                                .opacity(doc.id == editor.activeDocumentID ? 1 : 0)
                                .allowsHitTesting(doc.id == editor.activeDocumentID)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
                if let doc = editor.activeDocument {
                    Divider()
                    EditorStatusBar(
                        doc: doc,
                        save: { editor.save(doc) },
                        revert: { doc.revert() }
                    )
                }
            }
        }
        // Кнопки-невидимки для шорткатов окна (меню их не перехватывает).
        .background {
            Group {
                Button("") { editor.saveActive() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("") { editor.revertActive() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
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
            Text("Открой файл двойным кликом в проводнике ноды,\nили ⌘T — пустая вкладка для куска текста (⌘S сохранит на диск)")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabBar: some View {
        // Без горизонтальной прокрутки: вкладки переносятся по рядам, поэтому
        // плашку физически нечем срезать краем окна.
        TabFlowLayout(spacing: 3, lineSpacing: 3) {
            ForEach(editor.documents) { doc in
                EditorTabButton(
                    doc: doc,
                    isActive: doc.id == editor.activeDocumentID,
                    activate: { editor.activeDocumentID = doc.id },
                    close: { editor.requestClose(doc) },
                    duplicate: { editor.duplicate(doc) }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Статус-бар редактора. Отдельная вьюха с @ObservedObject на документ:
/// isDirty/statusText меняются в документе, и кнопка «Сохранить» должна
/// перерисовываться сразу, а не по внешнему пинку окна.
private struct EditorStatusBar: View {
    @ObservedObject var doc: EditorDocument
    let save: () -> Void
    let revert: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(doc.locationText)
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
            if doc.isDirty {
                Button(action: revert) {
                    Label("Отменить правки", systemImage: "arrow.uturn.backward")
                }
                .help("Вернуть файл к сохранённому состоянию (⌘⌥Z)")
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
    var duplicate: () -> Void = {}

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
        .contextMenu {
            Button("Дублировать вкладку") { duplicate() }
            Button("Закрыть", role: .destructive, action: close)
        }
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


// MARK: - Раскладка вкладок с переносом по рядам

/// Простой flow-layout: элементы идут слева направо, не влезающие
/// переносятся на новый ряд. Никакой прокрутки — ничего не обрезается.
struct TabFlowLayout: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
