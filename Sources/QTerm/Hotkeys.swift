import SwiftUI
import AppKit

// Настраиваемые горячие клавиши (канон Windows Hotkeys.cs): список функций,
// умолчания, в настройках хранятся ТОЛЬКО отличия от умолчаний — новые
// умолчания будущих волн доедут сами. Клавиша хранится ФИЗИЧЕСКОЙ (как
// KeyboardEvent.code на винде: «KeyG», «Digit1», «F5») — не зависит от
// раскладки RU/EN. Сочетание строкой: «Cmd+Shift+KeyG».

struct HotkeyAction: Identifiable {
    let id: String
    let title: String
    let defaultGesture: String
}

struct Gesture: Equatable, Hashable {
    var cmd = false
    var ctrl = false
    var opt = false
    var shift = false
    var code: String

    static func parse(_ s: String?) -> Gesture? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty, Hotkeys.keyEquivalent(last) != nil else { return nil }
        var g = Gesture(code: last)
        for p in parts.dropLast() {
            switch p.lowercased() {
            case "cmd": g.cmd = true
            case "ctrl": g.ctrl = true
            case "opt", "alt": g.opt = true
            case "shift": g.shift = true
            default: return nil
            }
        }
        return g
    }

    /// Для хранения: «Cmd+Shift+KeyG».
    var canon: String {
        (ctrl ? "Ctrl+" : "") + (opt ? "Opt+" : "") + (shift ? "Shift+" : "") + (cmd ? "Cmd+" : "") + code
    }

    /// Для людей, по-маковски: «⇧⌘G».
    var display: String {
        (ctrl ? "⌃" : "") + (opt ? "⌥" : "") + (shift ? "⇧" : "") + (cmd ? "⌘" : "") + Hotkeys.label(code)
    }

    var shortcut: KeyboardShortcut? {
        guard let key = Hotkeys.keyEquivalent(code) else { return nil }
        var m: EventModifiers = []
        if cmd { m.insert(.command) }
        if ctrl { m.insert(.control) }
        if opt { m.insert(.option) }
        if shift { m.insert(.shift) }
        return KeyboardShortcut(key, modifiers: m)
    }
}

final class Hotkeys: ObservableObject {
    static let shared = Hotkeys()
    static let storeKey = "hotkeys"

    static let actions: [HotkeyAction] = {
        var list: [HotkeyAction] = [
            HotkeyAction(id: "git", title: "Команды Git", defaultGesture: "Shift+Cmd+KeyG"),
            HotkeyAction(id: "snippets", title: "Сниппеты (команды)…", defaultGesture: ""),
            HotkeyAction(id: "journal", title: "Журнал команд", defaultGesture: ""),
            HotkeyAction(id: "clear", title: "Очистить экран", defaultGesture: ""),
            HotkeyAction(id: "clearAll", title: "Очистить экран и скроллбек", defaultGesture: ""),
            HotkeyAction(id: "broadcast", title: "«Во все ноды» вкл/выкл", defaultGesture: ""),
            HotkeyAction(id: "reconnect", title: "Переподключить ноду", defaultGesture: ""),
            HotkeyAction(id: "files", title: "Файлы: показать/скрыть", defaultGesture: ""),
            HotkeyAction(id: "dup", title: "Дублировать вкладку", defaultGesture: "Cmd+KeyT"),
            HotkeyAction(id: "close", title: "Закрыть вкладку", defaultGesture: "Cmd+KeyW"),
            HotkeyAction(id: "next", title: "Следующая вкладка", defaultGesture: "Shift+Cmd+BracketRight"),
            HotkeyAction(id: "prev", title: "Предыдущая вкладка", defaultGesture: "Shift+Cmd+BracketLeft"),
        ]
        for i in 1...9 {
            list.append(HotkeyAction(id: "tab\(i)", title: "Вкладка \(i)", defaultGesture: "Cmd+Digit\(i)"))
        }
        list += [
            HotkeyAction(id: "local", title: "Локальный терминал Mac", defaultGesture: "Cmd+KeyL"),
            HotkeyAction(id: "newnode", title: "Новая нода", defaultGesture: ""),
            HotkeyAction(id: "sync", title: "Синхронизировать сейчас", defaultGesture: ""),
            HotkeyAction(id: "qeditor", title: "Редактор (QTerm Editor)", defaultGesture: "Shift+Cmd+KeyE"),
            HotkeyAction(id: "hotkeys", title: "Горячие клавиши…", defaultGesture: ""),
        ]
        return list
    }()

