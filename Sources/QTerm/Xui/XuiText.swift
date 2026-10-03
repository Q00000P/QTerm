import SwiftUI
import AppKit

// Всё текстовое — выделяется и копируется: лог (NSTextView), строки таблиц (⌘C / «Копировать»), тексты NSAlert.

/// Лог окна: NSTextView только для чтения — выделение мышью через строки, ⌘A, ⌘C, поиск ⌘F, контекстное меню.
struct XuiLogView: NSViewRepresentable {
    let lines: [LogLine]
    var onClear: (() -> Void)?

    final class Coordinator {
        var lastId: UUID?
    }

    final class LogTextView: NSTextView {
        var clear: (() -> Void)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let m = super.menu(for: event) ?? NSMenu()
            let copyAll = NSMenuItem(title: "Копировать весь лог", action: #selector(copyAll(_:)), keyEquivalent: "")
            copyAll.target = self
            let clr = NSMenuItem(title: "Очистить лог", action: #selector(clearLog(_:)), keyEquivalent: "")
            clr.target = self
            m.insertItem(.separator(), at: 0)
            m.insertItem(clr, at: 0)
            m.insertItem(copyAll, at: 0)
            return m
        }

        @objc private func copyAll(_ sender: Any?) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }

        @objc private func clearLog(_ sender: Any?) { clear?() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.drawsBackground = false

        let tv = LogTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: sv.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.clear = onClear
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? LogTextView, let storage = tv.textStorage else { return }
        tv.clear = onClear
        let c = context.coordinator

        // что добавилось после последней показанной строки; не нашли (очистка / обрезка) — заново
        var start = 0
        var rebuild = true
        if let last = c.lastId, let i = lines.lastIndex(where: { $0.id == last }) {
            start = i + 1
            rebuild = false
        }
        if rebuild { storage.setAttributedString(NSAttributedString()) }
        guard start < lines.count else { c.lastId = lines.last?.id; return }

        let clip = sv.contentView.bounds
        let atBottom = rebuild || clip.maxY >= tv.frame.height - 24

        let out = NSMutableAttributedString()
        for l in lines[start...] {
            if storage.length + out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: Self.attrs(.info))) }
            out.append(NSAttributedString(string: l.text, attributes: Self.attrs(l.kind)))
        }
        storage.append(out)
        // не раздувать: лишнее сверху срезаем вместе с моделью (она держит 2000 строк)
        if storage.length > 400_000 {
            let s = storage.string as NSString
            let cut = s.range(of: "\n", range: NSRange(location: storage.length - 300_000, length: 300_000))
            if cut.location != NSNotFound { storage.deleteCharacters(in: NSRange(location: 0, length: cut.location + 1)) }
        }
        c.lastId = lines.last?.id
        if atBottom { tv.scrollToEndOfDocument(nil) }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

    static func attrs(_ k: LogKind) -> [NSAttributedString.Key: Any] {
        let color: NSColor
        switch k {
        case .ok: color = .systemGreen
        case .warn: color = .systemOrange
        case .err: color = .systemRed
        case .head: color = .controlAccentColor
        case .dim: color = .secondaryLabelColor
        case .info: color = .labelColor
        }
        return [.font: font, .foregroundColor: color]
    }
}

/// ⌘C по выделенным строкам таблицы: текст строк через табуляцию.
extension View {
    func copyRows(_ text: @escaping () -> String) -> some View {
        onCopyCommand {
            let s = text()
            return s.isEmpty ? [] : [NSItemProvider(object: s as NSString)]
        }
    }
}

enum XuiCopy {
    static func row(_ cells: [String]) -> String {
        cells.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\t")
    }

    static func put(_ lines: [String]) {
        let s = lines.joined(separator: "\n")
        guard !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Тексты всех NSAlert приложения — выделяемые (по умолчанию их не скопировать).
@MainActor
enum SelectableAlerts {
    private static var token: NSObjectProtocol?

    static func install() {
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { n in
            guard let w = n.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard w is NSPanel, String(describing: type(of: w)).contains("Alert") else { return }
                if let v = w.contentView { makeSelectable(v) }
            }
        }
    }

    private static func makeSelectable(_ v: NSView) {
        if let f = v as? NSTextField, !f.isEditable, !f.isSelectable { f.isSelectable = true }
        for s in v.subviews { makeSelectable(s) }
    }
}
