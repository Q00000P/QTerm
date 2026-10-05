import SwiftUI
import Combine
import AppKit
import CoreServices
import CodeEditSourceEditor
import CodeEditLanguages

// MARK: - Отдельное приложение-редактор QTermEditor
//
// Своя иконка в доке, свои окна, ⌘Tab — всё как у обычного приложения.
// SSH оно не знает: файлы приходят от QTerm.app и уходят обратно на заливку
// через EditorIPC (файловый обмен + distributed notifications).
// Уровень — MobaTextEditor (канон Windows QEditor): меню Файл/Правка/Поиск/
// Вид/Формат/Кодировка/Синтаксис/Инструменты, regex-поиск, закладки,
// кодировки и концы строк, сравнение вкладок.

// MARK: - Связь с TextViewController (CodeEditSourceEditor держит координаторы слабо)

final class DocCoordinator: TextViewCoordinator {
    weak var controller: TextViewController?

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
    }

    func destroy() {
        controller = nil
    }
}

// MARK: - Документ редактора

/// Открытый файл: с ноды (⌘S заливает по SSH той ноды) или локальный (скрапбук).
@MainActor
final class EditorDocument: ObservableObject, Identifiable {
    let id: UUID
    let sessionID: String
    let nodeName: String
    let remotePath: String
    /// Локальный документ (скрапбук): живёт на диске, а не на ноде.
    var localURL: URL?
    var isLocal: Bool { sessionID == "local" }

    var fileName: String {
        if let localURL { return localURL.lastPathComponent }
        return (remotePath as NSString).lastPathComponent
    }
    /// Строка местоположения для статус-бара.
    var locationText: String {
        if isLocal { return localURL?.path ?? "не сохранён — ⌘S запишет на диск" }
        return "\(nodeName):\(remotePath)"
    }

    @Published var text: String {
        didSet { updateDirty() }
    }
    @Published private(set) var isDirty = false
    @Published var language: CodeLanguage
    /// Кодировка, в которой файл будет записан.
    @Published var encoding: TextEncodingChoice
    /// Концы строк (определены при открытии, меняются «Формат → Концы строк»).
    @Published var eol: TextCodec.EOL
    /// Закладки — номера строк (с 1).
    @Published var bookmarks: [Int] = []
    /// Строка статуса под редактором («Сохранено 12:41» / ошибка).
    @Published var statusText: String?
    @Published var statusIsError = false
    @Published var cursorPositions: [CursorPosition] = []

    /// Последнее содержимое, совпадающее с сервером/диском.
    private(set) var savedText: String
    /// Кодировка сохранённого состояния (смена кодировки = есть что сохранять).
    private var savedEncoding: TextEncodingChoice
    /// Сырые байты последней загрузки/записи — для «Открыть заново в кодировке».
    var rawData: Data
    /// Текст, отправленный на заливку (станет эталоном при ответе ok).
    var pendingSave: (text: String, data: Data)?
    /// Ждём свежие байты после «Перечитать».
    var awaitingReload = false

    let coordinator = DocCoordinator()
    var controller: TextViewController? { coordinator.controller }

    init(id: UUID = UUID(), sessionID: String, nodeName: String, remotePath: String, data: Data) {
        self.id = id
        self.sessionID = sessionID
        self.nodeName = nodeName
        self.remotePath = remotePath
        let decoded = TextCodec.decode(data)
        self.text = decoded.text
        self.savedText = decoded.text
        self.encoding = decoded.encoding
        self.savedEncoding = decoded.encoding
        self.eol = TextCodec.detectEOL(decoded.text)
        self.rawData = data
        self.language = CodeLanguage.detectLanguageFrom(
            url: URL(fileURLWithPath: remotePath),
            prefixBuffer: String(decoded.text.prefix(300))
        )
    }

    private func updateDirty() {
        isDirty = text != savedText || encoding != savedEncoding
    }

    /// Успешная запись: текущее стало эталоном.
    func markSaved(text uploaded: String, data: Data) {
        savedText = uploaded
        savedEncoding = encoding
        rawData = data
        updateDirty()
    }

    /// Откатить несохранённые правки к последнему сохранённому состоянию.
    func revert() {
        guard isDirty else { return }
        encoding = savedEncoding
        replaceInEditor(savedText, status: "Изменения отменены")
    }

    /// Свежие байты с сервера / диска.
    func replaceContent(data: Data) {
        let decoded = TextCodec.decode(data)
        rawData = data
        encoding = decoded.encoding
        savedEncoding = decoded.encoding
        eol = TextCodec.detectEOL(decoded.text)
        savedText = decoded.text
        text = decoded.text
        updateDirty()
    }

    func setSaveEncoding(_ e: TextEncodingChoice) {
        encoding = e
        updateDirty()
        setStatus("Будет сохранено в \(e.name)")
    }

    func reopen(as e: TextEncodingChoice) {
        guard let t = TextCodec.decode(rawData, as: e) else {
            setStatus("Байты файла не читаются как \(e.name)", error: true)
            return
        }
        encoding = e
        savedEncoding = e
        savedText = t
        text = t
        eol = TextCodec.detectEOL(t)
        updateDirty()
        setStatus("Открыто как \(e.name)")
    }

    func setStatus(_ s: String, error: Bool = false) {
        statusText = s
        statusIsError = error
    }

    // MARK: Правки через TextView (с undo)

    /// Поле ввода CodeEditTextView (NSTextInputClient): вставка через него
    /// идёт в undo-стек редактора, в отличие от подмены текста биндингом.
    var textInput: (NSView & NSTextInputClient)? {
        guard let root = controller?.view else { return nil }
        return Self.findInput(root)
    }

    private static func findInput(_ v: NSView) -> (NSView & NSTextInputClient)? {
        if String(describing: type(of: v)) == "TextView", let t = v as? (NSView & NSTextInputClient) { return t }
        for s in v.subviews {
            if let t = findInput(s) { return t }
        }
        return nil
    }

    /// Текущий текст редактора (истина — сам TextView).
    var liveText: String { controller?.string ?? text }

    var selection: NSRange {
        textInput?.selectedRange() ?? cursorPositions.first?.range ?? NSRange(location: 0, length: 0)
    }

    func select(_ range: NSRange) {
        controller?.setCursorPositions([CursorPosition(range: range)], scrollToVisible: true)
        if let tv = textInput { tv.window?.makeFirstResponder(tv) }
    }

    /// Заменить диапазон; выделить вставленное (select) или поставить курсор после.
    func replace(_ range: NSRange, with s: String, select selectInserted: Bool = true) {
        guard let input = textInput else {
            // Редактор ещё не поднят — правим модель напрямую.
            let ns = text as NSString
            text = ns.replacingCharacters(in: range, with: s)
            return
        }
        input.insertText(s, replacementRange: range)
        let len = (s as NSString).length
        select(selectInserted ? NSRange(location: range.location, length: len)
                              : NSRange(location: range.location + len, length: 0))
    }

    /// Весь текст одной правкой (один шаг отмены).
    func replaceInEditor(_ newText: String, status: String) {
        let old = liveText as NSString
        if textInput != nil {
            replace(NSRange(location: 0, length: old.length), with: newText, select: false)
            select(NSRange(location: 0, length: 0))
        } else {
            text = newText
        }
        setStatus(status)
    }