    @Published private(set) var map: [String: Gesture?] = [:]

    private init() { load() }

    func shortcut(_ id: String) -> KeyboardShortcut? {
        (map[id] ?? nil)?.shortcut
    }

    func gesture(_ id: String) -> Gesture? { map[id] ?? nil }

    func load() {
        let ov = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
        var m: [String: Gesture?] = [:]
        for a in Self.actions {
            m[a.id] = Gesture.parse(ov[a.id] ?? a.defaultGesture)
        }
        map = m
    }

    /// Назначить (nil — снять). Сочетание, занятое другой функцией, у неё снимается.
    /// Возвращает название функции, у которой отобрали сочетание.
    @discardableResult
    func set(_ id: String, _ g: Gesture?) -> String? {
        var stolen: String?
        if let g {
            for (other, og) in map where other != id && og == g {
                map[other] = .some(nil)
                stolen = Self.title(other)
            }
        }
        map[id] = .some(g)
        save()
        return stolen
    }

    func resetAll() {
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
        load()
    }

    private func save() {
        var ov: [String: String] = [:]
        for a in Self.actions {
            let cur = (map[a.id] ?? nil)?.canon ?? ""
            let def = Gesture.parse(a.defaultGesture)?.canon ?? ""
            if cur != def { ov[a.id] = cur }
        }
        if ov.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.storeKey)
        } else {
            UserDefaults.standard.set(ov, forKey: Self.storeKey)
        }
    }

    static func title(_ id: String) -> String {
        actions.first { $0.id == id }?.title ?? id
    }

    // MARK: - Физические клавиши (ANSI keyCode → код)

    static let codeByKeyCode: [UInt16: String] = {
        var m: [UInt16: String] = [
            0: "KeyA", 11: "KeyB", 8: "KeyC", 2: "KeyD", 14: "KeyE", 3: "KeyF", 5: "KeyG",
            4: "KeyH", 34: "KeyI", 38: "KeyJ", 40: "KeyK", 37: "KeyL", 46: "KeyM", 45: "KeyN",
            31: "KeyO", 35: "KeyP", 12: "KeyQ", 15: "KeyR", 1: "KeyS", 17: "KeyT", 32: "KeyU",
            9: "KeyV", 13: "KeyW", 7: "KeyX", 16: "KeyY", 6: "KeyZ",
            29: "Digit0", 18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4",
            23: "Digit5", 22: "Digit6", 26: "Digit7", 28: "Digit8", 25: "Digit9",
            27: "Minus", 24: "Equal", 33: "BracketLeft", 30: "BracketRight", 41: "Semicolon",
            39: "Quote", 43: "Comma", 47: "Period", 44: "Slash", 42: "Backslash", 50: "Backquote",
            36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 117: "Delete",
            123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
            115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        ]
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, kc) in fkeys.enumerated() { m[kc] = "F\(i + 1)" }
        return m
    }()

    private static let chars: [String: Character] = [
        "Minus": "-", "Equal": "=", "BracketLeft": "[", "BracketRight": "]", "Semicolon": ";",
        "Quote": "'", "Comma": ",", "Period": ".", "Slash": "/", "Backslash": "\\", "Backquote": "`",
    ]

    static func keyEquivalent(_ code: String) -> KeyEquivalent? {
        if code.hasPrefix("Key"), code.count == 4, let c = code.last {
            return KeyEquivalent(Character(c.lowercased()))
        }
        if code.hasPrefix("Digit"), code.count == 6, let c = code.last { return KeyEquivalent(c) }
        if let c = chars[code] { return KeyEquivalent(c) }
        if code.hasPrefix("F"), let n = Int(code.dropFirst()), (1...12).contains(n),
           let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
            return KeyEquivalent(Character(scalar))
        }
        switch code {
        case "Enter": return .return
        case "Tab": return .tab
        case "Space": return .space
        case "Backspace": return .delete
        case "Delete": return .deleteForward
        case "ArrowLeft": return .leftArrow
        case "ArrowRight": return .rightArrow
        case "ArrowUp": return .upArrow
        case "ArrowDown": return .downArrow
        case "Home": return .home
        case "End": return .end
        case "PageUp": return .pageUp
        case "PageDown": return .pageDown
        default: return nil
        }
    }

    static func label(_ code: String) -> String {
        if code.hasPrefix("Key"), code.count == 4 { return String(code.last!) }
        if code.hasPrefix("Digit"), code.count == 6 { return String(code.last!) }
        if let c = chars[code] { return String(c) }
        switch code {
        case "Enter": return "↩"
        case "Tab": return "⇥"
        case "Space": return "Пробел"
        case "Backspace": return "⌫"
        case "Delete": return "⌦"
        case "ArrowLeft": return "←"
        case "ArrowRight": return "→"
        case "ArrowUp": return "↑"
        case "ArrowDown": return "↓"
        case "Home": return "↖"
        case "End": return "↘"
        case "PageUp": return "⇞"
        case "PageDown": return "⇟"
        default: return code
        }
    }

    /// Сочетание из нажатия. Без ⌘/⌃/⌥ принимаются только F-клавиши —
    /// иначе печать в терминал ловилась бы меню.
    static func gesture(from event: NSEvent) -> Gesture? {
        guard let code = codeByKeyCode[event.keyCode] else { return nil }
        let f = event.modifierFlags
        let g = Gesture(cmd: f.contains(.command), ctrl: f.contains(.control),
                        opt: f.contains(.option), shift: f.contains(.shift), code: code)
        let isF = code.hasPrefix("F") && code.count <= 3
        guard g.cmd || g.ctrl || g.opt || isF else { return nil }
        return g
    }
}

