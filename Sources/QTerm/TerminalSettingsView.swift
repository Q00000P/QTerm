import SwiftUI

/// Настройки терминала: поле «строк истории» (50…1 000 000).
/// Применяется к вкладкам, открытым после изменения.
struct TerminalSettingsView: View {
    @AppStorage(QTermTerminal.scrollbackKey) private var scrollback = QTermTerminal.scrollbackDefault
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { draft = String(scrollback) }
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
