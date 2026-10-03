import SwiftUI
import AppKit
import SessionVaultKit

// Раздел «Обновления»: версии панелей 3x-ui и ядра Xray, самообновление с бэкапом базы, смена ядра,
// geo-файлы, бэкапы и откат (версия панели через SSH-терминал сервера + база из бэкапа). Порт XuiWindow.Updates.cs.

struct UpdInfo {
    var version = "", latest = "", xray = "", state = "", ssh = ""
    var available = false, error = false, busy = false
}

struct UpdRow: Identifiable {
    var id: String { p.id }
    let p: XuiPanel
    let info: UpdInfo
    let lastBackup: String
    var dot: Color {
        info.error ? .red : info.busy ? .orange : info.available ? .blue : info.version.isEmpty ? .secondary : .green
    }
}

/// Выбор строки из списка (версии ядра/панели); можно вписать свою.
final class PickRequest: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let items: [String]
    let selected: String?
    let ok: String
    var done: ((String?) -> Void)?
    init(title: String, text: String, items: [String], selected: String?, ok: String = "Выбрать") {
        self.title = title; self.text = text; self.items = items; self.selected = selected; self.ok = ok
    }
}

extension XuiModel {
    var updPanels: [XuiPanel] { store.panels().filter(\.isXui) }

    var updRows: [UpdRow] {
        let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
        return updPanels
            .sorted { ($0.isMaster ? 1 : 0, $0.name.lowercased()) < ($1.isMaster ? 1 : 0, $1.name.lowercased()) }
            .map { p in
                let last = XuiBackups.forPanel(p).first
                return UpdRow(p: p, info: updInfo[p.id] ?? UpdInfo(),
                              lastBackup: last.map { "\(f.string(from: $0.time)) · v\($0.version.isEmpty ? "?" : $0.version)" } ?? "—")
            }
    }

    var updSelected: [XuiPanel] { updPanels.filter { updSel.contains($0.id) } }

    var bakRows: [XuiBackup] {
        let sel = updSelected
        return sel.count == 1 ? XuiBackups.forPanel(sel[0]) : XuiBackups.list()
    }

    var bakCaption: String {
        let sel = updSelected
        return sel.count == 1 ? "Бэкапы «\(sel[0].name)» (\(bakRows.count))" : "Все бэкапы (\(bakRows.count)) — выдели панель, чтобы отфильтровать"
    }

    private func setState(_ p: XuiPanel, _ s: String, error: Bool = false) {
        var i = updInfo[p.id] ?? UpdInfo()
        i.state = s
        i.error = error
        updInfo[p.id] = i
    }

    private func edit(_ p: XuiPanel, _ f: (inout UpdInfo) -> Void) {
        var i = updInfo[p.id] ?? UpdInfo()
        f(&i)
        updInfo[p.id] = i
    }

