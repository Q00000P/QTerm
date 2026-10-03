import AppKit
import SwiftTerm

/// Мышь как в MobaXterm (канон Windows): выделил — уже в буфере обмена,
/// правая кнопка — вставка. Оба поведения выключаются в настройках.
enum MobaMouse {
    static let copyKey = "copyOnSelect"
    static let pasteKey = "rightClickPaste"

    static var copyOnSelect: Bool {
        UserDefaults.standard.object(forKey: copyKey) as? Bool ?? true
    }
    static var rightClickPaste: Bool {
        UserDefaults.standard.object(forKey: pasteKey) as? Bool ?? true
    }

    /// После отпускания кнопки: есть выделение — кладём его в буфер.
    @MainActor
    static func copySelection(_ tv: TerminalView) {
        guard copyOnSelect, let sel = tv.selection, sel.active else { return }
        let text = sel.getSelectedText()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Экран SSH-вкладки: TerminalView + мышь мобы.
final class QTermTerminalView: TerminalView {
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        MobaMouse.copySelection(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        if MobaMouse.rightClickPaste {
            paste(self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}
