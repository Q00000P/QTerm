import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Точка входа «Нод 3x-ui»: хранилище (ставит AppState), запрос «нода из выделения».
@MainActor
final class XuiCenter: ObservableObject {
    static let shared = XuiCenter()
    var store: XuiStore?

    /// Текст выделения для «Нода из выделения» — окно «Ноды 3x-ui» откроет по нему лист.
    @Published var nodeAddRequest: NodeAddRequest?

    func requestNodeAdd(_ text: String) { nodeAddRequest = NodeAddRequest(text: text) }

    /// Выделение терминала уже в буфере (выделил = скопировал); берём его.
    static func clipboardText() -> String { NSPasteboard.general.string(forType: .string) ?? "" }

    /// Куда писать про автоперевыпуск токена (лог окна «Ноды 3x-ui»).
    var notice: ((String, LogKind) -> Void)?
    private var reissued: [String: (at: Date, ok: Bool)] = [:]

    /// Панель не приняла токен (401): выпустить новый по сохранённым логину/паролю и сохранить.
    func reissueToken(_ id: String) async -> String? {
        guard let store, var p = store.panels().first(where: { $0.id == id }), p.isXui,
              !p.login.isEmpty, let pass = p.pass, !pass.isEmpty else { return nil }
        // только что перевыпущен — старые копии панели в окне ещё со старым токеном; пароль не подошёл — не долбить вход
        if let r = reissued[id], Date().timeIntervalSince(r.at) < 60 { return r.ok ? p.token : nil }
        reissued[id] = (Date(), false)
        notice?("  ↻ «\(p.name)»: панель не приняла токен — выпускаю новый по сохранённому паролю", .warn)
        do {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyMMdd-HHmmss"
            let r = try await XuiLogin.issueToken(url: p.url, login: p.login, password: pass, twoFactor: nil,
                                                  verifyTls: p.verifyTls, tokenName: "qterm-" + f.string(from: Date()))
            guard let t = r.token, !t.isEmpty else {
                notice?("  ✗ «\(p.name)»: \(r.needTwoFactor ? "включена 2FA — выпусти токен вручную в «Панели и токены…»" : r.message)", .err)
                return nil
            }
            p.token = t
            store.save(p)
            reissued[id] = (Date(), true)
            notice?("  ✓ «\(p.name)»: новый токен выпущен и сохранён", .ok)
            return t
        } catch {
            notice?("  ✗ «\(p.name)»: \(error.localizedDescription)", .err)
            return nil
        }
    }

    /// Пароли из итога установки не должны висеть в буфере.
    static func scrubClipboard(_ passwords: [String]) {
        let clip = clipboardText()
        if passwords.contains(where: { !$0.isEmpty && clip.contains($0) }) { NSPasteboard.general.clearContents() }
    }
}

struct NodeAddRequest: Identifiable {
    let id = UUID()
    let text: String
}

/// Модальные мелочи: подтверждение, выбор, ввод строки (NSAlert — блокирует только своё окно на время ответа).
@MainActor
enum XuiDialog {
    static func info(_ text: String, title: String = "Ноды 3x-ui") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Индекс нажатой кнопки (−1 — Esc).
    static func choose(_ text: String, title: String, _ buttons: [String]) -> Int {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        let r = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return r >= 0 && r < buttons.count ? r : -1
    }

    static func confirm(_ text: String, title: String, yes: String = "Да") -> Bool {
        choose(text, title: title, [yes, "Отмена"]) == 0
    }

    static func ask(_ prompt: String, title: String = "Ноды 3x-ui", value: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = prompt
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.stringValue = value
        a.accessoryView = f
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Отмена")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let s = f.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - QR

enum XuiQR {
    /// QR-картинка; nil — не влезает (длинный конфиг AWG).
    static func image(_ text: String, level: String = "M") -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = level
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

struct XuiQRInfo: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    var clash: String?
    var isConfig = false
}

struct XuiQRSheet: View {
    let info: XuiQRInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(info.title).font(.headline)
            if let img = XuiQR.image(info.text, level: info.isConfig ? "L" : "M") {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 360, height: 360)
            } else {
                Text("Слишком длинно для QR (\(info.text.count) символов) — используй «Конфиг → буфер» или «Сохранить .conf».")
                    .frame(width: 360, alignment: .leading)
            }
            ScrollView {
                Text(info.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 360, height: info.isConfig ? 140 : 50)
            if let c = info.clash {
                Text("Clash / Mihomo (Кинетик):").foregroundStyle(.secondary)
                Text(c).font(.caption).textSelection(.enabled).frame(width: 360, alignment: .leading)
            }
            HStack {
                Button("Копировать") { XuiDialog.copy(info.text) }
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