    /// Номер строки (с 1) позиции.
    func lineNumber(at location: Int) -> Int {
        let ns = liveText as NSString
        let loc = min(max(location, 0), ns.length)
        var line = 1
        var i = 0
        while i < ns.length {
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: i, length: 0)))
            if end > loc { return line }
            if end >= ns.length {
                // Курсор после завершающего перевода строки — на пустой последней строке.
                return loc == ns.length ? line + 1 : line
            }
            line += 1
            i = end
        }
        return line
    }

    /// Текущая строка курсора (CodeEdit считает её сам; фолбэк — по тексту).
    var currentLine: Int {
        cursorPositions.first.map(\.line).flatMap { $0 > 0 ? $0 : nil } ?? lineNumber(at: selection.location)
    }

    /// Диапазон строки n (с 1), без перевода строки.
    func rangeOfLine(_ n: Int) -> NSRange? {
        let ns = liveText as NSString
        guard n >= 1 else { return nil }
        var start = 0
        var line = 1
        while line < n {
            guard start < ns.length else { return nil }
            start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
            line += 1
        }
        if start == ns.length, ns.length > 0 {
            // Строка после последнего перевода существует, только если он есть.
            let last = ns.character(at: ns.length - 1)
            if last != 10 && last != 13 { return nil }
        }
        let r = ns.lineRange(for: NSRange(location: start, length: 0))
        var len = r.length
        while len > 0, [10, 13].contains(ns.character(at: r.location + len - 1)) { len -= 1 }
        return NSRange(location: r.location, length: len)
    }

    var lineCount: Int {
        let ns = liveText as NSString
        guard ns.length > 0 else { return 1 }
        var count = 0
        var i = 0
        while i < ns.length {
            i = NSMaxRange(ns.lineRange(for: NSRange(location: i, length: 0)))
            count += 1
        }
        if let last = liveText.unicodeScalars.last, last == "\n" || last == "\r" { count += 1 }
        return count
    }

    func linePreview(_ n: Int) -> String {
        guard let r = rangeOfLine(n) else { return "" }
        let s = (liveText as NSString).substring(with: r).trimmingCharacters(in: .whitespaces)
        return s.count > 60 ? String(s.prefix(60)) + "…" : s
    }
}

// MARK: - Настройки редактора (общие для вкладок, переживают перезапуск)

final class EditorSettings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var wrapLines: Bool { didSet { d.set(wrapLines, forKey: "ed.wrap") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "ed.font") } }
    @Published var showMinimap: Bool { didSet { d.set(showMinimap, forKey: "ed.minimap") } }
    @Published var showGuide: Bool { didSet { d.set(showGuide, forKey: "ed.guide") } }
    @Published var useSpaces: Bool { didSet { d.set(useSpaces, forKey: "ed.spaces") } }
    @Published var tabWidth: Int { didSet { d.set(tabWidth, forKey: "ed.tab") } }

    static let defaultFont = 13.0

    init() {
        let d = UserDefaults.standard
        wrapLines = d.object(forKey: "ed.wrap") as? Bool ?? false
        let f = d.double(forKey: "ed.font")
        fontSize = f > 0 ? f : Self.defaultFont
        showMinimap = d.object(forKey: "ed.minimap") as? Bool ?? false
        showGuide = d.object(forKey: "ed.guide") as? Bool ?? false
        useSpaces = d.object(forKey: "ed.spaces") as? Bool ?? true
        let t = d.integer(forKey: "ed.tab")
        tabWidth = t > 0 ? t : 4
    }

    var indentUnit: String { useSpaces ? String(repeating: " ", count: tabWidth) : "\t" }
}

// MARK: - Состояние приложения-редактора

@MainActor
final class EditorAppState: ObservableObject {
    @Published var documents: [EditorDocument] = [] { didSet { watchDirty() } }