    func askPick(_ req: PickRequest) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            req.done = { cont.resume(returning: $0) }
            pickRequest = req
        }
    }

    func refreshUpdates() async {
        let panels = updPanels
        if panels.isEmpty { updStatus = "Нет панелей 3x-ui с токеном — «Панели и токены…» или «＋ Нода из выделения»"; return }
        updStatus = "проверяю версии…"
        for p in panels {
            // DNS-сопоставление панели с SSH-сессией
            let name = store.sessionFor(p)?.name ?? "—"
            edit(p) { $0.ssh = name }
        }
        await withTaskGroup(of: (String, UpdInfo?, String?).self) { g in
            for p in panels where !(updInfo[p.id]?.busy ?? false) {
                let cur = updInfo[p.id] ?? UpdInfo()
                g.addTask {
                    var i = cur
                    do {
                        let api = try XuiAPI.forPanel(p)
                        let st = try await api.status()
                        i.version = XuiBackups.norm(J.str(st, "panelVersion"))
                        i.xray = (st["xray"] as? JObj).map { J.str($0, "version") } ?? ""
                        let info = await api.updateInfo()
                        i.latest = XuiBackups.norm(info.map { J.str($0, "latestVersion") })
                        i.available = info.map { J.bool($0, "updateAvailable") } ?? false
                        if i.state.hasPrefix("✗") || i.state.isEmpty {
                            i.state = info == nil ? "панель не достучалась до GitHub — обновление только через терминал" : ""
                        }
                        i.error = false
                        return (p.id, i, nil)
                    } catch { return (p.id, nil, error.localizedDescription) }
                }
            }
            for await (id, info, err) in g {
                if let info { updInfo[id] = info }
                else if let err { var i = updInfo[id] ?? UpdInfo(); i.state = "✗ " + err; i.error = true; updInfo[id] = i }
            }
        }
        let noToken = nodes.filter { savedFor($0) == nil }.map(\.name)
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        updStatus = "панелей \(panels.count), есть обновление: \(panels.filter { updInfo[$0.id]?.available ?? false }.count) · \(f.string(from: Date()))"
            + (noToken.isEmpty ? "" : " · без токена в QTerm: \(noToken.joined(separator: ", "))")
    }

    /// Одна операция за раз; ошибки — в лог.
    private func updOp(_ title: String, _ op: () async throws -> Void) async {
        if updBusy || busy { log("! дождись окончания текущей операции", .warn); return }
        updBusy = true
        log("━━ \(title)", .head)
        do { try await op() } catch { log("✗ " + error.localizedDescription, .err) }
        updBusy = false
        objectWillChange.send()
    }

    private func backupOne(_ api: XuiAPI, _ p: XuiPanel) async throws {
        setState(p, "бэкап базы…")
        let path = try await XuiBackups.save(api, p.name)
        log("  ✓ бэкап «\(p.name)» → \(path)", .ok)
    }

    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// Ждём, пока панель ответит и покажет нужную версию (или любую, если want == nil).
    private func waitPanel(_ api: XuiAPI, _ p: XuiPanel, want: String?, seconds: Double, _ what: String) async -> String? {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            await sleep(5)
            let secs = Int(Date().timeIntervalSince(t0))
            if let st = try? await api.status() {
                let v = XuiBackups.norm(J.str(st, "panelVersion"))
                setState(p, "\(what)… \(secs) с, сейчас v\(v)")
                if want == nil || v == XuiBackups.norm(want) { return v }
            } else {
                setState(p, "\(what)… панель перезапускается")
            }
        }
        return nil
    }

    // MARK: самообновление

    func updatePanels() async {
        var sel = updSelected
        if sel.isEmpty { sel = updPanels.filter { updInfo[$0.id]?.available ?? false } }
        if sel.isEmpty { XuiDialog.info("Выдели панели (или сначала «Проверить версии» — обновлю те, где есть новая версия)"); return }
        // ноды первыми: новая главная шлёт узлам поля, которых старый узел может не понять
        let order = sel.sorted { ($0.isMaster ? 1 : 0, $0.name.lowercased()) < ($1.isMaster ? 1 : 0, $1.name.lowercased()) }
        guard XuiDialog.confirm(
            "Обновить по очереди: \(order.map(\.name).joined(separator: " → "))\n\n" +
            "Каждая: бэкап базы → самообновление панели (update.sh с GitHub) → ждём, пока поднимется с новой версией. " +
            "На первой ошибке останавливаюсь. Откат — внизу, из бэкапа.\n\nСовет: свежий релиз сначала поставь на одну ноду и проверь.",
            title: "Обновление панелей", yes: "Обновить") else { return }
        await updOp("Обновление панелей") {
            for p in order {
                edit(p) { $0.busy = true }
                defer { edit(p) { $0.busy = false } }
                do {
                    let api = try XuiAPI.forPanel(p)
                    let from = XuiBackups.norm(J.str(try await api.status(), "panelVersion"))
                    let settings = try await api.settings()
                    if J.str(settings, "webCertFile").isEmpty {
                        // update.sh без сертификата в панели начинает выпускать его и спрашивать в консоли
                        setState(p, "пропущена: в панели нет SSL-сертификата — обнови через терминал", error: true)
                        log("  ! «\(p.name)»: в настройках панели не задан сертификат — апдейтер 3x-ui начнёт выпускать его сам. Обнови её кнопкой «Версия через терминал…»", .warn)
                        continue
                    }
                    try await backupOne(api, p)
                    setState(p, "обновляю…")
                    let runId = try await api.startUpdate()
                    log("  … «\(p.name)»: обновление запущено (v\(from))", .dim)
                    let t0 = Date()
                    var state = "pending"
                    while Date().timeIntervalSince(t0) < 420 {
                        await sleep(5)
                        if let us = try? await api.updateStatus(), J.str(us, "runId") == (runId ?? "") {
                            state = J.str(us, "state", "pending")
                        }
                        setState(p, "обновляю… \(Int(Date().timeIntervalSince(t0))) с")
                        if state == "success" || state == "failed" { break }
                    }
                    if state == "failed" { throw XuiError("апдейтер завершился с ошибкой (журнал: x-ui log на сервере)") }
                    guard let now = await waitPanel(api, p, want: nil, seconds: 120, "жду панель") else {
                        throw XuiError("панель не поднялась за 2 минуты после обновления")
                    }
                    if now == from { throw XuiError("версия не поменялась (v\(now)) — смотри журнал апдейтера на сервере") }
                    edit(p) { $0.version = now; $0.available = false }
                    setState(p, "✓ v\(from) → v\(now)")
                    log("  ✓ «\(p.name)»: v\(from) → v\(now)", .ok)
                } catch {
                    setState(p, "✗ " + error.localizedDescription, error: true)
                    log("  ✗ «\(p.name)»: \(error.localizedDescription). Остальные не трогаю. Бэкап базы — внизу, откат — «Откатить панель к этому бэкапу…»", .err)
                    break
                }
            }
        }
        await refreshUpdates()
    }

    // MARK: ядро Xray

    func installXray() async {
        let sel = updSelected
        if sel.isEmpty { XuiDialog.info("Выдели панели, на которые поставить ядро"); return }
        let versions: [String]
        do { versions = try await XuiAPI.forPanel(sel[0]).xrayVersions() }
        catch { XuiDialog.info("Список версий Xray не получен: " + error.localizedDescription); return }
        if versions.isEmpty { XuiDialog.info("Панель не вернула версий Xray (нет выхода на GitHub?)"); return }
        let cur = updInfo[sel[0].id]?.xray ?? ""
        guard let v = await askPick(PickRequest(
            title: "Ядро Xray",
            text: "Ядро Xray для: \(sel.map(\.name).joined(separator: ", ")). Сейчас: \(cur.isEmpty ? "?" : cur). Двойной клик — выбрать.",
            items: versions, selected: versions.first { XuiBackups.norm($0) == XuiBackups.norm(cur) } ?? versions[0], ok: "Поставить"))
        else { return }
        await updOp("Ядро Xray \(v)") {
            for p in sel {
                edit(p) { $0.busy = true }
                defer { edit(p) { $0.busy = false } }
                do {
                    let api = try XuiAPI.forPanel(p)
                    try await backupOne(api, p)
                    setState(p, "ставлю Xray \(v)…")
                    try await api.installXray(v)
                    await sleep(3)
                    let x = try await api.status()["xray"] as? JObj
                    let ver = x.map { J.str($0, "version") } ?? ""
                    let state = x.map { J.str($0, "state") } ?? ""
                    edit(p) { $0.xray = ver }
                    let okState = state.isEmpty || state == "running"
                    setState(p, "✓ Xray \(ver) (\(state))", error: !okState)
                    log("  ✓ «\(p.name)»: Xray \(ver), \(state)", okState ? .ok : .warn)
                } catch {
                    setState(p, "✗ " + error.localizedDescription, error: true)
                    log("  ✗ «\(p.name)»: \(error.localizedDescription)", .err)
                }
            }
        }
    }

    func updateGeo() async {
        let sel = updSelected
        if sel.isEmpty { XuiDialog.info("Выдели панели"); return }
        await updOp("Geo-файлы") {
            for p in sel {
                do {
                    try await XuiAPI.forPanel(p).updateGeo()
                    setState(p, "✓ geo-файлы обновлены")
                    log("  ✓ «\(p.name)»: geoip/geosite обновлены", .ok)
                } catch {
                    setState(p, "✗ " + error.localizedDescription, error: true)
                    log("  ✗ «\(p.name)»: \(error.localizedDescription)", .err)
                }
            }
        }
    }

    func backupNow() async {
        var sel = updSelected
        if sel.isEmpty { sel = updPanels }
        await updOp("Бэкап баз") {
            for p in sel {
                do {
                    try await backupOne(XuiAPI.forPanel(p), p)
                    setState(p, "✓ бэкап снят")
                } catch {
                    setState(p, "✗ " + error.localizedDescription, error: true)
                    log("  ✗ «\(p.name)»: \(error.localizedDescription)", .err)
                }
            }
        }
    }

    // MARK: версия через терминал / откат

    static func releases() async -> [String] {
        guard let url = URL(string: "https://api.github.com/repos/MHSanaei/3x-ui/releases?per_page=30") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("QTerm", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: req),
              let arr = J.parse(res.0) as? [Any] else { return [] }
        return arr.compactMap { $0 as? JObj }
            .filter { !J.bool($0, "draft") && !J.bool($0, "prerelease") }
            .map { J.str($0, "tag_name") }.filter { !$0.isEmpty }
    }

    /// Установка конкретного релиза: апдейтер 3x-ui с тегом (конфиг и база остаются на месте).
    static func installCommand(_ tag: String, user: String) -> String {
        let sudo = user == "root" ? "" : "sudo "
        return "curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh -o /tmp/xui-update.sh && " +
            "\(sudo)env XUI_UPDATE_TAG=\(tag) bash /tmp/xui-update.sh"
    }

    func installViaTerminalPick() async {
        let sel = updSelected
        if sel.count != 1 { XuiDialog.info("Выдели одну панель"); return }
        let p = sel[0]
        let tags = await Self.releases()
        if tags.isEmpty { log("! список релизов 3x-ui с GitHub не получен — впиши версию руками", .warn) }
        let cur = updInfo[p.id]?.version ?? ""
        let prev = XuiBackups.forPanel(p).map(\.version).first { !$0.isEmpty && !cur.isEmpty && $0 != cur }
        guard let tag = await askPick(PickRequest(
            title: "Версия панели через терминал",
            text: "Какую версию 3x-ui поставить на «\(p.name)»? Сейчас v\(cur.isEmpty ? "?" : cur). Команда уйдёт в SSH-терминал сервера (видно, что происходит); база и настройки остаются. Для отката на старую версию лучше «Откатить панель к этому бэкапу…» — вернёт и базу.",
            items: tags, selected: prev.map { "v" + $0 } ?? tags.first, ok: "Поставить"))
        else { return }
        await installViaTerminal(p, tag.hasPrefix("v") ? tag : "v" + tag, restore: nil)
    }

    func rollbackToBackup() async {
        guard let b = bakRows.first(where: { $0.id == bakSel }) else { XuiDialog.info("Выбери бэкап в списке снизу"); return }
        guard let p = panelForBackup(b) else { return }
        if b.version.isEmpty {
            XuiDialog.info("В этом бэкапе не записана версия панели (старый формат). Поставь версию кнопкой «Версия через терминал…», потом «Восстановить базу…».")
            return
        }
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"
        guard XuiDialog.confirm(
            "Откат «\(p.name)» к v\(b.version) и базе от \(f.string(from: b.time)):\n\n" +
            "1) бэкап текущей базы (чтобы можно было вернуться);\n2) в SSH-терминале сервера — установка 3x-ui v\(b.version);\n" +
            "3) жду панель с этой версией;\n4) загружаю базу из бэкапа (адреса, сертификаты и привязка узла этой машины сохраняются).\n\n" +
            "Клиенты, добавленные после бэкапа, на этой панели пропадут.",
            title: "Откат панели", yes: "Откатить") else { return }
        await installViaTerminal(p, "v" + b.version, restore: b)
    }

    private func installViaTerminal(_ p: XuiPanel, _ tag: String, restore: XuiBackup?) async {
        guard let run = runInTerminal else { XuiDialog.info("Терминал QTerm недоступен из этого окна"); return }
        guard let sess = store.sessionFor(p) else {
            XuiDialog.info("Для «\(p.name)» не найдена SSH-сессия QTerm (ни по адресу, ни по IP). Привяжи её в «Панели и токены…» → «SSH-сессия».")
            return
        }
        let cmd = Self.installCommand(tag, user: sess.username)
        await updOp("«\(p.name)» → \(tag)\(restore == nil ? "" : " + база из бэкапа")") {
            edit(p) { $0.busy = true }
            defer { edit(p) { $0.busy = false } }
            do {
                let api = try XuiAPI.forPanel(p)
                try await backupOne(api, p)
                setState(p, "команда отправлена в терминал «\(sess.name)»")
                guard await run(sess.id, cmd) else {
                    XuiDialog.copy(cmd)
                    throw XuiError("не удалось открыть терминал «\(sess.name)» — команда в буфере, вставь её сам")
                }
                log("  … в терминале «\(sess.name)»: \(cmd)", .dim)
                guard let v = await waitPanel(api, p, want: tag, seconds: 600, "жду v\(XuiBackups.norm(tag))") else {
                    throw XuiError("за 10 минут панель не показала v\(XuiBackups.norm(tag)) — смотри терминал")
                }
                edit(p) { $0.version = v }
                log("  ✓ «\(p.name)»: v\(v)", .ok)
                if let r = restore {
                    setState(p, "загружаю базу из бэкапа…")
                    try await api.importDb(Data(contentsOf: URL(fileURLWithPath: r.path)))
                    guard await waitPanel(api, p, want: nil, seconds: 90, "панель перезапускается с базой") != nil else {
                        throw XuiError("после загрузки базы панель не ответила за 90 с")
                    }
                    log("  ✓ «\(p.name)»: база из \(r.fileName) на месте", .ok)
                }
                setState(p, "✓ v\(v)\(restore == nil ? "" : " + база из бэкапа")")
            } catch {
                setState(p, "✗ " + error.localizedDescription, error: true)
                log("  ✗ «\(p.name)»: \(error.localizedDescription)", .err)
            }
        }
        await refreshUpdates()
    }

    // MARK: бэкапы

    private func panelForBackup(_ b: XuiBackup) -> XuiPanel? {
        let sel = updSelected
        if sel.count == 1 { return sel[0] }
        let p = updPanels.first { XuiBackups.safe($0.name).caseInsensitiveCompare(b.panel) == .orderedSame }
            ?? (b.panel.caseInsensitiveCompare("master") == .orderedSame ? updPanels.first(where: \.isMaster) : nil)
        if p == nil { XuiDialog.info("Не понял, чей это бэкап («\(b.panel)») — выдели панель сверху") }
        return p
    }

    func restoreBackup() async {
        guard let b = bakRows.first(where: { $0.id == bakSel }) else { XuiDialog.info("Выбери бэкап в списке снизу"); return }
        guard let p = panelForBackup(b) else { return }
        let cur = updInfo[p.id]?.version ?? ""
        var warn = ""
        if !b.version.isEmpty && !cur.isEmpty && b.version != cur {
            warn = XuiBackups.compare(b.version, cur) < 0
                ? "\n\nБаза от v\(b.version), панель v\(cur): панель сама доведёт её миграциями при старте."
                : "\n\n⚠ База от более НОВОЙ v\(b.version), а панель v\(cur) — старая панель может её не понять. Лучше «Откатить панель к этому бэкапу…»."
        }
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm"
        guard XuiDialog.confirm(
            "Загрузить в «\(p.name)» базу из \(b.fileName) (\(f.string(from: b.time)))?\nПеред этим сниму бэкап текущей базы. Адреса, сертификаты и привязка узла этой машины сохраняются; панель перезапустится." + warn,
            title: "Восстановление базы", yes: "Восстановить") else { return }
        await updOp("Восстановление базы «\(p.name)»") {
            edit(p) { $0.busy = true }
            defer { edit(p) { $0.busy = false } }
            do {
                let api = try XuiAPI.forPanel(p)
                try await backupOne(api, p)
                setState(p, "загружаю базу…")
                try await api.importDb(Data(contentsOf: URL(fileURLWithPath: b.path)))
                guard await waitPanel(api, p, want: nil, seconds: 90, "панель перезапускается") != nil else {
                    throw XuiError("после загрузки базы панель не ответила за 90 с")
                }
                setState(p, "✓ база от \(f.string(from: b.time)) на месте")
                log("  ✓ «\(p.name)»: база из \(b.fileName) загружена", .ok)
            } catch {
                setState(p, "✗ " + error.localizedDescription, error: true)
                log("  ✗ «\(p.name)»: \(error.localizedDescription)", .err)
            }
        }
        await refresh(quiet: true)
    }

    func openBackupFolder() {
        try? FileManager.default.createDirectory(at: XuiBackups.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(XuiBackups.dir)
    }
}