// MARK: - Настройки: список функций с записью сочетания

struct HotkeysSettingsView: View {
    @ObservedObject private var hotkeys = Hotkeys.shared
    @State private var recording: String?
    @State private var monitor: Any?
    @State private var note: String?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Поиск функции", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button("Сбросить все") {
                    stopRecording()
                    hotkeys.resetAll()
                    note = "Восстановлены умолчания"
                }
            }
            List {
                ForEach(Hotkeys.actions.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }) { a in
                    HStack {
                        Text(a.title)
                        Spacer()
                        Button {
                            recording == a.id ? stopRecording() : startRecording(a.id)
                        } label: {
                            Text(recording == a.id ? "Нажмите сочетание…" : (hotkeys.gesture(a.id)?.display ?? "—"))
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 130)
                        }
                        .buttonStyle(.bordered)
                        .tint(recording == a.id ? Color.accentColor : nil)
                        Button {
                            stopRecording()
                            hotkeys.set(a.id, nil)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Снять сочетание")
                        .disabled(hotkeys.gesture(a.id) == nil)
                    }
                }
            }
            .frame(minHeight: 340)
            Text(note ?? "Клик по сочетанию → нажмите новое (нужен ⌘, ⌃ или ⌥; F1–F12 можно без них). Esc — отмена, ⌫ — снять. Занятое сочетание снимается с прежней функции.")
                .font(.caption)
                .foregroundStyle(note == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .onDisappear(perform: stopRecording)
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recording = id
        note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let rec = recording else { return event }
            let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            if event.keyCode == 53, plain { stopRecording(); return nil }          // Esc
            if event.keyCode == 51, plain {                                        // ⌫
                hotkeys.set(rec, nil)
                stopRecording()
                return nil
            }
            guard let g = Hotkeys.gesture(from: event) else {
                note = "Нужен ⌘, ⌃ или ⌥ (или F1–F12)"
                return nil
            }
            if let stolen = hotkeys.set(rec, g) {
                note = "\(g.display) снято с «\(stolen)»"
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