    /// Тулбар смотрит на EditorAppState, а «грязность» живёт в документе — без пересылки
    /// кнопки «Сохранить» оставались серыми, пока не дёрнется что-то ещё (меню видело верно).
    private var dirtySubs: [ObjectIdentifier: AnyCancellable] = [:]
    private func watchDirty() {
        let ids = Set(documents.map { ObjectIdentifier($0) })
        dirtySubs = dirtySubs.filter { ids.contains($0.key) }
        for d in documents where dirtySubs[ObjectIdentifier(d)] == nil {
            dirtySubs[ObjectIdentifier(d)] = d.$isDirty.removeDuplicates().dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.objectWillChange.send() }
            }
        }
    }
    @Published var activeDocumentID: UUID?
    /// Хост не отвечает — предупредим, что сохранять некуда.
    @Published var hostSeen = true

    // Поиск и замена (regex, регистр, слово целиком)
    @Published var showFind = false
    @Published var findText = ""
    @Published var replaceText = ""
    @Published var useRegex = false
    @Published var matchCase = false
    @Published var wholeWord = false
    @Published var findStatus = ""
    /// Запрос фокуса в поле поиска (меняется — поле забирает фокус).
    @Published var findFocusToken = 0

    /// Сравнение: (заголовок, строки diff).
    @Published var diffResult: DiffResult?
    @Published var recentFiles: [String] = UserDefaults.standard.stringArray(forKey: "ed.recent") ?? []

    let settings = EditorSettings()

    private var token: NSObjectProtocol?

    init() {
        token = EditorIPC.listen(EditorIPC.toEditor) { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        EditorIPC.drainPending { [weak self] message in
            Task { @MainActor in self?.handle(message) }
        }
        EditorIPC.send(.init(kind: .ready), to: EditorIPC.toHost)
        // файлы из Finder («Открыть в программе», перетаскивание на иконку), пришедшие до появления состояния
        EditorAppDelegate.attach(self)
    }

    var activeDocument: EditorDocument? {
        documents.first { $0.id == activeDocumentID }
    }

    /// Меню читают свойства документа — после правок кодировки/EOL/синтаксиса
    /// пересобрать их отметки.
    func touch() { objectWillChange.send() }

    // MARK: Приём от хоста

    private func handle(_ m: EditorIPC.Message) {
        switch m.kind {
        case .open:
            guard let path = m.remotePath, let session = m.sessionID, let node = m.nodeName else { return }
            let data = m.bytes.flatMap { Data(base64Encoded: $0) } ?? Data((m.text ?? "").utf8)
            if let existing = documents.first(where: {
                $0.id.uuidString == m.docID || ($0.sessionID == session && $0.remotePath == path)
            }) {
                if m.force == true || existing.awaitingReload || !existing.isDirty {
                    existing.replaceContent(data: data)
                    if existing.awaitingReload {
                        existing.awaitingReload = false
                        existing.setStatus("Перечитано с \(existing.nodeName) \(Self.timeStamp())")
                    }
                }
                activeDocumentID = existing.id
            } else {
                let id = UUID(uuidString: m.docID) ?? UUID()
                let doc = EditorDocument(id: id, sessionID: session, nodeName: node,
                                         remotePath: path, data: data)
                if doc.encoding != .utf8 { doc.setStatus("Кодировка: \(doc.encoding.name)") }
                documents.append(doc)
                activeDocumentID = doc.id
            }
            NSApp.activate(ignoringOtherApps: true)
        case .saved:
            guard let doc = documents.first(where: { $0.id.uuidString == m.docID }) else { return }
            if m.ok == true {
                if let p = doc.pendingSave { doc.markSaved(text: p.text, data: p.data) }
                doc.pendingSave = nil
                doc.setStatus("Сохранено \(Self.timeStamp()) → \(doc.nodeName)")
            } else {
                doc.pendingSave = nil
                doc.awaitingReload = false
                doc.setStatus(m.error ?? "Ошибка сохранения", error: true)
            }
        case .ping:
            hostSeen = true
        default:
            break
        }
    }

    // MARK: Файл

    private var untitledCounter = 0

    /// Пустая вкладка-скрапбук (кусок текста/кода, потом ⌘S на диск).
    func newDocument() {
        untitledCounter += 1
        let doc = EditorDocument(
            sessionID: "local", nodeName: "",
            remotePath: untitledCounter == 1 ? "Без имени" : "Без имени \(untitledCounter)",
            data: Data()
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
        for url in panel.urls { openLocal(url) }
    }

    func openLocal(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            activeDocument?.setStatus("Не читается: \(url.path)", error: true)
            return
        }
        rememberRecent(url.path)
        if let existing = documents.first(where: { $0.localURL == url }) {
            if !existing.isDirty { existing.replaceContent(data: data) }
            activeDocumentID = existing.id
            return
        }
        let doc = EditorDocument(sessionID: "local", nodeName: "", remotePath: url.path, data: data)
        doc.localURL = url
        documents.append(doc)
        activeDocumentID = doc.id
    }

    private func rememberRecent(_ path: String) {
        var r = recentFiles.filter { $0 != path }
        r.insert(path, at: 0)
        recentFiles = Array(r.prefix(12))
        UserDefaults.standard.set(recentFiles, forKey: "ed.recent")
    }

    func clearRecent() {
        recentFiles = []
        UserDefaults.standard.removeObject(forKey: "ed.recent")
    }

    /// Перечитать: с ноды — через хост, локальный — с диска.
    func reload(_ doc: EditorDocument) {
        if doc.isDirty && !confirm("«\(doc.fileName)»: несохранённые правки пропадут. Перечитать?") { return }
        if doc.isLocal {
            guard let url = doc.localURL, let data = try? Data(contentsOf: url) else {
                doc.setStatus("Нечего перечитывать — файл не сохранён на диск", error: true)
                return
            }
            doc.replaceContent(data: data)
            doc.setStatus("Перечитано \(Self.timeStamp())")
            return
        }
        doc.awaitingReload = true
        doc.setStatus("Перечитываю с \(doc.nodeName)…")
        EditorIPC.send(.init(kind: .reload, docID: doc.id.uuidString, sessionID: doc.sessionID,
                             nodeName: doc.nodeName, remotePath: doc.remotePath), to: EditorIPC.toHost)
    }

    func save(_ doc: EditorDocument) {
        let text = doc.liveText
        let data: Data
        do { data = try TextCodec.encode(text, as: doc.encoding) }
        catch { doc.setStatus(error.localizedDescription, error: true); return }
        if doc.isLocal {
            guard let url = doc.localURL else { saveAs(doc); return }
            writeToDisk(doc, url: url, text: text, data: data)
            return
        }
        doc.pendingSave = (text, data)
        doc.setStatus("Сохранение…")
        EditorIPC.send(.init(
            kind: .save, docID: doc.id.uuidString,
            sessionID: doc.sessionID, nodeName: doc.nodeName,
            remotePath: doc.remotePath, bytes: data.base64EncodedString()
        ), to: EditorIPC.toHost)
    }

    /// «Сохранить как…»: копия на диск. Для файла с ноды — копия, вкладка
    /// остаётся привязанной к ноде (быстро утащить кусок конфига в txt).
    func saveAs(_ doc: EditorDocument) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.isLocal && doc.localURL == nil ? "\(doc.fileName).txt" : doc.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = doc.liveText
        let data: Data
        do { data = try TextCodec.encode(text, as: doc.encoding) }
        catch { doc.setStatus(error.localizedDescription, error: true); return }
        if doc.isLocal {
            writeToDisk(doc, url: url, text: text, data: data)
        } else {
            do {
                try data.write(to: url, options: .atomic)
                rememberRecent(url.path)
                doc.setStatus("Копия сохранена: \(url.lastPathComponent)")
            } catch {
                doc.setStatus("Не записалось: \(error.localizedDescription)", error: true)
            }
        }
    }

    private func writeToDisk(_ doc: EditorDocument, url: URL, text: String, data: Data) {
        do {
            try data.write(to: url, options: .atomic)
            doc.localURL = url
            doc.markSaved(text: text, data: data)
            rememberRecent(url.path)
            doc.setStatus("Сохранено \(Self.timeStamp()) → \(url.lastPathComponent)")
            touch()
        } catch {
            doc.setStatus("Не записалось: \(error.localizedDescription)", error: true)
        }
    }

    func saveAll() {
        for doc in documents where doc.isDirty { save(doc) }
    }

    func requestClose(_ doc: EditorDocument) -> Bool {
        if doc.isDirty {
            activeDocumentID = doc.id
            let alert = NSAlert()
            alert.messageText = "«\(doc.fileName)» не сохранён"
            alert.informativeText = doc.isLocal
                ? "Сохранить на диск перед закрытием?"
                : "Сохранить изменения на «\(doc.nodeName)» перед закрытием?"
            alert.addButton(withTitle: "Сохранить")
            alert.addButton(withTitle: "Не сохранять")
            alert.addButton(withTitle: "Отмена")
            switch alert.runModal() {
            case .alertFirstButtonReturn: save(doc); return false
            case .alertSecondButtonReturn: break
            default: return false
            }
        }
        close(doc)
        return true
    }

    func close(_ doc: EditorDocument) {
        EditorIPC.send(.init(kind: .closed, docID: doc.id.uuidString), to: EditorIPC.toHost)
        documents.removeAll { $0.id == doc.id }
        if activeDocumentID == doc.id { activeDocumentID = documents.last?.id }
    }

    func closeActive() { if let doc = activeDocument { _ = requestClose(doc) } }

    /// Закрыть все (кроме keep). Отмена на любом — стоп.
    func closeAll(except keep: EditorDocument? = nil) {
        for doc in documents where doc.id != keep?.id {
            if !requestClose(doc) { return }
        }
        if let keep { activeDocumentID = keep.id }
    }

    /// Копия вкладки того же файла (смотреть два места файла одновременно).
    /// Сохранение любой копии льёт в тот же путь на ноде.
    func duplicate(_ doc: EditorDocument) {
        let copy = EditorDocument(id: UUID(), sessionID: doc.sessionID, nodeName: doc.nodeName,
                                  remotePath: doc.remotePath, data: doc.rawData)
        copy.localURL = doc.localURL
        if copy.text != doc.liveText { copy.text = doc.liveText }
        documents.append(copy)
        activeDocumentID = copy.id
    }

    func copyPath(_ doc: EditorDocument) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(doc.isLocal ? (doc.localURL?.path ?? doc.fileName) : doc.remotePath, forType: .string)
        doc.setStatus("Путь скопирован")
    }

    /// Печать: моноширинный текст документа.
    func printDocument(_ doc: EditorDocument) {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: max(width, 300), height: 100))
        tv.string = doc.liveText
        tv.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        tv.isEditable = false
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            tv.frame.size.height = used.height + 20
        }
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.jobTitle = doc.fileName
        op.showsPrintPanel = true
        op.run()
    }

    // MARK: Правка

    private func edit(_ body: (EditorDocument) -> Void) {
        guard let doc = activeDocument else { return }
        body(doc)
    }

    /// Строки выделения (или весь текст, если allIfEmpty и выделения нет).
    private func editLines(_ what: String, allIfEmpty: Bool = false, _ f: ([String]) -> [String]) {
        edit { doc in
            let ns = doc.liveText as NSString
            let sel = doc.selection
            let range = (allIfEmpty && sel.length == 0)
                ? NSRange(location: 0, length: ns.length)
                : LineOps.lineRange(ns, sel)
            let parts = LineOps.split(ns.substring(with: range))
            let out = LineOps.join(f(parts.lines), trailing: parts.trailingNewline, eol: parts.eol)
            if out == ns.substring(with: range) { doc.setStatus("\(what): без изменений"); return }
            doc.replace(range, with: out)
            doc.setStatus(what)
        }
    }

    func duplicateLines() {
        edit { doc in
            let ns = doc.liveText as NSString
            let lr = LineOps.lineRange(ns, doc.selection)
            let block = ns.substring(with: lr)
            let parts = LineOps.split(block)
            let copy = parts.trailingNewline ? block : block + doc.eol.rawValue
            doc.replace(NSRange(location: lr.location, length: 0), with: copy, select: false)
            let copyLen = (copy as NSString).length
            doc.select(NSRange(location: lr.location + copyLen, length: (block as NSString).length))
        }
    }

    func deleteLines() {
        edit { doc in
            let ns = doc.liveText as NSString
            var lr = LineOps.lineRange(ns, doc.selection)
            let parts = LineOps.split(ns.substring(with: lr))
            // Последняя строка без перевода — забираем перевод предыдущей.
            if !parts.trailingNewline, lr.location > 0 {
                let prevEnd = lr.location
                var cut = 1
                if prevEnd >= 2, ns.character(at: prevEnd - 1) == 10, ns.character(at: prevEnd - 2) == 13 { cut = 2 }
                lr = NSRange(location: lr.location - cut, length: lr.length + cut)
            }
            doc.replace(lr, with: "", select: false)
        }
    }

    func moveLines(up: Bool) {
        edit { doc in
            let ns = doc.liveText as NSString
            let cur = LineOps.lineRange(ns, doc.selection)
            let eol = doc.eol.rawValue
            if up {
                guard cur.location > 0 else { return }
                let prev = ns.lineRange(for: NSRange(location: cur.location - 1, length: 0))
                var a = ns.substring(with: cur)
                var b = ns.substring(with: prev)
                if !LineOps.split(a).trailingNewline {   // cur — последняя строка файла
                    a += eol
                    b = LineOps.split(b).lines.joined(separator: eol)
                }
                let combined = NSUnionRange(prev, cur)
                doc.replace(combined, with: a + b, select: false)
                let aLen = LineOps.split(a).lines.joined(separator: eol) as NSString
                doc.select(NSRange(location: prev.location, length: aLen.length))
            } else {
                guard NSMaxRange(cur) < ns.length else { return }
                let next = ns.lineRange(for: NSRange(location: NSMaxRange(cur), length: 0))
                var a = ns.substring(with: cur)
                var b = ns.substring(with: next)
                if !LineOps.split(b).trailingNewline {   // next — последняя строка файла
                    b += eol
                    a = LineOps.split(a).lines.joined(separator: eol)
                }
                let combined = NSUnionRange(cur, next)
                doc.replace(combined, with: b + a, select: false)
                let bLen = (b as NSString).length
                let aBody = LineOps.split(a).lines.joined(separator: eol) as NSString
                doc.select(NSRange(location: cur.location + bLen, length: aBody.length))
            }
        }
    }

    func indent() {
        if let c = activeDocument?.controller { c.handleIndent(inwards: false) }
    }

    func unindent() {
        if let c = activeDocument?.controller { c.handleIndent(inwards: true) }
    }

    func toggleComment() {
        activeDocument?.controller?.handleCommandSlash()
    }

    /// Преобразовать выделение (или весь текст, если выделения нет) — канон Windows.
    func transform(_ what: String, _ f: (String) throws -> String) {
        edit { doc in
            let ns = doc.liveText as NSString
            let sel = doc.selection
            let range = sel.length > 0 ? sel : NSRange(location: 0, length: ns.length)
            do {
                let out = try f(ns.substring(with: range))
                doc.replace(range, with: out)
                doc.setStatus(what)
            } catch {
                doc.setStatus("\(what): \(error.localizedDescription)", error: true)
            }
        }
    }

    func insertDateTime() {
        edit { doc in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            doc.replace(doc.selection, with: f.string(from: Date()), select: false)
        }
    }

    // MARK: Формат

    func sortLines(desc: Bool) {
        editLines(desc ? "Отсортировано Я → А" : "Отсортировано А → Я", allIfEmpty: true) { ls in
            let s = ls.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return desc ? s.reversed() : s
        }
    }

    func uniqueLines() {
        editLines("Повторы убраны", allIfEmpty: true) { ls in
            var seen = Set<String>()
            return ls.filter { seen.insert($0).inserted }
        }
    }

    func trimTrailing() {
        editLines("Пробелы в концах строк убраны", allIfEmpty: true) { ls in
            ls.map { l in
                var s = l
                while let c = s.last, c == " " || c == "\t" { s.removeLast() }
                return s
            }
        }
    }

    func joinLines() {
        guard let doc = activeDocument else { return }
        let ns = doc.liveText as NSString
        let lr = LineOps.lineRange(ns, doc.selection)
        guard LineOps.split(ns.substring(with: lr)).lines.count > 1 else {
            doc.setStatus("Выдели несколько строк, чтобы объединить")
            return
        }
        editLines("Строки объединены") { ls in
            [ls.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")]
        }
    }

    func tabsToSpaces() {
        let unit = String(repeating: " ", count: settings.tabWidth)
        editLines("Табы → пробелы", allIfEmpty: true) { ls in ls.map { $0.replacingOccurrences(of: "\t", with: unit) } }
    }

    func spacesToTabs() {
        let unit = String(repeating: " ", count: settings.tabWidth)
        editLines("Пробелы → табы (отступы)", allIfEmpty: true) { ls in
            ls.map { l in
                var rest = Substring(l)
                var prefix = ""
                while rest.hasPrefix(unit) { prefix += "\t"; rest = rest.dropFirst(unit.count) }
                return prefix + rest
            }
        }
    }

    func convertEOL(_ e: TextCodec.EOL) {
        guard let doc = activeDocument else { return }
        let text = doc.liveText
        let converted = TextCodec.normalizeEOL(text, to: e)
        doc.eol = e
        if converted != text {
            doc.replaceInEditor(converted, status: "Концы строк: \(e.name)")
        } else {
            doc.setStatus("Концы строк: \(e.name)")
        }
        touch()
    }

    func setLanguage(_ l: CodeLanguage) {
        activeDocument?.language = l
        touch()
    }

    func setSaveEncoding(_ e: TextEncodingChoice) {
        activeDocument?.setSaveEncoding(e)
        touch()
    }

    func reopen(as e: TextEncodingChoice) {
        guard let doc = activeDocument else { return }
        if doc.isDirty && !confirm("Несохранённые правки пропадут. Открыть заново как \(e.name)?") { return }
        doc.reopen(as: e)
        touch()
    }

    // MARK: Поиск и замена

    func showFindBar(replace: Bool = false) {
        if let doc = activeDocument, findText.isEmpty {
            let sel = doc.selection
            if sel.length > 0, sel.length < 200 {
                findText = (doc.liveText as NSString).substring(with: sel)
            }
        }
        showFind = true
        findFocusToken += 1
    }

    private func regex() -> NSRegularExpression? {
        guard !findText.isEmpty else { return nil }
        var pattern = useRegex ? findText : NSRegularExpression.escapedPattern(for: findText)
        if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        do {
            return try NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
        } catch {
            findStatus = "Ошибка regex: \(error.localizedDescription)"
            return nil
        }
    }

    func findNext(backwards: Bool = false) {
        guard let doc = activeDocument else { return }
        guard let re = regex() else {
            if findText.isEmpty { showFindBar() }
            return
        }
        let text = doc.liveText
        let ns = text as NSString
        let all = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !all.isEmpty else { findStatus = "Не найдено"; NSSound.beep(); return }
        let sel = doc.selection
        let match: NSTextCheckingResult
        if backwards {
            match = all.last(where: { $0.range.location < sel.location }) ?? all[all.count - 1]
        } else {
            let from = NSMaxRange(sel)
            match = all.first(where: { $0.range.location >= from && !($0.range == sel) }) ?? all[0]
        }
        doc.select(match.range)
        let idx = (all.firstIndex(where: { $0.range == match.range }) ?? 0) + 1
        findStatus = "\(idx) из \(all.count)"
    }

    func replaceCurrent() {
        guard let doc = activeDocument, let re = regex() else { return }
        let text = doc.liveText
        let sel = doc.selection
        if sel.length > 0,
           let m = re.firstMatch(in: text, range: sel), m.range == sel {
            let replacement = useRegex
                ? re.replacementString(for: m, in: text, offset: 0, template: replaceText)
                : replaceText
            doc.replace(sel, with: replacement, select: false)
        }
        findNext()
    }

    func replaceAll() {
        guard let doc = activeDocument, let re = regex() else { return }
        let text = doc.liveText
        let ns = text as NSString
        let count = re.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
        guard count > 0 else { findStatus = "Не найдено"; return }
        let template = useRegex ? replaceText : NSRegularExpression.escapedTemplate(for: replaceText)
        let out = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
        doc.replaceInEditor(out, status: "Заменено: \(count)")
        findStatus = "Заменено: \(count)"
    }

    // MARK: Навигация и закладки

    func goToLine() {
        guard let doc = activeDocument else { return }
        let max = doc.lineCount
        let cur = doc.currentLine
        guard let s = prompt("Перейти к строке", info: "Номер строки (1–\(max)):", value: "\(cur)"),
              let n = Int(s.trimmingCharacters(in: .whitespaces)) else { return }
        jump(doc, to: min(Swift.max(n, 1), max))
    }

    func jump(_ doc: EditorDocument, to line: Int) {
        guard let r = doc.rangeOfLine(line) else { return }
        doc.select(NSRange(location: r.location, length: 0))
    }

    func toggleBookmark() {
        guard let doc = activeDocument else { return }
        let line = doc.currentLine
        if let i = doc.bookmarks.firstIndex(of: line) {
            doc.bookmarks.remove(at: i)
            doc.setStatus("Закладка снята: строка \(line)")
        } else {
            doc.bookmarks.append(line)
            doc.bookmarks.sort()
            doc.setStatus("Закладка: строка \(line)")
        }
        touch()
    }

    func nextBookmark(backwards: Bool) {
        guard let doc = activeDocument, !doc.bookmarks.isEmpty else { return }
        let line = doc.currentLine
        let target = backwards
            ? (doc.bookmarks.last(where: { $0 < line }) ?? doc.bookmarks.last!)
            : (doc.bookmarks.first(where: { $0 > line }) ?? doc.bookmarks.first!)
        jump(doc, to: target)
    }

    func clearBookmarks() {
        activeDocument?.bookmarks.removeAll()
        touch()
    }

    // MARK: Инструменты

    func hashToClipboard(_ alg: String) {
        guard let doc = activeDocument else { return }
        let sel = doc.selection
        let ns = doc.liveText as NSString
        let src = sel.length > 0 ? ns.substring(with: sel) : ns as String
        let h = TextCodec.hash(src, alg)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(h, forType: .string)
        doc.setStatus("\(alg): \(h) — в буфере")
    }

    func showStats() {
        guard let doc = activeDocument else { return }
        let t = doc.liveText
        let words = t.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let bytes = (try? TextCodec.encode(t, as: doc.encoding).count).map { String($0) } ?? "—"
        let alert = NSAlert()
        alert.messageText = "Статистика — \(doc.fileName)"
        alert.informativeText = """
        Строк: \(doc.lineCount)
        Слов: \(words)
        Символов: \(t.count)
        Байт в \(doc.encoding.name): \(bytes)
        Концы строк: \(doc.eol.name)
        """
        alert.runModal()
    }

    func compare(_ a: EditorDocument, with b: EditorDocument) {
        diffResult = DiffResult(title: "\(a.fileName) ↔ \(b.fileName)",
                                left: a.fileName, right: b.fileName,
                                lines: LineDiff.compute(old: a.liveText, new: b.liveText))
    }

    func compareWithSaved(_ doc: EditorDocument) {
        diffResult = DiffResult(title: "\(doc.fileName): сохранённое ↔ текущее",
                                left: "сохранённое", right: "текущее",
                                lines: LineDiff.compute(old: doc.savedText, new: doc.liveText))
    }

    // MARK: Диалоги

    private func confirm(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "Да")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func prompt(_ title: String, info: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func timeStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

struct DiffResult: Identifiable {
    let id = UUID()
    let title: String
    let left: String
    let right: String
    let lines: [DiffLine]
}

// MARK: - Приложение и меню (порядок MobaTextEditor)

/// Finder: «Открыть в программе → QTerm Editor», двойной щелчок по закреплённым файлам, перетаскивание
/// на иконку в доке — любые файлы, в т.ч. без расширения (authorized_keys, config, known_hosts…).
final class EditorAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private static weak var editor: EditorAppState?
    @MainActor private static var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Self.deliver(urls) }
    }

    @MainActor static func deliver(_ urls: [URL]) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        guard let ed = editor else { pending.append(contentsOf: files); return }
        for url in files { ed.openLocal(url) }
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor static func attach(_ ed: EditorAppState) {
        editor = ed
        let early = pending
        pending = []
        if !early.isEmpty { Task { @MainActor in deliver(early) } }
    }
}

