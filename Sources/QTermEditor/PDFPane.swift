import SwiftUI
import AppKit
import PDFKit

// MARK: - Панель PDF в окне редактора (SwiftUI поверх PDFModel)

/// Вкладка PDF: миниатюры слева (переключаются) + PDFView.
struct PDFPaneView: View {
    @ObservedObject var model: PDFModel

    var body: some View {
        HStack(spacing: 0) {
            if model.showThumbnails {
                PDFThumbRep(model: model)
                    .frame(width: 150)
                Divider()
            }
            PDFViewRep(model: model)
        }
        .overlay(alignment: .center) {
            if model.isLocked { lockedOverlay }
        }
    }

    private var lockedOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.doc").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("PDF защищён паролем").font(.headline)
            Button("Ввести пароль…") {
                if let p = PDFModel.prompt("Пароль PDF", info: "", value: "", secure: true) { _ = model.unlock(password: p) }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PDFViewRep: NSViewRepresentable {
    let model: PDFModel
    func makeNSView(context: Context) -> QPDFView { model.pdfView }
    func updateNSView(_ nsView: QPDFView, context: Context) {}
}

/// PDFThumbnailView прокручивается сам — в NSScrollView не заворачиваем.
private struct PDFThumbRep: NSViewRepresentable {
    let model: PDFModel
    func makeNSView(context: Context) -> QThumbView { model.thumbView }
    func updateNSView(_ nsView: QThumbView, context: Context) {}
}

/// Панель инструментов PDF (вторая строка под общей панелью).
struct PDFToolbar: View {
    @ObservedObject var model: PDFModel
    @ObservedObject var editor: EditorAppState
    @State private var pageField = ""

    var body: some View {
        HStack(spacing: 2) {
            tool("chevron.left", "Предыдущая страница (Page Up)") { model.previousPage() }
            TextField("", text: $pageField)
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .font(.caption.monospacedDigit())
                .onSubmit { if let n = Int(pageField.trimmingCharacters(in: .whitespaces)) { model.go(toPage: n - 1) } }
                .onAppear { pageField = "\(model.currentPageIndex + 1)" }
                .onChange(of: model.currentPageIndex) { _, v in pageField = "\(v + 1)" }
            Text("/ \(model.pageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            tool("chevron.right", "Следующая страница (Page Down)") { model.nextPage() }
            sep
            tool("minus.magnifyingglass", "Мельче (⌘-)") { model.zoomOut() }
            Text("\(Int((model.scale * 100).rounded()))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40)
            tool("plus.magnifyingglass", "Крупнее (⌘=)") { model.zoomIn() }
            tool("arrow.left.and.right", "По ширине") { model.fitWidth() }
            tool("rectangle.portrait", "Страница целиком") { model.fitPage() }
            sep
            toggle("sidebar.left", "Миниатюры страниц", $model.showThumbnails)
            sep
            ForEach(PDFTool.allCases) { t in
                Button {
                    if t.isMarkup, model.tool != t, !(model.pdfView.currentSelection?.string ?? "").isEmpty {
                        // есть выделение — применяем сразу, без смены инструмента
                        model.markupSelection(t)
                    } else {
                        model.tool = (model.tool == t && t != .select) ? .select : t
                    }
                } label: {
                    Image(systemName: t.symbol).frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .background(model.tool == t ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .help(t.help)
            }
            Menu {
                ForEach(PDFInkColor.allCases) { c in
                    Button {
                        model.color = c
                    } label: {
                        if model.color == c { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                    }
                }
                Divider()
                Picker("Толщина", selection: $model.inkWidth) {
                    Text("Тонкая").tag(CGFloat(1.2))
                    Text("Средняя").tag(CGFloat(2.5))
                    Text("Толстая").tag(CGFloat(5))
                }
                .pickerStyle(.inline)
                Divider()
                Button("Выбрать картинку подписи…") { model.pickSignature() }
            } label: {
                Circle().fill(Color(nsColor: model.color.nsColor)).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Цвет и толщина разметки")
            sep
            tool("rotate.left", "Повернуть страницу влево") { model.rotateCurrent(by: -90) }
            tool("rotate.right", "Повернуть страницу вправо") { model.rotateCurrent(by: 90) }
            tool("trash", "Удалить страницу") { model.deleteCurrentPage() }
            tool("doc.badge.plus", "Вставить PDF после текущей страницы…") { model.insertPDF(append: false) }
            tool("photo.badge.plus", "Страница из картинки…") { model.insertImagePage() }
            sep
            tool("text.quote", "Текст документа → новая вкладка") { editor.extractPDFText(pageOnly: false) }
            tool("photo", "Страница → PNG…") { editor.exportPDFPagePNG() }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private var sep: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
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

/// Меню «PDF» (строка меню и меню в окне).
struct EdPDFItems: View {
    @ObservedObject var editor: EditorAppState
    private var model: PDFModel? { editor.activeDocument?.pdf }
    private var off: Bool { model == nil }

    var body: some View {
        Menu("Инструмент") {
            ForEach(PDFTool.allCases) { t in
                Button {
                    model?.tool = t
                } label: {
                    if model?.tool == t { Label(t.title, systemImage: "checkmark") } else { Text(t.title) }
                }
            }
        }
        .disabled(off)
        Button("Маркер по выделению") { model?.markupSelection(.highlight) }.disabled(off)
        Button("Подчеркнуть выделение") { model?.markupSelection(.underline) }.disabled(off)
        Button("Зачеркнуть выделение") { model?.markupSelection(.strikeout) }.disabled(off)
        Button("Изменить текст аннотации…") { model?.editHitAnnotationText() }.disabled(off)
        Button("Удалить аннотацию") { model?.deleteHitAnnotation() }.disabled(off)
        Menu("Удалить все аннотации") {
            Button("На этой странице") { model?.deleteAllAnnotations(onPageOnly: true) }
            Button("Во всём документе") { model?.deleteAllAnnotations(onPageOnly: false) }
        }
        .disabled(off)
        Button("Выбрать картинку подписи…") { model?.pickSignature() }.disabled(off)
        Divider()
        Button("Повернуть страницу влево") { model?.rotateCurrent(by: -90) }.disabled(off)
        Button("Повернуть страницу вправо") { model?.rotateCurrent(by: 90) }.disabled(off)
        Button("Повернуть все страницы вправо") { model?.rotateAll(by: 90) }.disabled(off)
        Button("Страницу выше") { model?.moveCurrentPage(by: -1) }.disabled(off)
        Button("Страницу ниже") { model?.moveCurrentPage(by: 1) }.disabled(off)
        Button("Удалить страницу") { model?.deleteCurrentPage() }.disabled(off)
        Button("Удалить страницы…") { editor.pdfDeletePages() }.disabled(off)
        Divider()
        Button("Вставить PDF после текущей…") { model?.insertPDF(append: false) }.disabled(off)
        Button("Добавить PDF в конец…") { model?.insertPDF(append: true) }.disabled(off)
        Button("Пустая страница после текущей") { model?.insertBlankPage() }.disabled(off)
        Button("Страница из картинки…") { model?.insertImagePage() }.disabled(off)
        Button("Сохранить страницы отдельным файлом…") { editor.pdfExportPages() }.disabled(off)
        Divider()
        Button("Текст документа → новая вкладка") { editor.extractPDFText(pageOnly: false) }.disabled(off)
        Button("Текст страницы → новая вкладка") { editor.extractPDFText(pageOnly: true) }.disabled(off)
        Button("Копировать текст страницы") { model?.copyPageText() }.disabled(off)
        Button("Страница → PNG…") { editor.exportPDFPagePNG() }.disabled(off)
        Divider()
        Button("Снять пароль…") { editor.pdfUnlock() }.disabled(off)
        Button("О документе") { editor.showStats() }.disabled(off)
    }
}

/// Статус-бар PDF-вкладки: где файл, страница, масштаб, инструмент, статус, сохранение.
struct PDFStatusBar: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var pdf: PDFModel
    @ObservedObject var editor: EditorAppState

    var body: some View {
        HStack(spacing: 10) {
            Text(doc.locationText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Стр \(pdf.currentPageIndex + 1) / \(pdf.pageCount)")
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
            Text("\(Int((pdf.scale * 100).rounded()))%")
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
            if pdf.tool != .select {
                Label(pdf.tool.title, systemImage: pdf.tool.symbol)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("Esc — вернуться к выделению")
            }
            Spacer()
            if let status = doc.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(doc.statusIsError ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("PDF")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Вкладка PDF: просмотр, разметка, страницы (PDFKit)")
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
