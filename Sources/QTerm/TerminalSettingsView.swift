import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Окно настроек (⌘,): Терминал / Вид / Горячие клавиши.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "terminal"

    var body: some View {
        TabView(selection: $tab) {
            TerminalSettingsView()
                .tabItem { Label("Терминал", systemImage: "terminal") }
                .tag("terminal")
            AppearanceSettingsView()
                .tabItem { Label("Вид", systemImage: "paintbrush") }
                .tag("appearance")
            HotkeysSettingsView()
                .tabItem { Label("Горячие клавиши", systemImage: "keyboard") }
                .tag("hotkeys")
        }
        .frame(width: 560)
    }
}

/// Терминал: строк истории (50…1 000 000, для новых вкладок) и панель мониторинга.
struct TerminalSettingsView: View {
    @AppStorage(QTermTerminal.scrollbackKey) private var scrollback = QTermTerminal.scrollbackDefault
    @AppStorage(NodeMonitor.enabledKey) private var monitorEnabled = true
    @AppStorage(MobaMouse.copyKey) private var copyOnSelect = true
    @AppStorage(MobaMouse.pasteKey) private var rightClickPaste = true
    @AppStorage(FSKeys.externalEditor) private var externalEditor = ""
    @State private var draft = ""
    @State private var note: String?

    var body: some View {
        Form {
            Section("Терминал") {
                HStack {
                    Text("Строк истории")
                    Spacer()
                    TextField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(apply)
                    Button("Применить", action: apply)
                }
                Text("От \(QTermTerminal.scrollbackRange.lowerBound) до \(QTermTerminal.scrollbackRange.upperBound.formatted()). Действует для новых вкладок; у MobaXterm по умолчанию 2 000, здесь — \(QTermTerminal.scrollbackDefault.formatted()).")
                    .font(.caption).foregroundStyle(.secondary)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Мышь (как в MobaXterm)") {
                Toggle("Выделение сразу копируется в буфер", isOn: $copyOnSelect)
                Toggle("Правая кнопка — вставка", isOn: $rightClickPaste)
                Text("⌘C/⌘V работают всегда.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Файлы") {
                HStack {
                    Text("Внешний редактор")
                    Spacer()
                    Text(externalEditor.isEmpty ? "программа по умолчанию"
                         : FileManager.default.displayName(atPath: externalEditor))
                        .foregroundStyle(.secondary)
                    Button("Выбрать…", action: pickEditor)
                    if !externalEditor.isEmpty {
                        Button("Сбросить") { externalEditor = "" }
                    }
                }
                Text("Меню файла «Открыть во внешнем редакторе»: копия открывается в этой программе, каждое сохранение заливается на сервер.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Мониторинг ноды") {
                Toggle("Панель под терминалом: CPU, RAM, сеть, аптайм, пользователи, диски", isOn: $monitorEnabled)
                Text("Раз в 3 с один запрос по уже открытому соединению (/proc, df, who — работает и на роутерах с BusyBox). Выключено — запросов нет.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = String(scrollback) }
    }

    private func pickEditor() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            externalEditor = url.path
        }
    }

    private func apply() {
        let cleaned = draft.filter(\.isNumber)
        guard let value = Int(cleaned) else {
            note = "Нужно число"; return
        }
        let clamped = min(max(value, QTermTerminal.scrollbackRange.lowerBound), QTermTerminal.scrollbackRange.upperBound)
        scrollback = clamped
        draft = String(clamped)
        note = clamped != value ? "Ограничено диапазоном: \(clamped)" : nil
    }
}

/// Вид: тема и шрифт терминала — применяются сразу ко всем вкладкам.
struct AppearanceSettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(TerminalLook.themeKey) private var theme = AppTheme.dark.rawValue
    @AppStorage(TerminalLook.fontNameKey) private var fontName = ""
    @AppStorage(TerminalLook.fontSizeKey) private var fontSize = TerminalLook.fontSizeDefault
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section("Тема") {
                Picker("Оформление", selection: $theme) {
                    ForEach(AppTheme.allCases) { t in
                        Text(t.title).tag(t.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Тёмная — всё тёмное (интерфейс и терминалы), светлая — всё светлое.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Шрифт терминала") {
                Picker("Семейство", selection: $fontName) {
                    Text("Системный моноширинный (SF Mono)").tag("")
                    ForEach(families, id: \.self) { f in
                        Text(f).tag(f)
                    }
                }
                HStack {
                    Text("Размер")
                    Spacer()
                    Text("\(Int(fontSize)) pt").monospacedDigit()
                    Stepper("", value: $fontSize, in: TerminalLook.fontSizeRange, step: 1)
                        .labelsHidden()
                }
                Text("Образец: ls -la /opt/etc  → 0O 1lI {}[] ✓ Привет")
                    .font(Font(TerminalLook.font as CTFont))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.12)))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if families.isEmpty { families = TerminalLook.monospacedFamilies }
        }
        .onChange(of: theme) { _, _ in TerminalLook.apply(state) }
        .onChange(of: fontName) { _, _ in TerminalLook.apply(state) }
        .onChange(of: fontSize) { _, _ in TerminalLook.apply(state) }
    }
}