@main
struct QTermEditorApp: App {
    @NSApplicationDelegateAdaptor(EditorAppDelegate.self) private var appDelegate
    @StateObject private var editor = EditorAppState()

    init() {
        // macOS 27 + русская локаль: NSAlert с SF Symbols падает, если
        // числовая локаль процесса с запятой. Держим «C».
        setlocale(LC_NUMERIC, "C")
        // типы документов (любой файл, в т.ч. без расширения) — в LaunchServices, чтобы Finder предлагал редактор
        _ = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
    }

    var body: some Scene {
        WindowGroup("Редактор — QTerm") {
            EditorRootView(editor: editor, settings: editor.settings)
                .frame(minWidth: 720, minHeight: 440)
                // файл из Finder открывается вкладкой в этом окне, а не новым окном
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in EditorAppDelegate.deliver([url]) }
        }
        .defaultSize(width: 980, height: 660)
        .commands { EditorCommands(editor: editor, settings: editor.settings) }
    }
}

struct EditorCommands: Commands {
    @ObservedObject var editor: EditorAppState
    @ObservedObject var settings: EditorSettings

    var body: some Commands {
        // Системная строка меню macOS — те же пункты, что в меню окна.
        CommandGroup(replacing: .newItem) { EdFileItems(editor: editor) }
        CommandGroup(replacing: .saveItem) { EdSaveItems(editor: editor) }
        CommandGroup(replacing: .printItem) { EdPrintItems(editor: editor) }
        CommandGroup(after: .pasteboard) { EdLineItems(editor: editor) }
        CommandMenu("Поиск") { EdSearchItems(editor: editor) }
        CommandGroup(before: .toolbar) { EdViewItems(settings: settings) }
        CommandMenu("Формат") { EdFormatItems(editor: editor, settings: settings) }
        CommandMenu("Кодировка") { EdEncodingItems(editor: editor) }
        CommandMenu("Синтаксис") { EdSyntaxItems(editor: editor) }
        CommandMenu("Инструменты") { EdToolsItems(editor: editor) }
    }
}

