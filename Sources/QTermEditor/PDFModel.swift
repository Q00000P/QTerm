import AppKit
import PDFKit
import Combine
import UniformTypeIdentifiers

// MARK: - PDF в редакторе (волна 19: просмотр, разметка, страницы)
//
// Нативный PDFKit, без зависимостей. Вкладка PDF живёт в той же ленте, что и
// текстовые: ⌘S льёт байты на ноду (или на диск) через тот же EditorBridge.
// Модель держит PDFView сама — так печать, поиск, выделение и миниатюры
// работают из меню, а не только из SwiftUI-обёртки.
//
// Отмена: снимок байтов документа перед каждой операцией (страницы,
// аннотации, перестановка в миниатюрах) → UndoManager восстанавливает
// документ целиком. Дёшево по коду, надёжно по результату.

/// Инструмент разметки на странице.
enum PDFTool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strikeout, note, text, rect, ink, image, signature
    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Выделение"
        case .highlight: return "Маркер"
        case .underline: return "Подчеркнуть"
        case .strikeout: return "Зачеркнуть"
        case .note: return "Заметка"
        case .text: return "Текст"
        case .rect: return "Рамка"
        case .ink: return "Карандаш"
        case .image: return "Картинка"
        case .signature: return "Подпись"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeout: return "strikethrough"
        case .note: return "note.text"
        case .text: return "character.textbox"
        case .rect: return "rectangle"
        case .ink: return "pencil.tip"
        case .image: return "photo"
        case .signature: return "signature"
        }
    }

    var help: String {
        switch self {
        case .select: return "Выделение текста и форм (Esc)"
        case .highlight: return "Маркер: выдели текст, затем нажми, или рисуй рамкой по тексту"
        case .underline: return "Подчеркнуть выделенный текст (или рамкой)"
        case .strikeout: return "Зачеркнуть выделенный текст (или рамкой)"
        case .note: return "Заметка: клик по странице"
        case .text: return "Текст поверх страницы: растяни рамку"
        case .rect: return "Рамка: растяни прямоугольник"
        case .ink: return "Рисовать от руки"
        case .image: return "Картинка с диска: растяни рамку (впечатывается в страницу)"
        case .signature: return "Подпись (сохранённая картинка): растяни рамку"
        }
    }

    /// Инструменты, которые тянут рамку/линию по странице.
    var isDrawing: Bool { self != .select }
    /// Для выделенного текста: применяется кнопкой без рисования.
    var isMarkup: Bool { self == .highlight || self == .underline || self == .strikeout }
}

/// Цвета разметки (общие для всех инструментов).
enum PDFInkColor: String, CaseIterable, Identifiable {
    case yellow, green, pink, blue, red, black
    var id: String { rawValue }
    var title: String {
        switch self {
        case .yellow: return "Жёлтый"
        case .green: return "Зелёный"
        case .pink: return "Розовый"
        case .blue: return "Синий"
        case .red: return "Красный"
        case .black: return "Чёрный"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.23, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.55, green: 0.92, blue: 0.45, alpha: 1)
        case .pink: return NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.75, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.45, green: 0.7, blue: 1.0, alpha: 1)
        case .red: return NSColor(calibratedRed: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        case .black: return .black
        }
    }
}

/// Документ PDF одной вкладки: PDFView, миниатюры, инструменты, отмена.
@MainActor
final class PDFModel: ObservableObject {
    let pdfView: QPDFView
    let thumbView: QThumbView
    let undo = UndoManager()

    @Published private(set) var document: PDFDocument?
    @Published var isDirty = false
    @Published var currentPageIndex = 0
    @Published var pageCount = 0
    @Published var scale: CGFloat = 1
    @Published var tool: PDFTool = .select { didSet { pdfView.toolChanged() } }
    @Published var color: PDFInkColor = .yellow
    @Published var inkWidth: CGFloat = 2.5
    @Published var showThumbnails: Bool = UserDefaults.standard.object(forKey: "pdf.thumbs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showThumbnails, forKey: "pdf.thumbs") }
    }
    @Published var isLocked = false
    /// Результаты поиска (текущий — подсвечен и показан).
    @Published private(set) var findResults: [PDFSelection] = []
    @Published private(set) var findIndex = -1
    /// Последняя аннотация, по которой кликнули (⌫ удаляет, меню правит текст).
    @Published private(set) var hitAnnotation: PDFAnnotation?

    /// Статус в строку состояния вкладки (документ подписывает себя).
    var status: @MainActor (String, Bool) -> Void = { _, _ in }

    private var tokens: [NSObjectProtocol] = []

