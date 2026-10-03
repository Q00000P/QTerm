import SwiftUI
import AppKit
import SessionVaultKit

/// Команды с Git (гисты и т.п.) — порт GitCmdsWindow с Windows.
/// Одно окно и для быстрого вызова (⌘⇧G: поиск → Enter), и для правки.
/// Три поля: имя (по нему поиск и вывод), команда, заметка. Синкается
/// как "gitCommands" — общий канон с Windows/Android.
struct GitCommandsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var selection: UUID?
    /// nil — новая запись (ещё не сохранена).
    @State private var currentID: UUID?
    @State private var name = ""
    @State private var command = ""
    @State private var note = ""
    @State private var status = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable { case search, list, name, command, note }

    // MARK: Данные

    private var rows: [GitCommand] {
        let f = search.trimmingCharacters(in: .whitespaces)
        return state.visibleGitCommands.filter { g in
            f.isEmpty
                || g.name.localizedCaseInsensitiveContains(f)
                || g.note.localizedCaseInsensitiveContains(f)
                || g.command.localizedCaseInsensitiveContains(f)
        }
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func trimmedCommand(_ s: String) -> String {
        normalize(s).trimmingCharacters(in: CharacterSet(charactersIn: "\n \t"))
    }

    private static func firstLine(_ s: String) -> String {
        normalize(s).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Есть несохранённое: сравниваем поля с сохранённой записью.
    private var isDirty: Bool {
        if let id = currentID, let g = state.gitCommand(id) {
            return g.name != name.trimmingCharacters(in: .whitespaces)
                || g.command != Self.trimmedCommand(command)
                || g.note != Self.normalize(note).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !(name + command + note).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Имя по умолчанию: имя файла из последней ссылки
    /// (…/raw/server-init.sh → server-init.sh), иначе начало команды.
    static func deriveName(_ cmd: String) -> String {
        let rx = try? NSRegularExpression(pattern: #"https?://[^\s'"<>|;&]+"#)
        let ns = cmd as NSString
        let matches = rx?.matches(in: cmd, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in matches.reversed() {
            var u = ns.substring(with: m.range)
            if let cut = u.firstIndex(where: { $0 == "?" || $0 == "#" }) { u = String(u[..<cut]) }
            while u.hasSuffix("/") { u.removeLast() }
            let seg = String(u.split(separator: "/").last ?? "")
            if !seg.isEmpty, seg.lowercased() != "raw", !seg.contains(":") {
                return seg.removingPercentEncoding ?? seg
            }
        }
        let first = firstLine(cmd)
        return first.count > 40 ? String(first.prefix(40)) + "…" : first
    }

    // MARK: Вид

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                listPane
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                editorPane
                    .frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 520)
        .onAppear {
            if let first = rows.first { selection = first.id; load(first.id) }
            focus = .search
            updateStatus()
        }
        .onChange(of: selection) { _, new in
            guard let new, new != currentID else { return }
            confirmSaveIfDirty()
            load(new)
        }
        .onChange(of: search) { _, _ in
            // Идёт правка — не перескакиваем на другую запись при поиске.
            guard !isDirty else { return }
            if let cur = currentID, rows.contains(where: { $0.id == cur }) { return }
            if let first = rows.first { selection = first.id; load(first.id) }
        }
        .onChange(of: name) { _, _ in updateStatus() }
        .onChange(of: command) { _, _ in updateStatus() }
        .onChange(of: note) { _, _ in updateStatus() }
    }

    private var listPane: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Поиск по имени, заметке, команде", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
                        handleQuickKey(press)
                    }
                Button {
                    newEntry()
                } label: {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("⌘N. Если в буфере команда со ссылкой — подставится сама, имя возьмётся из имени файла")
            }
            List(selection: $selection) {
                ForEach(rows) { g in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(g.name).fontWeight(.semibold).lineLimit(1)
                        let preview = Self.firstLine(g.note)
                        if !preview.isEmpty {
                            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(g.id)
                    .help(g.note.isEmpty ? g.command : g.command + "\n\n" + g.note)
                }
            }
            .listStyle(.inset)
            .focused($focus, equals: .list)
            .onKeyPress(keys: [.return, .delete]) { press in
                if press.key == .delete { deleteCurrent(); return .handled }
                return handleQuickKey(press)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first {
                    Button("Выполнить") { selection = id; load(id); run(execute: true) }
                    Button("Вставить") { selection = id; load(id); run(execute: false) }
                    Divider()
                    Button("Удалить", role: .destructive) { selection = id; load(id); deleteCurrent() }
                }
            } primaryAction: { ids in
                if let id = ids.first { selection = id; load(id); run(execute: true) }
            }
        }
        .padding(10)
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Имя").font(.caption).foregroundStyle(.secondary)
            TextField("Пусто — возьмётся из имени файла в ссылке", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .name)
                .onSubmit { doSave() }
            Text("Команда").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            TextEditor(text: $command)
                .font(.system(.callout, design: .monospaced))
                .focused($focus, equals: .command)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.35)))
            Text("Заметка").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            TextEditor(text: $note)
                .font(.callout)
                .focused($focus, equals: .note)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.35)))
        }
        .padding(10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Удалить", role: .destructive) { deleteCurrent() }
                .help("Удаление уедет синком на все устройства")
            Text(status)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Закрыть") { closeAsking() }
                .keyboardShortcut(.cancelAction)
            Button("Копировать") { copyCommand() }
            Button("Сохранить") { doSave() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Вставить") { run(execute: false) }
                .help("⇧↩ в поиске/списке — вставить в терминал без запуска")
            Button("Выполнить") { run(execute: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .help("↩ в поиске/списке или ⌘↩ — вставить в терминал и запустить")
        }
        .padding(10)
    }

    // MARK: Клавиатура в поиске/списке

    private func handleQuickKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            // ↩ — выполнить, ⇧↩ — только вставить (канон Windows).
            run(execute: !press.modifiers.contains(.shift))
            return .handled
        case .downArrow, .upArrow:
            guard !rows.isEmpty else { return .ignored }
            let idx = rows.firstIndex { $0.id == selection } ?? -1
            let next = min(max(idx + (press.key == .downArrow ? 1 : -1), 0), rows.count - 1)
            selection = rows[next].id
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: Действия

    private func load(_ id: UUID) {
        guard let g = state.gitCommand(id) else { blank(); return }
        currentID = g.id
        name = g.name
        command = g.command
        note = g.note
        updateStatus()
    }

    private func blank() {
        currentID = nil
        name = ""
        command = ""
        note = ""
        updateStatus()
    }

    private func updateStatus() {
        let n = state.visibleGitCommands.count
        let mark = currentID == nil
            ? (isDirty ? "● новая, не сохранена · " : "")
            : (isDirty ? "● изменено · " : "")
        status = mark + "\(n) шт. · ↩ выполнить · ⇧↩ вставить · ⌘S сохранить · Esc закрыть"
    }

    /// Сохранить поля. false — пустая команда (нечего сохранять).
    @discardableResult
    private func saveCore() -> Bool {
        let cmd = Self.trimmedCommand(command)
        guard !cmd.isEmpty else {
            status = "Пустая команда — нечего сохранять"
            focus = .command
            return false
        }
        var nm = name.trimmingCharacters(in: .whitespaces)
        if nm.isEmpty { nm = Self.deriveName(cmd) }
        var g = currentID.flatMap { state.gitCommand($0) } ?? GitCommand(name: nm, command: cmd)
        g.name = nm
        g.command = cmd
        g.note = Self.normalize(note).trimmingCharacters(in: .whitespacesAndNewlines)
        state.saveGitCommand(g)
        currentID = g.id
        selection = g.id
        name = nm
        command = cmd
        note = g.note
        return true
    }

    private func doSave() {
        if saveCore() {
            updateStatus()
            status = "Сохранено · " + status
        }
    }

    /// Несохранённое при переходе на другую запись — спросить.
    private func confirmSaveIfDirty() {
        guard isDirty else { return }
        let what = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "новую команду" : "«\(name.trimmingCharacters(in: .whitespaces))»"
        let alert = NSAlert()
        alert.messageText = "Сохранить \(what)?"
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        if alert.runModal() == .alertFirstButtonReturn { saveCore() }
    }

    private func newEntry() {
        confirmSaveIfDirty()
        selection = nil
        blank()
        // Скопировал команду со ссылкой из гиста — подставляем сразу.
        let clip = Self.normalize(NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !clip.isEmpty, clip.count <= 4000,
           clip.range(of: #"https?://"#, options: .regularExpression) != nil {
            command = clip
            name = Self.deriveName(clip)
            focus = .note
        } else {
            focus = .name
        }
        updateStatus()
    }

    private func deleteCurrent() {
        guard let id = currentID, let g = state.gitCommand(id) else { blank(); return }
        let alert = NSAlert()
        alert.messageText = "Удалить «\(g.name)»?"
        alert.informativeText = "Удаление уедет на все устройства."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.deleteGitCommand(id)
        blank()
        if let first = rows.first { selection = first.id; load(first.id) } else { selection = nil }
        updateStatus()
    }

    private func copyCommand() {
        let cmd = Self.trimmedCommand(command)
        guard !cmd.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        status = "Скопировано в буфер"
    }

    private func run(execute: Bool) {
        let cmd = Self.trimmedCommand(command)
        guard !cmd.isEmpty else { return }
        if isDirty && !saveCore() { return } // правки не теряем
        dismiss()
        let text = execute ? cmd + "\n" : cmd
        if state.sendText(text) {
            state.focusActiveTerminal()
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            Dialogs.info("Нет открытого терминала — команда скопирована в буфер.")
        }
    }

    private func closeAsking() {
        guard isDirty else { dismiss(); state.focusActiveTerminal(); return }
        let what = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "новую команду" : "«\(name.trimmingCharacters(in: .whitespaces))»"
        let alert = NSAlert()
        alert.messageText = "Сохранить \(what)?"
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if saveCore() { dismiss(); state.focusActiveTerminal() }
        case .alertSecondButtonReturn:
            dismiss(); state.focusActiveTerminal()
        default:
            break
        }
    }
}