/// Меню в окне: без клавиш (они уже в строке меню macOS — иначе дубли).
private struct InWindowMenuKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var inWindowMenu: Bool {
        get { self[InWindowMenuKey.self] }
        set { self[InWindowMenuKey.self] = newValue }
    }
}

private struct EdKey: ViewModifier {
    @Environment(\.inWindowMenu) private var inWindow
    let key: KeyEquivalent
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        content.keyboardShortcut(inWindow ? nil : KeyboardShortcut(key, modifiers: modifiers))
    }
}

private extension View {
    func edKey(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> some View {
        modifier(EdKey(key: key, modifiers: modifiers))
    }
}

// MARK: - Пункты меню (общие: строка меню macOS и меню в окне, как у мобы)

private func fKey(_ n: Int) -> KeyEquivalent {
    KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!))
}

/// Системные действия правки через цепочку ответчиков (undo/copy…).
@MainActor
private func sendAction(_ name: String) {
    _ = NSApp.sendAction(Selector((name)), to: nil, from: nil)
}

struct EdFileItems: View {
    @ObservedObject var editor: EditorAppState
    private var doc: EditorDocument? { editor.activeDocument }

    var body: some View {
        Button("Новый документ") { editor.newDocument() }
            .edKey("n", .command)
        Button("Новая вкладка") { editor.newDocument() }
            .edKey("t", .command)
        Button("Открыть с диска…") { editor.openFromDisk() }
            .edKey("o", .command)
        Menu("Недавние файлы") {
            ForEach(editor.recentFiles, id: \.self) { p in
                Button(p) { editor.openLocal(URL(fileURLWithPath: p)) }
            }
            if editor.recentFiles.isEmpty {
                Text("Пусто")
            } else {
                Divider()
                Button("Очистить список") { editor.clearRecent() }
            }
        }
        Button("Перечитать") { if let d = doc { editor.reload(d) } }
            .edKey("r", .command)
            .disabled(doc == nil)
        Divider()
        Button("Закрыть вкладку") { editor.closeActive() }
            .edKey("w", .command)
            .disabled(doc == nil)
        Button("Закрыть остальные") { editor.closeAll(except: doc) }
            .edKey("w", [.command, .option])
            .disabled(editor.documents.count < 2)
        Button("Закрыть все") { editor.closeAll() }
            .disabled(editor.documents.isEmpty)
    }
}

