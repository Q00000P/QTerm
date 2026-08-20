import SwiftUI
import SessionVaultKit

/// Данные → Журнал команд…: просмотр и правка журнала подсказок.
/// Удаление — tombstone: уезжает синком и не воскресает с других устройств
/// (повторный ввод команды воскрешает её честно).
struct CommandLogView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""
    @State private var confirmClear = false

    private var rows: [(cmd: String, stat: CmdStat)] {
        let all = state.visibleCmdHistory
        guard !filter.isEmpty else { return all }
        return all.filter { $0.cmd.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Журнал команд").font(.headline)
            Text("Команды, набранные в терминале (синкаются между устройствами и подсвечиваются ★ в подсказках). Удалённые не возвращаются с других устройств; повторный ввод команды вернёт её в журнал.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Поиск…", text: $filter)
                .textFieldStyle(.roundedBorder)

            if rows.isEmpty {
                Spacer()
                Text(filter.isEmpty ? "Журнал пуст — он копится с Enter'ов в терминале" : "Ничего не найдено")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List {
                    ForEach(rows, id: \.cmd) { row in
                        HStack(spacing: 8) {
                            Text(row.cmd)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("×\(row.stat.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Self.shortDate(row.stat.lastUsed))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 90, alignment: .trailing)
                            Button {
                                state.deleteCommand(row.cmd)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Удалить из журнала (на всех устройствах)")
                        }
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text("\(rows.count) команд")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Очистить журнал", role: .destructive) { confirmClear = true }
                    .disabled(state.visibleCmdHistory.isEmpty)
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
        .confirmationDialog(
            "Удалить весь журнал команд? Подсказки останутся только словарные.",
            isPresented: $confirmClear
        ) {
            Button("Очистить", role: .destructive) { state.clearCommandLog() }
            Button("Отмена", role: .cancel) {}
        }
    }

    private static func shortDate(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }
}
