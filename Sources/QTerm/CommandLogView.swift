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
    @State private var macScope = false
    @State private var newDictCmd = ""
    @State private var showDict = false

    private var rows: [(cmd: String, stat: CmdStat)] {
        let all = state.visibleCmdHistory(macScope: macScope)
        guard !filter.isEmpty else { return all }
        return all.filter { $0.cmd.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Журнал команд").font(.headline)
            Text("Команды, набранные в терминале (синкаются между устройствами и подсвечиваются ★ в подсказках). Удалённые не возвращаются с других устройств; повторный ввод команды вернёт её в журнал.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Picker("", selection: $macScope) {
                    Text("Серверы").tag(false)
                    Text("Мак").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("", selection: $showDict) {
                    Text("Журнал").tag(false)
                    Text("Словарь").tag(true)
                }
                .pickerStyle(.segmented)
            }

            TextField("Поиск…", text: $filter)
                .textFieldStyle(.roundedBorder)

            if showDict {
                dictList
            } else if rows.isEmpty {
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
                                state.addDictEntry(row.cmd, scope: macScope ? "mac" : "server")
                            } label: {
                                Image(systemName: "text.book.closed")
                            }
                            .buttonStyle(.borderless)
                            .help("Добавить в словарь (синкается)")
                            Button {
                                state.deleteCommand(row.cmd, macScope: macScope)
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

            HStack(spacing: 6) {
                TextField("Своя команда в словарь…", text: $newDictCmd)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addToDict() }
                Button("В словарь") { addToDict() }
                    .disabled(newDictCmd.trimmingCharacters(in: .whitespaces).count < 2)
            }

            HStack {
                Text(showDict ? "\(dictRows.count) в словаре" : "\(rows.count) команд")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !showDict {
                    Button("Очистить журнал", role: .destructive) { confirmClear = true }
                        .disabled(state.visibleCmdHistory(macScope: macScope).isEmpty)
                }
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
            Button("Очистить", role: .destructive) { state.clearCommandLog(macScope: macScope) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func addToDict() {
        let cmd = newDictCmd.trimmingCharacters(in: .whitespaces)
        guard cmd.count >= 2 else { return }
        state.addDictEntry(cmd, scope: macScope ? "mac" : "server")
        newDictCmd = ""
        showDict = true   // сразу показать результат в разделе «Словарь»
    }

    // MARK: Раздел «Словарь»

    private struct DictRow: Identifiable {
        let id: String
        let custom: Bool   // своя (можно удалить) или встроенная (можно скрыть)
    }

    private var dictRows: [DictRow] {
        let rows = state.dictionaryRows(macScope: macScope)
        let all = rows.map { DictRow(id: $0.cmd, custom: $0.custom) }
        guard !filter.isEmpty else { return all }
        return all.filter { $0.id.localizedCaseInsensitiveContains(filter) }
    }

    private var dictList: some View {
        List {
            ForEach(dictRows) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.custom ? "person.fill" : "text.book.closed")
                        .font(.caption)
                        .foregroundStyle(row.custom ? Color.cyan : Color.secondary)
                        .frame(width: 14)
                    Text(row.id)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        if row.custom {
                            state.removeDictEntry(row.id)
                        } else {
                            state.hideDictEntry(row.id)
                        }
                    } label: {
                        Image(systemName: row.custom ? "trash" : "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .help(row.custom ? "Удалить свою команду (на всех устройствах)" : "Скрыть встроенную из подсказок")
                }
            }
        }
        .listStyle(.inset)
    }

    private static func shortDate(_ iso: String?) -> String {
        guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: date)
    }
}