struct EdSaveItems: View {
    @ObservedObject var editor: EditorAppState
    private var doc: EditorDocument? { editor.activeDocument }

    var body: some View {
        Button("Сохранить") { if let d = doc { editor.save(d) } }
            .edKey("s", .command)
            .disabled(doc == nil)
        Button("Сохранить как…") { if let d = doc { editor.saveAs(d) } }
            .edKey("s", [.command, .shift])
            .disabled(doc == nil)
        Button("Сохранить все") { editor.saveAll() }
            .edKey("s", [.command, .option])
            .disabled(!editor.documents.contains { $0.isDirty })
        Button("Отменить все правки файла") { doc?.revert() }
            .edKey("z", [.command, .option])
            .disabled(doc == nil)
        Button("Копировать путь") { if let d = doc { editor.copyPath(d) } }
            .disabled(doc == nil)
    }
}

struct EdPrintItems: View {
    @ObservedObject var editor: EditorAppState

    var body: some View {
        Button("Печать…") { if let d = editor.activeDocument { editor.printDocument(d) } }
            .edKey("p", .command)
            .disabled(editor.activeDocument == nil)
    }
}

/// Правка: строки, отступы, регистр, дата (в системном меню — после «Вставить»).
struct EdLineItems: View {
    @ObservedObject var editor: EditorAppState

    var body: some View {
        Divider()
        Button("Дублировать строку") { editor.duplicateLines() }
            .edKey("d", .command)
        Button("Удалить строку") { editor.deleteLines() }
            .edKey("k", [.command, .shift])
        Button("Строку вверх") { editor.moveLines(up: true) }
            .edKey(.upArrow, [.command, .option])
        Button("Строку вниз") { editor.moveLines(up: false) }
            .edKey(.downArrow, [.command, .option])
        Divider()
        Button("Сдвинуть вправо") { editor.indent() }
            .edKey("]", .command)
        Button("Сдвинуть влево") { editor.unindent() }
            .edKey("[", .command)
        Button("Комментарий вкл/выкл") { editor.toggleComment() }
            .edKey("/", .command)
        Menu("Регистр") {
            Button("ВЕРХНИЙ РЕГИСТР") { editor.transform("Верхний регистр") { $0.uppercased() } }
                .edKey("u", [.command, .shift])
            Button("нижний регистр") { editor.transform("Нижний регистр") { $0.lowercased() } }
                .edKey("u", [.command, .option])
            Button("Каждое Слово С Заглавной") { editor.transform("Слова с заглавной") { $0.capitalized } }
        }
        Button("Вставить дату и время") { editor.insertDateTime() }
            .edKey("d", [.command, .shift])
    }
}

/// «Правка» для меню в окне: системные undo/буфер + строчные операции.
struct EdEditItems: View {
    @ObservedObject var editor: EditorAppState

    var body: some View {
        Button("Отменить") { sendAction("undo:") }
            .edKey("z", .command)
        Button("Повторить") { sendAction("redo:") }
            .edKey("z", [.command, .shift])
        Divider()
        Button("Вырезать") { sendAction("cut:") }
            .edKey("x", .command)
        Button("Копировать") { sendAction("copy:") }
            .edKey("c", .command)
        Button("Вставить") { sendAction("paste:") }
            .edKey("v", .command)
        Button("Выделить всё") { sendAction("selectAll:") }
            .edKey("a", .command)
        EdLineItems(editor: editor)
    }
}

struct EdSearchItems: View {
    @ObservedObject var editor: EditorAppState
    private var doc: EditorDocument? { editor.activeDocument }

    var body: some View {
        Button("Найти / заменить…") { editor.showFindBar(replace: true) }
            .edKey("f", [.command, .option])
            .disabled(doc == nil)
        Button("Найти далее") { editor.findNext() }
            .edKey("g", .command)
            .disabled(doc == nil)
        Button("Найти предыдущее") { editor.findNext(backwards: true) }
            .edKey("g", [.command, .shift])
            .disabled(doc == nil)
        Divider()
        Button("Перейти к строке…") { editor.goToLine() }
            .edKey("l", .command)
            .disabled(doc == nil)
        Divider()
        Button("Закладка на строке") { editor.toggleBookmark() }
            .edKey(fKey(2), .command)
            .disabled(doc == nil)
        Button("Следующая закладка") { editor.nextBookmark(backwards: false) }
            .edKey(fKey(2), [])
            .disabled(doc?.bookmarks.isEmpty ?? true)
        Button("Предыдущая закладка") { editor.nextBookmark(backwards: true) }
            .edKey(fKey(2), .shift)
            .disabled(doc?.bookmarks.isEmpty ?? true)
        Menu("Закладки") {
            if let d = doc, !d.bookmarks.isEmpty {
                ForEach(d.bookmarks, id: \.self) { n in
                    Button("\(n):  \(d.linePreview(n))") { editor.jump(d, to: n) }
                }
                Divider()
                Button("Убрать все закладки") { editor.clearBookmarks() }
            } else {
                Text("Нет закладок")
            }
        }
    }
}

struct EdViewItems: View {
    @ObservedObject var settings: EditorSettings

    var body: some View {
        Toggle("Перенос строк", isOn: $settings.wrapLines)
        Toggle("Миникарта", isOn: $settings.showMinimap)
        Toggle("Линейка на 80 символов", isOn: $settings.showGuide)
        Divider()
        Button("Крупнее") { settings.fontSize = min(settings.fontSize + 1, 36) }
            .edKey("=", .command)
        Button("Мельче") { settings.fontSize = max(settings.fontSize - 1, 8) }
            .edKey("-", .command)
        Button("Обычный размер") { settings.fontSize = EditorSettings.defaultFont }
            .edKey("0", .command)
        Divider()
    }
}

struct EdFormatItems: View {
    @ObservedObject var editor: EditorAppState
    @ObservedObject var settings: EditorSettings
    private var doc: EditorDocument? { editor.activeDocument }

    var body: some View {
        Menu("Отступ") {
            Picker("Отступ", selection: $settings.useSpaces) {
                Text("Пробелами").tag(true)
                Text("Табами").tag(false)
            }
            .pickerStyle(.inline)
            Picker("Ширина", selection: $settings.tabWidth) {
                ForEach([2, 4, 8], id: \.self) { n in Text("Ширина \(n)").tag(n) }
            }
            .pickerStyle(.inline)
        }
        Button("Табы → пробелы") { editor.tabsToSpaces() }.disabled(doc == nil)
        Button("Пробелы → табы") { editor.spacesToTabs() }.disabled(doc == nil)
        Button("Убрать пробелы в концах строк") { editor.trimTrailing() }.disabled(doc == nil)
        Button("Объединить строки") { editor.joinLines() }
            .edKey("j", [.command, .shift])
            .disabled(doc == nil)
        Divider()
        Button("Сортировать строки А → Я") { editor.sortLines(desc: false) }.disabled(doc == nil)
        Button("Сортировать строки Я → А") { editor.sortLines(desc: true) }.disabled(doc == nil)
        Button("Убрать повторы строк") { editor.uniqueLines() }.disabled(doc == nil)
        Divider()
        Menu("Концы строк") {
            ForEach(TextCodec.EOL.allCases) { e in
                Button {
                    editor.convertEOL(e)
                } label: {
                    if doc?.eol == e { Label(e.title, systemImage: "checkmark") } else { Text(e.title) }
                }
            }
        }
        .disabled(doc == nil)
    }
}

