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

    struct Issued {
        var token: String?
        var message: String
        var needTwoFactor = false
    }

    /// Войти в панель логином/паролем, выпустить admin-токен, сохранить его вместе с логином и паролем.
    func issueAndSave(_ id: String, login: String, pass: String, twoFa: String? = nil) async -> Issued {
        guard let store, var p = store.panels().first(where: { $0.id == id }) else { return Issued(token: nil, message: "панель не найдена") }
        do {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyMMdd-HHmmss"
            let r = try await XuiLogin.issueToken(url: p.url, login: login, password: pass, twoFactor: twoFa,
                                                  verifyTls: p.verifyTls, tokenName: "qterm-" + f.string(from: Date()))
            guard let t = r.token, !t.isEmpty else {
                return Issued(token: nil, message: r.needTwoFactor ? "включена 2FA — нужен код" : r.message, needTwoFactor: r.needTwoFactor)
            }
            p.login = login
            p.pass = pass
            p.token = t
            store.save(p)
            reissued[id] = (Date(), true)
            return Issued(token: t, message: "новый токен выпущен и сохранён")
        } catch {
            return Issued(token: nil, message: error.localizedDescription)
        }
    }

    /// Панель не приняла токен (401): выпустить новый по сохранённым логину/паролю и сохранить.
    func reissueToken(_ id: String) async -> String? {
        guard let store, let p = store.panels().first(where: { $0.id == id }), p.isXui,
              !p.login.isEmpty, let pass = p.pass, !pass.isEmpty else { return nil }
        // только что перевыпущен — старые копии панели в окне ещё со старым токеном; пароль не подошёл — не долбить вход
        if let r = reissued[id], Date().timeIntervalSince(r.at) < 60 { return r.ok ? p.token : nil }
        reissued[id] = (Date(), false)
        notice?("  ↻ «\(p.name)»: панель не приняла токен — выпускаю новый по сохранённому паролю", .warn)
        let r = await issueAndSave(id, login: p.login, pass: pass)
        notice?("  \(r.token == nil ? "✗" : "✓") «\(p.name)»: \(r.message)", r.token == nil ? .err : .ok)
        return r.token
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

    /// Логин / пароль / код 2FA. nil — отмена.
    static func credentials(_ text: String, title: String, login: String) -> (login: String, pass: String, twoFa: String)? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let l = NSTextField(frame: NSRect(x: 0, y: 64, width: 320, height: 24))
        l.placeholderString = "Логин админа"
        l.stringValue = login
        let pw = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 24))
        pw.placeholderString = "Пароль админа"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.placeholderString = "Код 2FA, если включена"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 88))
        box.addSubview(l); box.addSubview(pw); box.addSubview(tf)
        a.accessoryView = box
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Пропустить")
        a.window.initialFirstResponder = login.isEmpty ? l : pw
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let lg = l.stringValue.trimmingCharacters(in: .whitespaces)
        guard !lg.isEmpty, !pw.stringValue.isEmpty else { return nil }
        return (lg, pw.stringValue, tf.stringValue.trimmingCharacters(in: .whitespaces))
    }

    struct Field {
        var label: String
        var value = ""
        var secure = false
    }

    /// Форма из нескольких полей (подпись над каждым). nil — отмена.
    static func form(_ text: String, title: String, _ fields: [Field], ok: String = "OK") -> [String]? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        var inputs: [NSTextField] = []
        for f in fields {
            let cap = NSTextField(labelWithString: f.label)
            cap.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            cap.textColor = .secondaryLabelColor
            let t: NSTextField = f.secure ? NSSecureTextField() : NSTextField()
            t.stringValue = f.value
            t.translatesAutoresizingMaskIntoConstraints = false
            t.widthAnchor.constraint(equalToConstant: 320).isActive = true
            stack.addArrangedSubview(cap)
            stack.addArrangedSubview(t)
            inputs.append(t)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(fields.count) * 46)
        a.accessoryView = stack
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Отмена")
        a.window.initialFirstResponder = inputs.first
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map(\.stringValue)
    }

    /// Случайный пароль без похожих символов (0/O, 1/l/I).
    static func randomPassword(_ n: Int = 20) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var g = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count, using: &g)] })
    }

    /// Показать секрет (новый токен) — выделяемым текстом и с кнопкой «Копировать».
    static func secret(_ text: String, title: String, value: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 44))
        f.stringValue = value
        f.isEditable = false
        f.isSelectable = true
        f.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        a.accessoryView = f
        a.addButton(withTitle: "Копировать и закрыть")
        a.addButton(withTitle: "Закрыть")
        if a.runModal() == .alertFirstButtonReturn { copy(value) }
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