    init(data: Data) {
        pdfView = QPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        thumbView = QThumbView(frame: NSRect(x: 0, y: 0, width: 150, height: 600))
        pdfView.model = self
        thumbView.model = self
        thumbView.pdfView = pdfView
        thumbView.thumbnailSize = NSSize(width: 110, height: 110)
        thumbView.allowsDragging = true
        thumbView.maximumNumberOfColumns = 1
        thumbView.backgroundColor = .windowBackgroundColor
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = 0.2
        pdfView.maxScaleFactor = 8
        pdfView.enableDataDetectors = true
        undo.levelsOfUndo = data.count > 12 * 1024 * 1024 ? 4 : 20

        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncPage() }
        })
        tokens.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scale = self?.pdfView.scaleFactor ?? 1 }
        })
        tokens.append(nc.addObserver(forName: .PDFViewAnnotationHit, object: pdfView, queue: .main) { [weak self] note in
            let ann = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation
            Task { @MainActor in self?.annotationHit(ann) }
        })
        load(data)
    }

    deinit {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
    }

    // MARK: Загрузка и байты

    /// Поднять документ из байтов (открытие, перечитать, откат, отмена).
    @discardableResult
    func load(_ data: Data) -> Bool {
        guard let doc = PDFDocument(data: data) else {
            document = nil
            pdfView.document = nil
            pageCount = 0
            status("Файл не читается как PDF", true)
            return false
        }
        install(doc, keepPage: false)
        isDirty = false
        undo.removeAllActions()
        isLocked = doc.isLocked
        if doc.isLocked { status("PDF защищён паролем — меню PDF → Снять пароль…", true) }
        return true
    }

    private func install(_ doc: PDFDocument, keepPage: Bool) {
        let page = keepPage ? currentPageIndex : 0
        document = doc
        pdfView.document = doc
        pageCount = doc.pageCount
        findResults = []
        findIndex = -1
        hitAnnotation = nil
        if let p = doc.page(at: min(page, max(doc.pageCount - 1, 0))) { pdfView.go(to: p) }
        syncPage()
        scale = pdfView.scaleFactor
    }

    /// Текущие байты документа (для ⌘S и снимков отмены).
    func data() -> Data? {
        document?.dataRepresentation()
    }

    func unlock(password: String) -> Bool {
        guard let doc = document else { return false }
        if doc.unlock(withPassword: password) {
            isLocked = false
            pageCount = doc.pageCount
            syncPage()
            status("Пароль снят — при сохранении файл запишется без пароля", false)
            return true
        }
        status("Пароль не подошёл", true)
        return false
    }

    private func syncPage() {
        guard let doc = document, let p = pdfView.currentPage else { currentPageIndex = 0; return }
        currentPageIndex = doc.index(for: p)
    }

    func markDirty() {
        if !isDirty { isDirty = true }
    }

    // MARK: Отмена (снимок байтов)

    /// Снимок перед операцией: отмена вернёт документ целиком.
    private func snapshot(_ name: String) {
        guard let before = data() else { return }
        undo.registerUndo(withTarget: self) { m in
            let after = m.data()
            m.restore(before)
            if let after {
                m.undo.registerUndo(withTarget: m) { m2 in m2.redoRestore(after, before: before, name: name) }
            }
        }
        undo.setActionName(name)
    }

    private func redoRestore(_ after: Data, before: Data, name: String) {
        restore(after)
        undo.registerUndo(withTarget: self) { m in
            m.restore(before)
            m.undo.registerUndo(withTarget: m) { m2 in m2.redoRestore(after, before: before, name: name) }
        }
        undo.setActionName(name)
    }

    private func restore(_ data: Data) {
        guard let doc = PDFDocument(data: data) else { return }
        install(doc, keepPage: true)
        isDirty = true
        status("Отмена: \(undo.undoActionName.isEmpty ? "документ восстановлен" : undo.undoActionName)", false)
    }

    /// Миниатюры: перетаскивание начато / закончено — сверяем порядок страниц.
    /// Отмена — обратная перестановка объектов страниц (без снимка байтов:
    /// клик по миниатюре не должен стоить сериализации документа).
    private var dragOrder: [PDFPage]?

    private func pageOrder() -> [PDFPage] {
        guard let doc = document else { return [] }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0) }
    }

    func thumbDragBegan() {
        dragOrder = pageOrder()
    }

    func thumbDragEnded() {
        guard let before = dragOrder else { return }
        dragOrder = nil
        let after = pageOrder()
        guard after.count == before.count, after.map(ObjectIdentifier.init) != before.map(ObjectIdentifier.init) else { return }
        registerReorder(from: before, to: after)
        markDirty()
        syncPage()
        status("Страницы переставлены", false)
    }

    private func registerReorder(from before: [PDFPage], to after: [PDFPage]) {
        undo.registerUndo(withTarget: self) { m in
            m.applyOrder(before)
            m.registerReorder(from: after, to: before)
        }
        undo.setActionName("Перестановка страниц")
    }

    private func applyOrder(_ order: [PDFPage]) {
        guard let doc = document, order.count == doc.pageCount else { return }
        let current = pageOrder()
        guard Set(current.map(ObjectIdentifier.init)) == Set(order.map(ObjectIdentifier.init)) else { return }
        // Обменами, без удаления: страницы остаются в документе.
        var cur = current
        for i in 0..<order.count {
            guard let j = cur.firstIndex(where: { $0 === order[i] }), j != i else { continue }
            doc.exchangePage(at: i, withPageAt: j)
            cur.swapAt(i, j)
        }
        pdfView.layoutDocumentView()
        isDirty = true
        syncPage()
        status("Отмена: перестановка страниц", false)
    }

    // MARK: Навигация и масштаб

    var currentPage: PDFPage? { pdfView.currentPage }

    func go(toPage index: Int) {
        guard let doc = document, doc.pageCount > 0 else { return }
        let i = min(max(index, 0), doc.pageCount - 1)
        if let p = doc.page(at: i) { pdfView.go(to: p) }
    }

    func nextPage() { if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) } }
    func previousPage() { if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) } }

    func zoomIn() { pdfView.autoScales = false; pdfView.scaleFactor = min(pdfView.scaleFactor * 1.2, pdfView.maxScaleFactor) }
    func zoomOut() { pdfView.autoScales = false; pdfView.scaleFactor = max(pdfView.scaleFactor / 1.2, pdfView.minScaleFactor) }
    func zoomActual() { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    func fitWidth() { pdfView.autoScales = true; scale = pdfView.scaleFactor }

    func fitPage() {
        guard let page = pdfView.currentPage else { return }
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pw = rotated ? box.height : box.width
        let ph = rotated ? box.width : box.height
        let avail = pdfView.bounds.insetBy(dx: 12, dy: 12).size
        guard pw > 0, ph > 0, avail.width > 0, avail.height > 0 else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(avail.width / pw, avail.height / ph)
    }

    // MARK: Поиск

    func find(_ text: String, matchCase: Bool) -> String {
        guard let doc = document else { return "" }
        guard !text.isEmpty else { clearFind(); return "" }
        let results = doc.findString(text, withOptions: matchCase ? [] : [.caseInsensitive])
        findResults = results
        pdfView.highlightedSelections = results.isEmpty ? nil : results.map { s in
            let c = s.copy() as! PDFSelection
            c.color = NSColor.systemYellow.withAlphaComponent(0.5)
            return c
        }
        findIndex = -1
        if results.isEmpty { NSSound.beep(); return "Не найдено" }
        return findStep(backwards: false)
    }

    /// Следующее/предыдущее совпадение; возвращает текст статуса «3 из 17».
    func findStep(backwards: Bool) -> String {
        guard !findResults.isEmpty else { return "Не найдено" }
        if backwards {
            findIndex = findIndex <= 0 ? findResults.count - 1 : findIndex - 1
        } else {
            findIndex = (findIndex + 1) % findResults.count
        }
        let sel = findResults[findIndex]
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.go(to: sel)
        return "\(findIndex + 1) из \(findResults.count)"
    }

    func clearFind() {
        findResults = []
        findIndex = -1
        pdfView.highlightedSelections = nil
    }

    // MARK: Аннотации

    private func annotationHit(_ ann: PDFAnnotation?) {
        hitAnnotation = ann
        // Поле формы: после клика в него будет ввод — считаем документ изменённым.
        if let ann, ann.isWidgetLike { markDirty() }
    }

    private var hitIsWidget: Bool { hitAnnotation?.isWidgetLike ?? false }

    /// Маркер/подчёркивание/зачёркивание выделенного текста (или рамки по тексту).
    func markupSelection(_ kind: PDFTool, selection: PDFSelection? = nil) {
        guard kind.isMarkup else { return }
        let sel = selection ?? pdfView.currentSelection
        guard let sel, !(sel.string ?? "").isEmpty else {
            status("Сначала выдели текст на странице", true)
            return
        }
        snapshot(kind.title)
        var n = 0
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 1, b.height > 1 else { continue }
                let sub: PDFAnnotationSubtype = kind == .highlight ? .highlight : (kind == .underline ? .underline : .strikeOut)
                let ann = PDFAnnotation(bounds: b, forType: sub, withProperties: nil)
                ann.color = color.nsColor
                page.addAnnotation(ann)
                n += 1
            }
        }
        pdfView.setCurrentSelection(nil, animate: false)
        markDirty()
        status("\(kind.title): \(n) стр.", false)
    }

    /// Рамка по странице инструментом: текст под ней → разметка, иначе ничего.
    func markupRect(_ kind: PDFTool, rect: CGRect, page: PDFPage) {
        guard let sel = page.selection(for: rect), !(sel.string ?? "").isEmpty else {
            status("Под рамкой нет текста", true)
            return
        }
        markupSelection(kind, selection: sel)
    }

    func addNote(at point: CGPoint, page: PDFPage) {
        guard let text = PDFModel.prompt("Заметка", info: "Текст заметки:", value: "", multiline: true), !text.isEmpty else { return }
        snapshot("Заметка")
        let ann = PDFAnnotation(bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), forType: .text, withProperties: nil)
        ann.iconType = .note
        ann.contents = text
        ann.color = color.nsColor
        page.addAnnotation(ann)
        markDirty()
        status("Заметка добавлена", false)
    }

    func addFreeText(in rect: CGRect, page: PDFPage) {
        guard let text = PDFModel.prompt("Текст на странице", info: "Что написать:", value: "", multiline: true), !text.isEmpty else { return }
        snapshot("Текст")
        var r = rect.standardized
        if r.width < 40 { r.size.width = 160 }
        if r.height < 14 { r.size.height = 24 }
        let ann = PDFAnnotation(bounds: r, forType: .freeText, withProperties: nil)
        ann.contents = text
        ann.font = NSFont.systemFont(ofSize: max(10, min(r.height * 0.7, 28)))
        ann.fontColor = color == .yellow ? .black : color.nsColor
        ann.color = .clear
        ann.alignment = .left
        let border = PDFBorder()
        border.lineWidth = 0
        ann.border = border
        page.addAnnotation(ann)
        markDirty()
        status("Текст добавлен", false)
    }

    func addRect(_ rect: CGRect, page: PDFPage) {
        let r = rect.standardized
        guard r.width > 2, r.height > 2 else { return }
        snapshot("Рамка")
        let ann = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
        ann.color = color.nsColor
        let border = PDFBorder()
        border.lineWidth = inkWidth
        ann.border = border
        page.addAnnotation(ann)
        markDirty()
        status("Рамка добавлена", false)
    }

    func addInk(points: [CGPoint], page: PDFPage) {
        guard points.count > 1 else { return }
        snapshot("Карандаш")
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX, maxX = -minX, maxY = -minX
        for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        let pad = inkWidth + 2
        let bounds = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        let ann = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        ann.color = color.nsColor
        let border = PDFBorder()
        border.lineWidth = inkWidth
        ann.border = border
        let path = NSBezierPath()
        path.lineWidth = inkWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // Путь — в координатах относительно bounds аннотации.
        path.move(to: NSPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
        for p in points.dropFirst() { path.line(to: NSPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)) }
        ann.add(path)
        page.addAnnotation(ann)
        markDirty()
    }

    func deleteHitAnnotation() {
        guard let ann = hitAnnotation, let page = ann.page, !ann.isWidgetLike else {
            status("Кликни по аннотации, которую удалить", true)
            return
        }
        snapshot("Удалить аннотацию")
        page.removeAnnotation(ann)
        hitAnnotation = nil
        markDirty()
        status("Аннотация удалена", false)
    }

    func editHitAnnotationText() {
        guard let ann = hitAnnotation, !ann.isWidgetLike else {
            status("Кликни по заметке или тексту, который править", true)
            return
        }
        guard let text = PDFModel.prompt("Текст аннотации", info: "", value: ann.contents ?? "", multiline: true) else { return }
        snapshot("Текст аннотации")
        ann.contents = text
        markDirty()
    }

    func deleteAllAnnotations(onPageOnly: Bool) {
        guard let doc = document else { return }
        let pages: [PDFPage] = onPageOnly ? [currentPage].compactMap { $0 } : (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        let victims = pages.flatMap { p in p.annotations.filter { !$0.isWidgetLike }.map { (p, $0) } }
        guard !victims.isEmpty else { status("Аннотаций нет", false); return }
        guard PDFModel.confirm("Удалить аннотации (\(victims.count))\(onPageOnly ? " на этой странице" : " во всём документе")? Поля форм останутся.") else { return }
        snapshot("Удалить аннотации")
        for (p, a) in victims { p.removeAnnotation(a) }
        hitAnnotation = nil
        markDirty()
        status("Удалено аннотаций: \(victims.count)", false)
    }

    // MARK: Картинка и подпись (впечатываются в страницу)

    static var signatureURL: URL? {
        get { UserDefaults.standard.string(forKey: "pdf.signature").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "pdf.signature") }
    }

    /// Выбрать картинку подписи (png с прозрачностью лучше всего).
    @discardableResult
    func pickSignature() -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .pdf]
        panel.message = "Картинка подписи (png с прозрачным фоном — лучший вариант)"
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return nil }
        PDFModel.signatureURL = url
        status("Подпись: \(url.lastPathComponent)", false)
        return img
    }

    func signatureImage() -> NSImage? {
        if let url = PDFModel.signatureURL, let img = NSImage(contentsOf: url) { return img }
        return pickSignature()
    }

    func pickImage() -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp]
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return nil }
        return img
    }

    /// Впечатать картинку в страницу (рамка → пропорции по ширине).
    func bake(image: NSImage, into rect: CGRect, page: PDFPage) {
        guard let doc = document else { return }
        var r = rect.standardized
        if r.width < 8 { r.size.width = 150 }
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        r.size.height = r.width / max(aspect, 0.01)
        if rect.standardized.height > 8 {
            // пользователь задал высоту рамкой — рисуем сверху вниз от верхнего края рамки
            r.origin.y = rect.standardized.maxY - r.height
        }
        guard let newPage = PDFPageBaker.bake(image: image, rect: r, page: page) else {
            status("Не удалось впечатать картинку", true)
            return
        }
        snapshot("Картинка")
        let idx = doc.index(for: page)
        let keep = page.annotations.filter { $0.isWidgetLike }
        doc.removePage(at: idx)
        doc.insert(newPage, at: idx)
        for a in keep { newPage.addAnnotation(a) }
        if let p = doc.page(at: idx) { pdfView.go(to: p) }
        pageCount = doc.pageCount
        markDirty()
        status("Картинка впечатана в страницу \(idx + 1)", false)
    }

    // MARK: Страницы

    func rotateCurrent(by degrees: Int) {
        guard let page = currentPage else { return }
        rotate([page], by: degrees, name: "Поворот страницы")
        status("Страница \(currentPageIndex + 1): поворот \(page.rotation)°", false)
    }

    func rotateAll(by degrees: Int) {
        rotate(pageOrder(), by: degrees, name: "Поворот всех страниц")
        status("Все страницы повёрнуты", false)
    }

    /// Поворот без снимка байтов: отмена — поворот обратно.
    private func rotate(_ pages: [PDFPage], by degrees: Int, name: String) {
        guard !pages.isEmpty else { return }
        for p in pages { p.rotation = (p.rotation + degrees + 360) % 360 }
        pdfView.layoutDocumentView()
        markDirty()
        undo.registerUndo(withTarget: self) { m in m.rotate(pages, by: -degrees, name: name) }
        undo.setActionName(name)
    }

    func deleteCurrentPage() {
        guard let doc = document, doc.pageCount > 1 else { status("Последнюю страницу удалить нельзя", true); return }
        let idx = currentPageIndex
        snapshot("Удалить страницу")
        doc.removePage(at: idx)
        pageCount = doc.pageCount
        go(toPage: idx)
        markDirty()
        status("Страница \(idx + 1) удалена", false)
    }

    /// Удалить страницы по диапазону «1-3, 7».
    func deletePages(spec: String) {
        guard let doc = document, let set = PDFModel.parseRanges(spec, max: doc.pageCount) else { status("Непонятный диапазон", true); return }
        guard set.count < doc.pageCount else { status("Все страницы удалить нельзя", true); return }
        snapshot("Удалить страницы")
        for i in set.sorted(by: >) { doc.removePage(at: i) }
        pageCount = doc.pageCount
        go(toPage: min(currentPageIndex, doc.pageCount - 1))
        markDirty()
        status("Удалено страниц: \(set.count)", false)
    }

    func moveCurrentPage(by delta: Int) {
        guard let doc = document else { return }
        let from = currentPageIndex
        let to = from + delta
        guard to >= 0, to < doc.pageCount else { return }
        snapshot("Переместить страницу")
        doc.exchangePage(at: from, withPageAt: to)
        go(toPage: to)
        markDirty()
    }

    /// Вставить страницы другого PDF (после текущей или в конец).
    func insertPDF(append: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = append ? "PDF для добавления в конец" : "PDF для вставки после страницы \(currentPageIndex + 1)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty, let doc = document else { return }
        snapshot("Вставить PDF")
        var at = append ? doc.pageCount : currentPageIndex + 1
        var n = 0
        for url in panel.urls {
            guard let src = PDFDocument(url: url) else { status("Не читается: \(url.lastPathComponent)", true); continue }
            if src.isLocked { status("Защищён паролем: \(url.lastPathComponent)", true); continue }
            for i in 0..<src.pageCount {
                guard let p = src.page(at: i), let copy = p.copy() as? PDFPage else { continue }
                doc.insert(copy, at: at)
                at += 1
                n += 1
            }
        }
        pageCount = doc.pageCount
        markDirty()
        status("Вставлено страниц: \(n)", false)
    }

    /// Картинка как новая страница (после текущей).
    func insertImagePage() {
        guard let doc = document, let img = pickImage(), let page = PDFPage(image: img) else { return }
        snapshot("Страница из картинки")
        let at = doc.pageCount == 0 ? 0 : currentPageIndex + 1
        doc.insert(page, at: at)
        pageCount = doc.pageCount
        go(toPage: at)
        markDirty()
        status("Страница из картинки вставлена", false)
    }

    func insertBlankPage() {
        guard let doc = document else { return }
        let box = currentPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let size = NSSize(width: box.width, height: box.height)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor.white.setFill(); r.fill(); return true
        }
        guard let page = PDFPage(image: img) else { return }
        snapshot("Пустая страница")
        let at = doc.pageCount == 0 ? 0 : currentPageIndex + 1
        doc.insert(page, at: at)
        pageCount = doc.pageCount
        go(toPage: at)
        markDirty()
    }

    /// Сохранить страницы (диапазон) отдельным файлом — «разделить».
    func exportPages(spec: String, suggestedName: String) {
        guard let doc = document, let set = PDFModel.parseRanges(spec, max: doc.pageCount), !set.isEmpty else { status("Непонятный диапазон", true); return }
        let out = PDFDocument()
        var at = 0
        for i in set.sorted() {
            guard let p = doc.page(at: i), let c = p.copy() as? PDFPage else { continue }
            out.insert(c, at: at); at += 1
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if out.write(to: url) { status("Сохранено страниц: \(at) → \(url.lastPathComponent)", false) }
        else { status("Не записалось: \(url.lastPathComponent)", true) }
    }

    /// Страница → PNG (150 dpi).
    func exportCurrentPagePNG(suggestedName: String, dpi: CGFloat = 150) {
        guard let page = currentPage, let img = PDFPageBaker.render(page: page, dpi: dpi) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: url); status("PNG: \(url.lastPathComponent)", false) }
        catch { status("Не записалось: \(error.localizedDescription)", true) }
    }

    /// Текст документа или страницы (в текстовую вкладку / буфер).
    func text(pageOnly: Bool) -> String {
        if pageOnly { return currentPage?.string ?? "" }
        return document?.string ?? ""
    }

    func copyPageText() {
        let t = text(pageOnly: true)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        status(t.isEmpty ? "На странице нет текстового слоя (скан?)" : "Текст страницы скопирован", t.isEmpty)
    }

    func copySelection() {
        guard let s = pdfView.currentSelection?.string, !s.isEmpty else { copyPageText(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        status("Скопировано", false)
    }

    func selectAll() { pdfView.selectAll(nil) }

    /// Сводка для «Статистика документа».
    func summary() -> String {
        guard let doc = document else { return "Документ не загружен" }
        let attrs = doc.documentAttributes ?? [:]
        func a(_ k: PDFDocumentAttribute) -> String { (attrs[k] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
        let page = currentPage
        let box = page?.bounds(for: .mediaBox) ?? .zero
        let mm = { (v: CGFloat) in String(format: "%.0f", v / 72 * 25.4) }
        let annCount = (0..<doc.pageCount).compactMap { doc.page(at: $0) }.reduce(0) { $0 + $1.annotations.count }
        let bytes = data()?.count ?? 0
        return """
        Страниц: \(doc.pageCount)
        Размер страницы \(currentPageIndex + 1): \(mm(box.width)) × \(mm(box.height)) мм (\(Int(box.width)) × \(Int(box.height)) pt), поворот \(page?.rotation ?? 0)°
        Аннотаций и полей: \(annCount)
        Байт: \(bytes)
        Заголовок: \(a(.titleAttribute))
        Автор: \(a(.authorAttribute))
        Создатель: \(a(.creatorAttribute)) / \(a(.producerAttribute))
        Защита: \(doc.isLocked ? "заблокирован" : (doc.isEncrypted ? "зашифрован (открыт)" : "нет"))
        """
    }

    func printOperation(title: String) -> NSPrintOperation? {
        guard let doc = document else { return nil }
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)
        op?.jobTitle = title
        op?.showsPrintPanel = true
        return op
    }

    // MARK: Служебное

    /// «1-3, 7, 10-» → индексы (с нуля). Пусто/мусор → nil.
    static func parseRanges(_ spec: String, max: Int) -> Set<Int>? {
        var out = Set<Int>()
        let parts = spec.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
        guard !parts.isEmpty else { return nil }
        for raw in parts {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if let dash = p.firstIndex(where: { $0 == "-" || $0 == "–" }) {
                let a = Int(p[..<dash].trimmingCharacters(in: .whitespaces)) ?? 1
                let bs = p[p.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                let b = bs.isEmpty ? max : (Int(bs) ?? -1)
                guard a >= 1, b >= a else { return nil }
                for i in a...min(b, max) { out.insert(i - 1) }
            } else if let n = Int(p), n >= 1, n <= max {
                out.insert(n - 1)
            } else {
                return nil
            }
        }
        return out
    }

    static func confirm(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "Да")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func prompt(_ title: String, info: String, value: String, multiline: Bool = false, secure: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
        if multiline {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
            let tv = NSTextView(frame: scroll.bounds)
            tv.string = value
            tv.font = NSFont.systemFont(ofSize: 13)
            tv.isRichText = false
            tv.autoresizingMask = [.width]
            scroll.documentView = tv
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            alert.accessoryView = scroll
            alert.window.initialFirstResponder = tv
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return tv.string
        }
        let field: NSTextField = secure
            ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            : NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

extension PDFAnnotation {
    /// Поле формы (не трогаем при «удалить аннотации»).
    var isWidgetLike: Bool {
        if let t = type?.lowercased(), t.hasSuffix("widget") { return true }
        return fieldName != nil
    }
}

// MARK: - Рендер страниц и впечатывание картинок (Core Graphics)

enum PDFPageBaker {

    /// Размер повёрнутой страницы в пунктах.
    static func displaySize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .mediaBox)
        return page.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Страница → NSImage (с учётом поворота).
    static func render(page: PDFPage, dpi: CGFloat) -> NSImage? {
        let size = displaySize(page)
        let scale = dpi / 72
        let w = max(Int(size.width * scale), 1), h = max(Int(size.height * scale), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.transform(for: .mediaBox))
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    /// Новая страница: старое содержимое (вектор, текст остаётся текстом) + картинка.
    /// rect — в координатах страницы (как даёт PDFView.convert(_:to:)).
    static func bake(image: NSImage, rect: CGRect, page: PDFPage) -> PDFPage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = displaySize(page)
        var mediaBox = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.concatenate(page.transform(for: .mediaBox))
        page.draw(with: .mediaBox, to: ctx)
        ctx.draw(cg, in: rect)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), let newPage = doc.page(at: 0) else { return nil }
        return newPage
    }
}

// MARK: - PDFView с инструментами разметки

final class QPDFView: PDFView {
    weak var model: PDFModel?

    private let overlay = InkOverlay()
    private var dragStartView: CGPoint?
    private var dragPage: PDFPage?
    private var inkPointsView: [CGPoint] = []
    private var inkPointsPage: [CGPoint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupOverlay()
    }

    private func setupOverlay() {
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.isHidden = true
        addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    override var undoManager: UndoManager? { model?.undo }

    override var acceptsFirstResponder: Bool { true }

    func toolChanged() {
        window?.invalidateCursorRects(for: self)
        if model?.tool == .select { setCurrentSelection(currentSelection, animate: false) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let t = model?.tool, t.isDrawing { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Наш overlay должен быть поверх всего, что PDFView добавляет сам.
        if overlay.superview !== self { addSubview(overlay) }
        overlay.frame = bounds
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        if overlay.superview === self, subviews.last !== overlay {
            overlay.removeFromSuperview()
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }

    // MARK: Мышь

    override func mouseDown(with event: NSEvent) {
        guard let model, model.tool.isDrawing else { super.mouseDown(with: event); return }
        let pt = convert(event.locationInWindow, from: nil)
        guard let page = page(for: pt, nearest: true) else { return }
        dragStartView = pt
        dragPage = page
        inkPointsView = [pt]
        inkPointsPage = [convert(pt, to: page)]
        overlay.isHidden = false
        overlay.mode = model.tool == .ink ? .ink : .rect
        overlay.color = model.color.nsColor
        overlay.width = model.inkWidth
        overlay.points = inkPointsView
        overlay.rect = .zero
        overlay.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, model.tool.isDrawing, let start = dragStartView, let page = dragPage else { super.mouseDragged(with: event); return }
        let pt = convert(event.locationInWindow, from: nil)
        if model.tool == .ink {
            inkPointsView.append(pt)
            inkPointsPage.append(convert(pt, to: page))
            overlay.points = inkPointsView
        } else {
            overlay.rect = CGRect(x: min(start.x, pt.x), y: min(start.y, pt.y), width: abs(pt.x - start.x), height: abs(pt.y - start.y))
        }
        overlay.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let model, model.tool.isDrawing, let start = dragStartView, let page = dragPage else { super.mouseUp(with: event); return }
        let pt = convert(event.locationInWindow, from: nil)
        overlay.isHidden = true
        overlay.points = []
        dragStartView = nil
        dragPage = nil
        let a = convert(start, to: page), b = convert(pt, to: page)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch model.tool {
        case .ink:
            model.addInk(points: inkPointsPage, page: page)
        case .highlight, .underline, .strikeout:
            if rect.width < 3 && rect.height < 3 { model.markupSelection(model.tool) }
            else { model.markupRect(model.tool, rect: rect, page: page) }
        case .note:
            model.addNote(at: b, page: page)
        case .text:
            model.addFreeText(in: rect, page: page)
        case .rect:
            model.addRect(rect, page: page)
        case .image:
            if let img = model.pickImage() { model.bake(image: img, into: rect, page: page) }
        case .signature:
            if let img = model.signatureImage() { model.bake(image: img, into: rect, page: page) }
        case .select:
            break
        }
        inkPointsView = []
        inkPointsPage = []
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            model?.tool = .select
            return
        }
        if (event.keyCode == 51 || event.keyCode == 117), let model, model.hitAnnotation != nil,
           !(model.hitAnnotation?.isWidgetLike ?? false), window?.firstResponder === self {
            model.deleteHitAnnotation()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let model else { return menu }
        if menu.items.count > 0 { menu.addItem(.separator()) }
        let hasSel = !(currentSelection?.string ?? "").isEmpty
        if hasSel {
            for t in [PDFTool.highlight, .underline, .strikeout] {
                let item = NSMenuItem(title: t.title, action: #selector(markupFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = t.rawValue
                menu.addItem(item)
            }
        }
        if model.hitAnnotation != nil, !(model.hitAnnotation?.isWidgetLike ?? false) {
            menu.addItem(.separator())
            let edit = NSMenuItem(title: "Изменить текст аннотации…", action: #selector(editAnnotation(_:)), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
            let del = NSMenuItem(title: "Удалить аннотацию", action: #selector(deleteAnnotation(_:)), keyEquivalent: "")
            del.target = self
            menu.addItem(del)
        }
        return menu
    }

    @objc private func markupFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = PDFTool(rawValue: raw) else { return }
        model?.markupSelection(t)
    }

    @objc private func editAnnotation(_ sender: Any?) { model?.editHitAnnotationText() }
    @objc private func deleteAnnotation(_ sender: Any?) { model?.deleteHitAnnotation() }
}

/// Прозрачный слой поверх PDFView: живой штрих карандаша / рамка при растягивании.
final class InkOverlay: NSView {
    enum Mode { case ink, rect }
    var mode: Mode = .ink
    var points: [CGPoint] = []
    var rect: CGRect = .zero
    var color: NSColor = .systemYellow
    var width: CGFloat = 2.5

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .ink:
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: points[0])
            for p in points.dropFirst() { path.line(to: p) }
            color.setStroke()
            path.stroke()
        case .rect:
            guard rect.width > 0 || rect.height > 0 else { return }
            color.withAlphaComponent(0.9).setStroke()
            let p = NSBezierPath(rect: rect)
            p.lineWidth = 1.5
            p.setLineDash([5, 3], count: 2, phase: 0)
            p.stroke()
        }
    }
}

/// Миниатюры с перетаскиванием страниц: фиксируем снимок до и порядок после.
final class QThumbView: PDFThumbnailView {
    weak var model: PDFModel?

    override func mouseDown(with event: NSEvent) {
        model?.thumbDragBegan()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // PDFKit переставляет страницу в конце drag-сессии — проверяем чуть позже.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            self?.model?.thumbDragEnded()
        }
    }
}