struct EdEncodingItems: View {
    @ObservedObject var editor: EditorAppState
    private var doc: EditorDocument? { editor.activeDocument }

    var body: some View {
        Menu("Открыть заново как") {
            ForEach(TextEncodingChoice.all) { e in
                Button(e.name) { editor.reopen(as: e) }
            }
        }
        .disabled(doc == nil)
        Menu("Сохранять в") {
            ForEach(TextEncodingChoice.all) { e in
                Button {
                    editor.setSaveEncoding(e)
                } label: {
                    if doc?.encoding == e { Label(e.name, systemImage: "checkmark") } else { Text(e.name) }
                }
            }
        }
        .disabled(doc == nil)
    }
}

struct EdSyntaxItems: View {
    @ObservedObject var editor: EditorAppState
    private var doc: EditorDocument? { editor.activeDocument }

    var body: some View {
        Button {
            editor.setLanguage(.default)
        } label: {
            if doc?.language == CodeLanguage.default { Label("Обычный текст", systemImage: "checkmark") } else { Text("Обычный текст") }
        }
        .disabled(doc == nil)
        Divider()
        ForEach(CodeLanguage.allLanguages, id: \.self) { l in
            Button {
                editor.setLanguage(l)
            } label: {
                if doc?.language == l { Label(l.tsName, systemImage: "checkmark") } else { Text(l.tsName) }
            }
            .disabled(doc == nil)
        }
    }
}

struct EdToolsItems: View {
    @ObservedObject var editor: EditorAppState
    private var doc: EditorDocument? { editor.activeDocument }

    var body: some View {
        Button("Base64: закодировать") { editor.transform("Base64 ←", TextCodec.toBase64) }.disabled(doc == nil)
        Button("Base64: раскодировать") { editor.transform("Base64 →", TextCodec.fromBase64) }.disabled(doc == nil)
        Button("URL: закодировать") { editor.transform("URL ←", TextCodec.urlEncode) }.disabled(doc == nil)
        Button("URL: раскодировать") { editor.transform("URL →", TextCodec.urlDecode) }.disabled(doc == nil)
        Divider()
        Button("JSON: форматировать") { editor.transform("JSON отформатирован", TextCodec.jsonPretty) }.disabled(doc == nil)
        Button("JSON: сжать в строку") { editor.transform("JSON сжат", TextCodec.jsonMinify) }.disabled(doc == nil)
        Divider()
        Menu("Хеш выделения → буфер") {
            ForEach(TextCodec.hashNames, id: \.self) { alg in
                Button(alg) { editor.hashToClipboard(alg) }
            }
        }
        .disabled(doc == nil)
        Divider()
        Menu("Сравнить с…") {
            if let d = doc {
                Button("Сохранённой версией") { editor.compareWithSaved(d) }
                Divider()
                ForEach(editor.documents.filter { $0.id != d.id }) { other in
                    Button(other.isLocal ? other.fileName : "\(other.fileName) — \(other.nodeName)") {
                        editor.compare(d, with: other)
                    }
                }
            }
        }
        .disabled(doc == nil)
        Button("Статистика документа") { editor.showStats() }.disabled(doc == nil)
    }
}

// MARK: - Меню и панель инструментов в окне (как у MobaTextEditor)

struct EditorMenuBar: View {
    @ObservedObject var editor: EditorAppState
    @ObservedObject var settings: EditorSettings

    var body: some View {
        HStack(spacing: 2) {
            menu("Файл") {
                EdFileItems(editor: editor)
                Divider()
                EdSaveItems(editor: editor)
                Divider()
                EdPrintItems(editor: editor)
            }
            menu("Правка") { EdEditItems(editor: editor) }
            menu("Поиск") { EdSearchItems(editor: editor) }
            menu("Вид") { EdViewItems(settings: settings) }
            menu("Формат") { EdFormatItems(editor: editor, settings: settings) }
            menu("Кодировка") { EdEncodingItems(editor: editor) }
            menu("Синтаксис") { EdSyntaxItems(editor: editor) }
            menu("Инструменты") { EdToolsItems(editor: editor) }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .environment(\.inWindowMenu, true)
    }

    private func menu<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Menu(title, content: content)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 6)
    }
}

struct EditorToolbar: View {
    @ObservedObject var editor: EditorAppState
    @ObservedObject var settings: EditorSettings
    private var doc: EditorDocument? { editor.activeDocument }

    var body: some View {
        HStack(spacing: 2) {
            tool("doc.badge.plus", "Новый (⌘N)") { editor.newDocument() }
            tool("folder", "Открыть с диска (⌘O)") { editor.openFromDisk() }
            tool("square.and.arrow.down", "Сохранить (⌘S)", disabled: !(doc?.isDirty ?? false)) {
                if let d = doc { editor.save(d) }
            }
            tool("square.and.arrow.down.on.square", "Сохранить все (⌥⌘S)",
                 disabled: !editor.documents.contains { $0.isDirty }) { editor.saveAll() }
            tool("arrow.clockwise", "Перечитать (⌘R)", disabled: doc == nil) {
                if let d = doc { editor.reload(d) }
            }
            tool("printer", "Печать (⌘P)", disabled: doc == nil) {
                if let d = doc { editor.printDocument(d) }
            }
            sep
            tool("arrow.uturn.backward", "Отменить (⌘Z)", disabled: doc == nil) { sendAction("undo:") }
            tool("arrow.uturn.forward", "Повторить (⇧⌘Z)", disabled: doc == nil) { sendAction("redo:") }
            sep
            tool("scissors", "Вырезать (⌘X)", disabled: doc == nil) { sendAction("cut:") }
            tool("doc.on.doc", "Копировать (⌘C)", disabled: doc == nil) { sendAction("copy:") }
            tool("doc.on.clipboard", "Вставить (⌘V)", disabled: doc == nil) { sendAction("paste:") }
            sep
            tool("magnifyingglass", "Найти / заменить (⌥⌘F)", disabled: doc == nil) { editor.showFindBar(replace: true) }
            tool("number", "Перейти к строке (⌘L)", disabled: doc == nil) { editor.goToLine() }
            tool("bookmark", "Закладка на строке (⌘F2)", disabled: doc == nil) { editor.toggleBookmark() }
            sep
            tool("increase.indent", "Сдвинуть вправо (⌘])", disabled: doc == nil) { editor.indent() }
            tool("decrease.indent", "Сдвинуть влево (⌘[)", disabled: doc == nil) { editor.unindent() }
            tool("text.bubble", "Комментарий (⌘/)", disabled: doc == nil) { editor.toggleComment() }
            sep
            toggle("text.word.spacing", "Перенос строк", $settings.wrapLines)
            toggle("map", "Миникарта", $settings.showMinimap)
            tool("textformat.size.larger", "Крупнее (⌘=)") { settings.fontSize = min(settings.fontSize + 1, 36) }
            tool("textformat.size.smaller", "Мельче (⌘-)") { settings.fontSize = max(settings.fontSize - 1, 8) }
            sep
            tool("arrow.left.arrow.right", "Сравнить с сохранённой версией", disabled: doc == nil) {
                if let d = doc { editor.compareWithSaved(d) }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private var sep: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func tool(_ symbol: String, _ help: String, disabled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
        .disabled(disabled)
    }

    private func toggle(_ symbol: String, _ help: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Image(systemName: symbol).frame(width: 20, height: 16)
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Окно редактора

struct EditorRootView: View {
    @ObservedObject var editor: EditorAppState
    @ObservedObject var settings: EditorSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Меню и панель инструментов в окне — как у MobaTextEditor
            // (те же пункты есть и в строке меню macOS вверху экрана).
            EditorMenuBar(editor: editor, settings: settings)
            Divider()
            EditorToolbar(editor: editor, settings: settings)
            Divider()
            if editor.documents.isEmpty {
                emptyState
            } else {
                tabBar
                Divider()
                if editor.showFind {
                    FindBar(editor: editor)
                    Divider()
                }
                // Все панели живут одновременно: переключение вкладки не
                // пересоздаёт редактор, поэтому скролл, выделение и undo-стек
                // каждого файла остаются на месте.
                //
                // GeometryReader ОБЯЗАТЕЛЕН: intrinsic-ширина CodeEdit равна
                // самой длинной строке файла и распирает VStack шире окна —
                // контент (включая ленту вкладок) вылезал за левый край.
                GeometryReader { geo in
                    ZStack {
                        ForEach(editor.documents) { doc in
                            EditorPane(doc: doc, settings: settings,
                                       theme: colorScheme == .dark ? .qtermDark : .qtermLight)
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
                    EditorStatusBar(doc: doc, editor: editor)
                }
            }
        }
        // Кнопки-невидимки для шорткатов окна (меню их не перехватывает).
        .background {
            Group {
                Button("") { if let d = editor.activeDocument { editor.save(d) } }
                    .keyboardShortcut("s", modifiers: .command)
                Button("") { editor.activeDocument?.revert() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .sheet(item: $editor.diffResult) { r in
            DiffView(result: r)
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
                EditorTabButton(doc: doc, editor: editor, isActive: doc.id == editor.activeDocumentID)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Полоса поиска и замены: regex, регистр, слово целиком.
private struct FindBar: View {
    @ObservedObject var editor: EditorAppState
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Найти", text: $editor.findText)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFocused)
                    .onSubmit { editor.findNext() }
                    .frame(minWidth: 180)
                toggle(".*", "Регулярное выражение", $editor.useRegex)
                toggle("Aa", "Учитывать регистр", $editor.matchCase)
                toggle("\\b", "Слово целиком", $editor.wholeWord)
                Button { editor.findNext(backwards: true) } label: { Image(systemName: "chevron.up") }
                    .help("Предыдущее (⇧⌘G)")
                Button { editor.findNext() } label: { Image(systemName: "chevron.down") }
                    .help("Следующее (⌘G, ↩)")
                Text(editor.findStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    editor.showFind = false
                    editor.activeDocument?.select(editor.activeDocument?.selection ?? NSRange(location: 0, length: 0))
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6) {
                TextField(editor.useRegex ? "Заменить ($1 — группа)" : "Заменить", text: $editor.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.replaceCurrent() }
                    .frame(minWidth: 180)
                Button("Заменить") { editor.replaceCurrent() }
                Button("Заменить все") { editor.replaceAll() }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear { findFocused = true }
        .onChange(of: editor.findFocusToken) { _, _ in findFocused = true }
        .onChange(of: editor.findText) { _, _ in editor.findStatus = "" }
    }

    private func toggle(_ label: String, _ help: String, _ value: Binding<Bool>) -> some View {
        Toggle(label, isOn: value)
            .toggleStyle(.button)
            .font(.system(.caption, design: .monospaced))
            .help(help)
    }
}

/// Статус-бар: где файл, строка:колонка, синтаксис, кодировка, концы строк.
private struct EditorStatusBar: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var editor: EditorAppState

    var body: some View {
        HStack(spacing: 10) {
            Text(doc.locationText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let pos = doc.cursorPositions.first {
                Text("Стр \(pos.line), Кол \(pos.column)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !doc.bookmarks.isEmpty {
                Text("🔖 \(doc.bookmarks.count)").font(.caption).foregroundStyle(.secondary)
                    .help("Закладки: F2 / ⇧F2")
            }
            Spacer()
            if let status = doc.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(doc.statusIsError ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Menu(doc.language == CodeLanguage.default ? "Текст" : doc.language.tsName) {
                Button("Обычный текст") { editor.setLanguage(.default) }
                Divider()
                ForEach(CodeLanguage.allLanguages, id: \.self) { l in
                    Button(l.tsName) { editor.setLanguage(l) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().font(.caption)
            .help("Синтаксис")
            Menu(doc.encoding.name) {
                Section("Сохранять в") {
                    ForEach(TextEncodingChoice.all) { e in
                        Button(e.name) { editor.setSaveEncoding(e) }
                    }
                }
                Section("Открыть заново как") {
                    ForEach(TextEncodingChoice.all) { e in
                        Button(e.name) { editor.reopen(as: e) }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().font(.caption)
            .help("Кодировка файла")
            Menu(doc.eol.name) {
                ForEach(TextCodec.EOL.allCases) { e in
                    Button(e.title) { editor.convertEOL(e) }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().font(.caption)
            .help("Концы строк")
            if doc.isDirty {
                Button {
                    doc.revert()
                } label: {
                    Label("Отменить правки", systemImage: "arrow.uturn.backward")
                }
                .help("Вернуть файл к сохранённому состоянию (⌘⌥Z)")
            }
            Button {
                editor.save(doc)
            } label: {
                Label("Сохранить", systemImage: "arrow.up.doc")
            }
            .disabled(!doc.isDirty)
            .help(doc.isLocal ? "⌘S — на диск" : "⌘S — залить на \(doc.nodeName)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

/// Вкладка файла в ленте редактора.
private struct EditorTabButton: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var editor: EditorAppState
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(doc.fileName)
                .lineLimit(1)
            if doc.isDirty {
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
            Button {
                _ = editor.requestClose(doc)
            } label: {
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
        .onTapGesture { editor.activeDocumentID = doc.id }
        .contextMenu {
            Button("Сохранить") { editor.save(doc) }
            Button("Сохранить как…") { editor.saveAs(doc) }
            Button("Перечитать") { editor.reload(doc) }
            Divider()
            Button("Копировать путь") { editor.copyPath(doc) }
            Button("Дублировать вкладку") { editor.duplicate(doc) }
            if let active = editor.activeDocument, active.id != doc.id {
                Button("Сравнить с активной") { editor.compare(active, with: doc) }
            }
            Divider()
            Button("Закрыть") { _ = editor.requestClose(doc) }
            Button("Закрыть остальные") { editor.closeAll(except: doc) }
            Button("Закрыть все") { editor.closeAll() }
        }
        .help(doc.locationText)
    }
}

/// Сам редактор (CodeEditSourceEditor поверх tree-sitter).
private struct EditorPane: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var settings: EditorSettings
    let theme: EditorTheme

    var body: some View {
        CodeEditSourceEditor(
            $doc.text,
            language: doc.language,
            theme: theme,
            font: NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular),
            tabWidth: settings.tabWidth,
            indentOption: settings.useSpaces ? .spaces(count: settings.tabWidth) : .tab,
            lineHeight: 1.2,
            wrapLines: settings.wrapLines,
            cursorPositions: $doc.cursorPositions,
            coordinators: [doc.coordinator],
            showMinimap: settings.showMinimap,
            reformatAtColumn: 80,
            showReformattingGuide: settings.showGuide
        )
    }
}

/// Сравнение: построчный diff (− было, + стало).
private struct DiffView: View {
    let result: DiffResult
    @Environment(\.dismiss) private var dismiss

    private var stats: (added: Int, removed: Int) {
        (result.lines.filter { $0.kind == .added }.count, result.lines.filter { $0.kind == .removed }.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(result.title).font(.headline).lineLimit(1)
                Spacer()
                Text("− \(result.left): \(stats.removed)   + \(result.right): \(stats.added)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if stats.added == 0 && stats.removed == 0 {
                Text("Отличий нет").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(result.lines) { l in
                            row(l)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private func row(_ l: DiffLine) -> some View {
        let sign: String, bg: Color
        switch l.kind {
        case .same: sign = " "; bg = .clear
        case .removed: sign = "−"; bg = Color.red.opacity(0.18)
        case .added: sign = "+"; bg = Color.green.opacity(0.18)
        }
        return HStack(spacing: 6) {
            Text(l.oldNumber.map { String($0) } ?? "").frame(width: 44, alignment: .trailing)
            Text(l.newNumber.map { String($0) } ?? "").frame(width: 44, alignment: .trailing)
            Text(sign).frame(width: 12)
            Text(l.text.isEmpty ? " " : l.text)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(l.kind == .same ? Color.secondary : Color.primary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
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
