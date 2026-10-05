import SwiftUI
import AppKit

// «Источники нод» каскада — две логики сразу:
// • свой клиент каскада на любой панели 3x-ui (главной — с инбаундами всех узлов, или отдельной ноде) с нужным
//   набором инбаундов: его Clash-подписка и есть источник, единая подписка клиентов не трогается;
// • подписки отдельных нод (ссылкой) и WireGuard/AWG (клиент AWG-панели другой ноды или .conf) — в т.ч. резерв.
// Источники живут на сервере (/etc/qcascade/sources.json, 600): ссылки и ключи в QTerm не хранятся.

extension CascadeModel {
    private func taken(_ list: [CascadeSource]) -> Set<String> { Set(list.map(\.name)) }

    private static func freeName(_ want: String, _ taken: Set<String>) -> String {
        if !taken.contains(want) { return want }
        for i in 2..<100 where !taken.contains("\(want)-\(i)") { return "\(want)-\(i)" }
        return want + "-" + String(UUID().uuidString.prefix(4))
    }

    func askXuiSource(_ r: XuiSourceRequest) async -> CascadeSource? {
        await withCheckedContinuation { (cont: CheckedContinuation<CascadeSource?, Never>) in
            r.done = { cont.resume(returning: $0) }
            xuiSource = r
        }
    }

    func askWgSource(_ r: WgSourceRequest) async -> (source: CascadeSource, reserve: Bool)? {
        await withCheckedContinuation { (cont: CheckedContinuation<(source: CascadeSource, reserve: Bool)?, Never>) in
            r.done = { cont.resume(returning: $0) }
            wgSource = r
        }
    }

    private func sourcesReady() -> (c: CascadeServer, st: CascSrvState, status: JObj)? {
        if let r = ready { return r }
        XuiDialog.info(sel == nil ? "Сначала добавь каскад-сервер: «＋ Сервер…»"
                                  : "Каскад на сервере не установлен (или старой версии) — «Установить…»", title: "Каскад")
        return nil
    }

    /// Заменить источник oldName (на его месте) или добавить новый.
    private static func upsert(_ list: inout [CascadeSource], _ src: CascadeSource, _ oldName: String?) throws {
        if list.contains(where: { $0.name == src.name && $0.name != oldName }) { throw XuiError("источник «\(src.name)» уже есть") }
        if let old = oldName, let i = list.firstIndex(where: { $0.name == old }) { list[i] = src } else { list.append(src) }
    }

    /// Источники целиком с сервера → правка → запись (сервер проверяет сам). В работу — по «Применить».
    @discardableResult
    private func mutate(_ title: String, env: [(String, String)] = [], _ change: @escaping (inout [CascadeSource]) throws -> String) async -> Bool {
        await op(title) { c, r in
            var list = try await r.sources()
            let msg = try change(&list)
            try await r.saveSources(list)
            if !env.isEmpty { try await r.set(env) }
            self.states[c.id]?.pending = true
            self.log("  ✓ \(msg) — в работу по «Применить»", .ok)
        }
    }

    // MARK: добавить

    func addXuiSource() async {
        guard let r0 = sourcesReady() else { return }
        guard let src = await askXuiSource(XuiSourceRequest(server: r0.c.name, edit: nil, taken: taken(shownSources))) else { return }
        await mutate("Источник \(src.name)") { list in try Self.upsert(&list, src, nil); return "источник «\(src.name)»: \(src.origin)" }
    }

    func addLinkSource() async {
        guard sourcesReady() != nil else { return }
        let t = taken(shownSources)
        guard let src = CascadeLinkForm.ask(edit: nil, taken: t, defName: Self.freeName("SUB", t)) else { return }
        await mutate("Источник \(src.name)") { list in try Self.upsert(&list, src, nil); return "источник «\(src.name)»: ссылка подписки" }
    }

    func addWgSource() async {
        guard let r0 = sourcesReady() else { return }
        guard let res = await askWgSource(WgSourceRequest(server: r0.c.name, edit: nil, isReserve: reserve.isEmpty, taken: taken(shownSources))) else { return }
        let src = res.source
        await mutate("Источник \(src.name)", env: res.reserve ? [("QC_RESERVE", src.name)] : []) { list in
            try Self.upsert(&list, src, nil)
            return "источник «\(src.name)»: \(src.origin)" + (res.reserve ? " · резерв" : "")
        }
    }

    // MARK: изменить / вкл-выкл / удалить

    func editSource(_ name: String? = nil) async {
        guard let r0 = sourcesReady() else { return }
        guard let pick = name ?? sourceSel else { XuiDialog.info("Выбери источник в списке", title: "Каскад"); return }
        if busy { log("! дождись окончания текущей операции", .warn); return }
        let full: [CascadeSource]
        do { full = try await remote(r0.c).sources() } catch { log("✗ " + error.localizedDescription, .err); return }
        guard let cur = full.first(where: { $0.name == pick }) else {
            XuiDialog.info("Этого источника на сервере уже нет — список обновлён", title: "Каскад")
            await refresh()
            return
        }
        let t = taken(full)
        let res = reserve
        var upd: CascadeSource?
        var newReserve: String?
        switch cur.kind {
        case "xui":
            upd = await askXuiSource(XuiSourceRequest(server: r0.c.name, edit: cur, taken: t))
        case "awg", "conf":
            if let w = await askWgSource(WgSourceRequest(server: r0.c.name, edit: cur, isReserve: res == cur.name, taken: t)) {
                upd = w.source
                let want = w.reserve ? w.source.name : (res == cur.name ? "" : res)
                if want != res { newReserve = want }
            }
        default:
            upd = CascadeLinkForm.ask(edit: cur, taken: t, defName: cur.name)
        }
        guard let upd else { return }
        if newReserve == nil && res == cur.name && upd.name != cur.name { newReserve = upd.name }   // переименовали резерв
        await mutate("Источник \(cur.name)", env: newReserve.map { [("QC_RESERVE", $0)] } ?? []) { list in
            try Self.upsert(&list, upd, cur.name)
            return "источник «\(upd.name)» сохранён"
        }
    }

    func toggleSource() async {
        guard sourcesReady() != nil else { return }
        guard let pick = sourceSel, let row = shownSources.first(where: { $0.name == pick }) else {
            XuiDialog.info("Выбери источник в списке", title: "Каскад"); return
        }
        let on = !row.enabled
        await mutate("Источник \(pick): \(on ? "включить" : "выключить")") { list in
            guard let i = list.firstIndex(where: { $0.name == pick }) else { throw XuiError("этого источника на сервере уже нет") }
            list[i].enabled = on
            return "«\(pick)» \(on ? "включён" : "выключен")"
        }
    }

    func deleteSource() async {
        guard sourcesReady() != nil else { return }
        guard let pick = sourceSel, let src = shownSources.first(where: { $0.name == pick }) else {
            XuiDialog.info("Выбери источник в списке", title: "Каскад"); return
        }
        let panel = store.panels().first { $0.id.lowercased() == src.panelId && !src.panelId.isEmpty }
        let choice: Int
        if src.kind == "xui", let p = panel {
            choice = XuiDialog.choose("Удалить источник «\(src.name)»?\n\nКлиент каскада \(src.m("client")) на панели «\(p.name)» можно удалить заодно — если его подписка больше нигде не нужна.",
                                      title: "Удалить источник", ["Удалить и клиента на панели", "Только источник", "Отмена"])
        } else if src.kind == "awg", let p = panel {
            choice = XuiDialog.choose("Удалить источник «\(src.name)»?\n\nКлиента \(src.m("client")) AWG-панели «\(p.name)» можно удалить заодно.",
                                      title: "Удалить источник", ["Удалить и клиента AWG", "Только источник", "Отмена"])
        } else {
            choice = XuiDialog.confirm("Удалить источник «\(src.name)»?", title: "Удалить источник", yes: "Удалить") ? 1 : -1
        }
        if choice < 0 || choice == 2 { return }
        let wasReserve = reserve == src.name
        let ok = await mutate("Удалить источник \(src.name)", env: wasReserve ? [("QC_RESERVE", "")] : []) { list in
            list.removeAll { $0.name == src.name }
            return "источник «\(src.name)» удалён" + (wasReserve ? ", резерв выключен" : "")
        }
        guard ok, choice == 0, let p = panel else { return }
        do {
            if src.kind == "xui" {
                let api = try XuiAPI.forPanel(p)
                try await api.deleteClient(src.m("client"))
                log("  ✓ клиент \(src.m("client")) удалён с «\(p.name)»", .ok)
            } else {
                let api = try Awg.api(p)
                var id = src.m("clientId")
                if id.isEmpty { id = try await api.clients(p).first(where: { $0.name == src.m("client") })?.cid ?? "" }
                if id.isEmpty { throw XuiError("клиента \(src.m("client")) на «\(p.name)» нет") }
                try await api.delete(id)
                log("  ✓ клиент AWG \(src.m("client")) удалён с «\(p.name)»", .ok)
            }
        } catch { log("✗ клиент не удалён: " + error.localizedDescription, .err) }
    }
}

// MARK: - Ссылка подписки (форма)

enum CascadeLinkForm {
    @MainActor
    static func ask(edit: CascadeSource?, taken: Set<String>, defName: String) -> CascadeSource? {
        var name = edit?.name ?? defName, url = edit?.url ?? "", prefix = edit?.prefix ?? ""
        while true {
            guard let f = XuiDialog.form(
                "Clash/Mihomo-ссылка подписки — например, подписка отдельной ноды. Уйдёт только на сервер (/etc/qcascade, 600), " +
                "в QTerm не хранится. Одинаковые имена нод из разных источников разводит префикс.",
                title: edit == nil ? "Источник: ссылка подписки" : "Источник «\(edit!.name)»",
                [.init(label: "Имя источника (латиница, цифры, . _ -)", value: name),
                 .init(label: "Ссылка Clash / Mihomo", value: url, secure: true),
                 .init(label: "Префикс имён нод (необязательно)", value: prefix)],
                ok: edit == nil ? "Добавить" : "Сохранить") else { return nil }
            name = f[0].trimmingCharacters(in: .whitespaces)
            url = f[1].trimmingCharacters(in: .whitespaces)
            prefix = f[2].trimmingCharacters(in: .whitespaces)
            var err: String?
            if !CascadeSource.validName(name) { err = "имя источника — латиница, цифры, . _ - (до 32 знаков)" }
            else if name != edit?.name && taken.contains(name) { err = "источник «\(name)» уже есть" }
            else if !(url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://")) { err = "нужна http(s)-ссылка подписки" }
            else if !CascadeSource.validPrefix(prefix) { err = "префикс — латиница, цифры, . _ - (до 16)" }
            if let err { XuiDialog.info(err, title: "Источник"); continue }
            var s = edit ?? CascadeSource()
            s.name = name
            s.type = "sub"
            s.url = url
            s.prefix = prefix
            if edit == nil || edit!.kind != "link" { s.meta = ["kind": "link"] }
            return s
        }
    }
}

// MARK: - Свой клиент каскада на панели 3x-ui

@MainActor
final class XuiSourceVM: ObservableObject {
    let req: XuiSourceRequest
    let panels: [XuiPanel]
    private let log: (String) -> Void
    @Published var panelId = ""
    @Published var newClient = true
    @Published var newName = ""
    @Published var oldName = ""
    @Published var name = ""
    @Published var prefix = ""
    @Published var inbounds: [XInbound] = []
    @Published var nodes: [XNode] = []
    @Published var clients: [XClient] = []
    @Published var checked = Set<Int>()
    @Published var status = ""
    @Published var busy = false
    private var api: XuiAPI?
    /// Перенос выбора с ноды на её главную (см. moveToMaster): применяется, когда главная загрузится.
    private var carry: (masterId: String, nodeId: Int, nodeName: String, fromName: String, picked: Set<String>, email: String)?
    /// pickOld от программной смены клиента (перенос) не должен перетирать отмеченные инбаунды.
    private var suppressPick = false

    var panel: XuiPanel? { panels.first { $0.id == panelId } }
    var isEdit: Bool { req.edit != nil }

    init(req: XuiSourceRequest, store: XuiStore, log: @escaping (String) -> Void) {
        self.req = req
        self.log = log
        panels = store.panels().filter { $0.isXui && !$0.token.isEmpty }
        let slug = String(req.server.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(24))
        newName = req.edit?.m("client") ?? "CASC-\(slug.isEmpty ? "CASCADE" : slug)"
        name = req.edit?.name ?? ""
        prefix = req.edit?.prefix ?? ""
        if let e = req.edit {
            panelId = panels.first { $0.id.lowercased() == e.panelId }?.id ?? ""
            newClient = false
            oldName = e.m("client")
        } else {
            panelId = (panels.first { $0.isMaster } ?? panels.first)?.id ?? ""
        }
    }

    struct IbGroup: Identifiable {
        let id: String
        let items: [XInbound]
    }

    /// Инбаунды по серверам: сама панель, потом узлы.
    var groups: [IbGroup] {
        let multi = inbounds.filter(\.multiUser)
        var keys: [Int?] = []
        for ib in multi where !keys.contains(where: { $0 == ib.nodeId }) { keys.append(ib.nodeId) }
        func title(_ k: Int?) -> String {
            guard let k else { return panel?.name ?? "панель" }
            return nodes.first { $0.id == k }?.name ?? "узел \(k)"
        }
        func sortKey(_ k: Int?) -> String { k == nil ? "" : title(k) }
        let ordered = keys.sorted { sortKey($0).localizedCaseInsensitiveCompare(sortKey($1)) == .orderedAscending }
        return ordered.map { k in
            IbGroup(id: title(k),
                    items: multi.filter { $0.nodeId == k }.sorted { $0.remark.localizedCaseInsensitiveCompare($1.remark) == .orderedAscending })
        }
    }

    func load() async {
        guard let p = panel else {
            status = panels.isEmpty ? "✗ в QTerm нет панелей 3x-ui с токеном — «Ноды 3x-ui» → «Панели и токены…»"
                                    : isEdit ? "✗ панели «\(req.edit?.m("panelName") ?? "")» больше нет в QTerm" : ""
            return
        }
        busy = true
        defer { busy = false }
        status = "загружаю «\(p.name)»…"
        do {
            let a = try XuiAPI.forPanel(p)
            api = a
            inbounds = try await a.inbounds()
            nodes = p.isMaster ? ((try? await a.nodes()) ?? []) : []
            clients = try await a.clients()
            if isEdit {
                if let cl = clients.first(where: { $0.email == oldName }) { checked = Set(cl.inboundIds); status = "" }
                else { status = "! клиента \(oldName) на панели нет — сохранение создаст его заново" }
            } else {
                checked = []
                status = ""
            }
            if name.isEmpty {
                let base = String(p.name.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }.prefix(24))
                var n = base.isEmpty ? "SRC" : base
                if req.taken.contains(n) { var i = 2; while req.taken.contains("\(n)-\(i)") { i += 1 }; n = "\(n)-\(i)" }
                name = n
            }
            if let c = carry, c.masterId == p.id { applyCarry(c) }
        } catch { status = "✗ " + error.localizedDescription }
        carry = nil
    }

    /// Главная, у которой эта панель — узел (3x-ui v3): по адресу узла, потом по имени.
    private func findMaster(of p: XuiPanel) async -> (master: XuiPanel, node: XNode)? {
        guard let u = PanelURL.tryParse(p.url) else { return nil }
        let pn = p.name.trimmingCharacters(in: .whitespaces)
        // сначала помеченные главными, потом остальные панели 3x-ui: роль в QTerm могли и не выставить
        for m in panels.filter({ $0.id != p.id }).sorted(by: { $0.isMaster && !$1.isMaster }) {
            guard let a = try? XuiAPI.forPanel(m), let nodes = try? await a.nodes() else { continue }
            let n = nodes.first { u.sameAs($0.address, $0.port, $0.basePath) }
                ?? nodes.first { $0.address.caseInsensitiveCompare(u.host) == .orderedSame }
                ?? nodes.first { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(pn) == .orderedSame }
            if let n { return (m, n) }
        }
        return nil
    }

    /// Переносит выбор на главную: те же серверы — инбаунды узла на главной (по протоколу и порту), тот же клиент.
    /// Ничего не создаёт — видно, что отмечено, кнопку жмут сами.
    private func moveToMaster(from node: XuiPanel, to master: XuiPanel, _ n: XNode, ids: [Int], email: String) {
        let picked = Set(inbounds.filter { ids.contains($0.id) }.map { "\($0.proto):\($0.port)" })
        carry = (master.id, n.id, n.name, node.name, picked, email)
        panelId = master.id          // смена панели перезагрузит её (onChange) — выбор применит load()
    }

    private func applyCarry(_ c: (masterId: String, nodeId: Int, nodeName: String, fromName: String, picked: Set<String>, email: String)) {
        let onNode = inbounds.filter { $0.multiUser && $0.nodeId == c.nodeId }
        var sel = Set(onNode.filter { c.picked.contains("\($0.proto):\($0.port)") }.map(\.id))
        if sel.isEmpty { sel = Set(onNode.map(\.id)) }
        let exists = clients.contains { $0.email == c.email }
        if exists {
            if oldName != c.email { suppressPick = true; oldName = c.email }
            newClient = false
        } else {
            newName = c.email
            newClient = true
        }
        checked = sel
        status = "→ «\(c.fromName)» — узел главной «\(panel?.name ?? "")», Clash-подписку отдаёт главная. Перенёс сюда: отмечены инбаунды " +
            "\(c.nodeName) (\(sel.count)), клиент \(c.email)\(exists ? "" : " (будет создан)"). Проверь и жми «Создать и добавить»."
    }

    func pickOld(_ em: String) {
        if suppressPick { suppressPick = false; return }
        guard !isEdit, let cl = clients.first(where: { $0.email == em }) else { return }
        newClient = false
        checked = Set(cl.inboundIds)
    }

    func ok() async -> CascadeSource? {
        guard !busy, let a = api, let p = panel else { return nil }
        let nm = name.trimmingCharacters(in: .whitespaces)
        let pf = prefix.trimmingCharacters(in: .whitespaces)
        let ids = inbounds.filter { $0.multiUser && checked.contains($0.id) }.map(\.id)
        let email = (newClient ? newName : oldName).trimmingCharacters(in: .whitespaces)
        var err: String?
        if !CascadeSource.validName(nm) { err = "имя источника — латиница, цифры, . _ - (до 32 знаков)" }
        else if nm != req.edit?.name && req.taken.contains(nm) { err = "источник «\(nm)» уже есть" }
        else if !CascadeSource.validPrefix(pf) { err = "префикс — латиница, цифры, . _ - (до 16)" }
        else if ids.isEmpty { err = "отметь хотя бы один инбаунд" }
        else if email.isEmpty { err = newClient ? "введи имя нового клиента" : "выбери клиента" }
        if let err { status = "✗ " + err; return nil }

        // Clash-подписку проверяем ДО правок на панели: иначе клиент уже привязан, а источника нет
        busy = true
        status = "проверяю подписку панели…"
        let st: JObj
        do { st = try await a.settings() } catch { busy = false; status = "✗ " + error.localizedDescription; return nil }
        if XuiAPI.subLink(st, a.url, "x", clash: true) == nil {
            // у ноды своя подписка выключена, а клиентам её отдаёт главная (узлы 3x-ui v3) — источник делаем там
            if let f = await findMaster(of: p) {
                busy = false
                moveToMaster(from: p, to: f.master, f.node, ids: ids, email: email)
                return nil
            }
            busy = false
            status = "✗ в «\(p.name)» выключена Clash/Mihomo-подписка: Настройки панели → Подписка → Clash — включить " +
                "(или выбери главную панель, если эта нода — её узел: там её инбаунды тоже есть)"
            return nil
        }
        busy = false
        status = ""

        var cl = clients.first { $0.email == email }
        let own = req.edit?.m("client") == email
        if cl != nil && newClient &&
            !XuiDialog.confirm("Клиент «\(email)» уже есть на «\(p.name)» — взять его? Его инбаунды приведутся к отмеченным.", title: "Источник", yes: "Взять") {
            return nil
        }
        if let c = cl, !own {
            let del = c.inboundIds.filter { !ids.contains($0) }
            if !del.isEmpty && !XuiDialog.confirm("«\(email)» отвяжется от \(del.count) инбаунд(ов) — его другие устройства их потеряют. Продолжить?",
                                                  title: "Источник", yes: "Продолжить") { return nil }
        }
        busy = true
        defer { busy = false }
        status = "работаю с панелью…"
        do {
            if let c = cl {
                let add = ids.filter { !c.inboundIds.contains($0) }
                let del = c.inboundIds.filter { !ids.contains($0) }
                if !add.isEmpty { try await a.attach(email, add) }
                if !del.isEmpty { try await a.detach(email, del) }
                if !add.isEmpty || !del.isEmpty { log("  ✓ \(email) на «\(p.name)»: +\(add.count) / −\(del.count) инбаундов") }
            } else {
                try await a.addClient(email, ids)
                log("  ✓ клиент каскада \(email) создан на «\(p.name)»: инбаундов \(ids.count)")
            }
            clients = try await a.clients()
            cl = clients.first { $0.email == email }
            guard var c = cl else { throw XuiError("клиент \(email) не нашёлся на панели после создания — обнови и выбери его как существующего") }
            if c.subId.isEmpty {
                let sid = (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                try await a.updateClient(email, XuiAPI.clientPayload(c, subId: sid))
                clients = try await a.clients()
                guard let c2 = clients.first(where: { $0.email == email }) else { throw XuiError("клиент \(email) пропал с панели") }
                c = c2
            }
            guard let link = XuiAPI.subLink(st, a.url, c.subId, clash: true) else {
                throw XuiError("в панели «\(p.name)» выключена Clash/Mihomo-подписка: Настройки панели → Подписка → Clash — включить")
            }
            var src = req.edit ?? CascadeSource()
            src.name = nm
            src.type = "sub"
            src.url = link
            src.conf = ""
            src.prefix = pf
            src.meta = ["kind": "xui", "panel": p.id, "panelName": p.name, "client": email, "inbounds": ids]
            status = ""
            return src
        } catch {
            status = "✗ " + error.localizedDescription
            return nil
        }
    }
}

struct XuiSourceSheet: View {
    @StateObject private var vm: XuiSourceVM
    let finish: (CascadeSource?) -> Void

    init(req: XuiSourceRequest, store: XuiStore, log: @escaping (String) -> Void, finish: @escaping (CascadeSource?) -> Void) {
        _vm = StateObject(wrappedValue: XuiSourceVM(req: req, store: store, log: log))
        self.finish = finish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.isEdit ? "Источник «\(vm.req.edit?.name ?? "")»" : "Источник: клиент каскада на панели 3x-ui").font(.title3.bold())
            Text("Свой клиент каскада на панели 3x-ui: его Clash-подписка с отмеченными инбаундами станет источником нод — в каскад попадут " +
                 "ровно эти серверы. Единая подписка клиентов не меняется. Панель — главная (инбаунды всех её узлов) или отдельная нода; " +
                 "клиентов каскада может быть сколько угодно, на разных панелях.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            fields
            HStack {
                Text("Инбаунды — какие серверы попадут в подписку каскада:").foregroundStyle(.secondary)
                Spacer()
                Button("Все") { vm.checked = Set(vm.inbounds.filter(\.multiUser).map(\.id)) }
                Button("Ни одного") { vm.checked = [] }
            }
            inboundList
            Text(vm.status).foregroundStyle(vm.status.hasPrefix("✗") ? .red : .secondary).textSelection(.enabled)
            HStack {
                if vm.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button(vm.isEdit ? "Сохранить" : "Создать и добавить") {
                    Task { if let s = await vm.ok() { finish(s) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.busy || vm.panel == nil)
            }
        }
        .padding(16)
        .frame(width: 740, height: 660)
        .task { await vm.load() }
        .onChange(of: vm.panelId) { _, _ in Task { await vm.load() } }
        .onChange(of: vm.oldName) { _, v in vm.pickOld(v) }
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Панель").foregroundStyle(.secondary)
                Picker("", selection: $vm.panelId) {
                    if vm.panels.isEmpty { Text("—").tag("") }
                    ForEach(vm.panels) { Text($0.display).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 320)
                .disabled(vm.isEdit)
            }
            GridRow {
                Text("Клиент").foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: $vm.newClient) {
                        Text("новый").tag(true)
                        Text("существующий").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .disabled(vm.isEdit)
                    if vm.newClient {
                        TextField("имя клиента", text: $vm.newName).textFieldStyle(.roundedBorder).frame(width: 220)
                    } else {
                        Picker("", selection: $vm.oldName) {
                            Text("—").tag("")
                            ForEach(vm.clients.map(\.email).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden().frame(width: 240)
                        .disabled(vm.isEdit)
                    }
                }
            }
            GridRow {
                Text("Имя источника").foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $vm.name).textFieldStyle(.roundedBorder).frame(width: 200)
                    Text("префикс нод").foregroundStyle(.secondary)
                    TextField("", text: $vm.prefix).textFieldStyle(.roundedBorder).frame(width: 110)
                }
            }
        }
    }

    private var inboundList: some View {
        List {
            ForEach(vm.groups) { g in
                Section(g.id) {
                    ForEach(g.items) { ib in
                        Toggle("\(ib.remark)   ·   \(ib.proto):\(ib.port)\(ib.enable ? "" : "   · выключен")", isOn: Binding(
                            get: { vm.checked.contains(ib.id) },
                            set: { on in if on { vm.checked.insert(ib.id) } else { vm.checked.remove(ib.id) } }))
                    }
                }
            }
        }
        .frame(minHeight: 240)
    }
}

// MARK: - WireGuard / AWG

@MainActor
final class WgSourceVM: ObservableObject {
    let req: WgSourceRequest
    let panels: [XuiPanel]
    private let log: (String) -> Void
    @Published var name = ""
    @Published var fromPanel = true
    @Published var panelId = ""
    @Published var ifaces: [AwgInterface] = []
    @Published var ifaceName = ""
    @Published var clients: [AwgClient] = []
    @Published var newClient = true
    @Published var newName = ""
    @Published var oldId = ""
    @Published var conf = ""
    @Published var reserve = false
    @Published var status = ""
    @Published var busy = false

    var panel: XuiPanel? { panels.first { $0.id == panelId } }
    var isEdit: Bool { req.edit != nil }

    init(req: WgSourceRequest, store: XuiStore, log: @escaping (String) -> Void) {
        self.req = req
        self.log = log
        panels = store.panels().filter(\.isAwg)
        let slug = String(req.server.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(24))
        var n = req.edit?.name ?? "WG"
        if req.edit == nil && req.taken.contains(n) { var i = 2; while req.taken.contains("WG-\(i)") { i += 1 }; n = "WG-\(i)" }
        name = n
        newName = req.edit.map { $0.m("client") }.flatMap { $0.isEmpty ? nil : $0 } ?? "casc-\(slug.isEmpty ? "cascade" : slug)"
        reserve = req.isReserve
        if let e = req.edit, e.kind == "awg", let p = panels.first(where: { $0.id.lowercased() == e.panelId }) {
            panelId = p.id
            newClient = false
            oldId = e.m("clientId")
        } else if req.edit != nil || panels.isEmpty {
            fromPanel = false
            conf = req.edit?.kind == "conf" ? req.edit!.conf : ""
            panelId = panels.first?.id ?? ""
        } else {
            panelId = panels.first?.id ?? ""
        }
    }

    func load() async {
        guard fromPanel, let p = panel else {
            if fromPanel && panels.isEmpty { status = "✗ в QTerm нет AWG-панелей — «Ноды 3x-ui» → «Панели и токены…» (роль «AWG-панель»), или готовый .conf" }
            return
        }
        busy = true
        defer { busy = false }
        status = "загружаю «\(p.name)»…"
        do {
            let api = try Awg.api(p)
            ifaces = try await api.interfaces().filter(\.enabled)
            clients = try await api.clients(p)
            if !ifaces.contains(where: { $0.name == ifaceName }) { ifaceName = ifaces.first?.name ?? "" }
            if isEdit, let e = req.edit, e.kind == "awg" {
                oldId = clients.first(where: { $0.cid == e.m("clientId") })?.cid ?? clients.first(where: { $0.name == e.m("client") })?.cid ?? ""
            }
            status = ""
        } catch { status = "✗ " + error.localizedDescription }
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Конфиг WireGuard / AWG"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            conf = try String(contentsOf: url, encoding: .utf8)
            if name == "WG" || name.hasPrefix("WG-") || name.isEmpty {
                let base = String(url.deletingPathExtension().lastPathComponent.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }.prefix(24))
                if !base.isEmpty && !req.taken.contains(base) { name = base }
            }
        } catch { status = "✗ " + error.localizedDescription }
    }

    func ok() async -> (source: CascadeSource, reserve: Bool)? {
        guard !busy else { return nil }
        let nm = name.trimmingCharacters(in: .whitespaces)
        if !CascadeSource.validName(nm) { status = "✗ имя источника — латиница, цифры, . _ - (до 32 знаков)"; return nil }
        if nm != req.edit?.name && req.taken.contains(nm) { status = "✗ источник «\(nm)» уже есть"; return nil }
        var src = req.edit ?? CascadeSource()
        src.name = nm
        src.type = "wg"
        src.url = ""
        src.prefix = ""
        if !fromPanel {
            let c = conf.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            if let e = CascadeSource.checkWgConf(c) { status = "✗ конфиг: " + e; return nil }
            src.conf = c
            src.meta = ["kind": "conf"]
            return (src, reserve)
        }
        guard let p = panel else { status = "✗ выбери AWG-панель"; return nil }
        let cname = newClient ? newName.trimmingCharacters(in: .whitespaces) : (clients.first { $0.cid == oldId }?.name ?? "")
        if cname.isEmpty { status = newClient ? "✗ введи имя клиента" : "✗ выбери клиента"; return nil }
        if newClient, clients.contains(where: { $0.name == cname }),
           !XuiDialog.confirm("Клиент «\(cname)» уже есть на «\(p.name)» — взять его конфиг?", title: "Источник", yes: "Взять") { return nil }
        busy = true
        defer { busy = false }
        status = "работаю с AWG-панелью…"
        do {
            let api = try Awg.api(p)
            var cl = newClient ? clients.first(where: { $0.name == cname }) : clients.first(where: { $0.cid == oldId })
            if cl == nil {
                try await api.create(cname, interfaceId: p.isAwgLegacy || ifaceName.isEmpty ? nil : ifaceName)
                clients = try await api.clients(p)
                cl = clients.last { $0.name == cname }
                guard cl != nil else { throw XuiError("клиент \(cname) не нашёлся на панели после создания") }
                log("  ✓ клиент AWG \(cname) создан на «\(p.name)»\(ifaceName.isEmpty ? "" : " · " + ifaceName)")
            }
            let c = cl!
            let text = try await api.config(c.cid).replacingOccurrences(of: "\r\n", with: "\n")
            if let e = CascadeSource.checkWgConf(text) { throw XuiError("панель отдала странный конфиг: " + e) }
            var t = text
            while t.hasSuffix("\n") { t.removeLast() }
            src.conf = t + "\n"
            src.meta = ["kind": "awg", "panel": p.id, "panelName": p.name, "client": c.name, "clientId": c.cid, "iface": c.interfaceId]
            status = ""
            return (src, reserve)
        } catch {
            status = "✗ " + error.localizedDescription
            return nil
        }
    }
}

struct WgSourceSheet: View {
    @StateObject private var vm: WgSourceVM
    let finish: ((source: CascadeSource, reserve: Bool)?) -> Void

    init(req: WgSourceRequest, store: XuiStore, log: @escaping (String) -> Void,
         finish: @escaping ((source: CascadeSource, reserve: Bool)?) -> Void) {
        _vm = StateObject(wrappedValue: WgSourceVM(req: req, store: store, log: log))
        self.finish = finish
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.isEdit ? "Источник «\(vm.req.edit?.name ?? "")»" : "Источник: WireGuard / AWG").font(.title3.bold())
            Text("Выход WireGuard / AmneziaWG (2.0 и 3.x) из каскада — клиент AWG-панели другой ноды (QTerm создаст его и заберёт конфиг сам) " +
                 "или готовый .conf. Конфиг уйдёт только на сервер (/etc/qcascade, 600).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Имя источника").foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                TextField("", text: $vm.name).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            Picker("", selection: $vm.fromPanel) {
                Text("клиент AWG-панели").tag(true)
                Text("готовый конфиг .conf").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            if vm.fromPanel { panelPart } else { confPart }
            Toggle("резерв: все ноды группы недоступны — всё, что не DIRECT, идёт через этот туннель", isOn: $vm.reserve)
            Text(vm.status).foregroundStyle(vm.status.hasPrefix("✗") ? .red : .secondary).textSelection(.enabled)
            Spacer(minLength: 0)
            HStack {
                if vm.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button(vm.isEdit ? "Сохранить" : "Добавить") {
                    Task { if let r = await vm.ok() { finish(r) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(vm.busy)
            }
        }
        .padding(16)
        .frame(width: 700, height: 600)
        .task { await vm.load() }
        .onChange(of: vm.panelId) { _, _ in Task { await vm.load() } }
        .onChange(of: vm.fromPanel) { _, v in if v && vm.clients.isEmpty { Task { await vm.load() } } }
    }

    private var panelPart: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("AWG-панель").foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: $vm.panelId) {
                        if vm.panels.isEmpty { Text("—").tag("") }
                        ForEach(vm.panels) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 220)
                    Text("интерфейс").foregroundStyle(.secondary)
                    Picker("", selection: $vm.ifaceName) {
                        if vm.ifaces.isEmpty { Text("—").tag("") }
                        ForEach(vm.ifaces, id: \.name) { Text($0.label).tag($0.name) }
                    }
                    .labelsHidden().frame(width: 200)
                }
            }
            GridRow {
                Text("Клиент").foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: $vm.newClient) {
                        Text("новый").tag(true)
                        Text("существующий").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    if vm.newClient {
                        TextField("имя клиента", text: $vm.newName).textFieldStyle(.roundedBorder).frame(width: 200)
                    } else {
                        Picker("", selection: $vm.oldId) {
                            Text("—").tag("")
                            ForEach(vm.clients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, id: \.cid) {
                                Text($0.name).tag($0.cid)
                            }
                        }
                        .labelsHidden().frame(width: 220)
                    }
                }
            }
        }
        .padding(.leading, 12)
    }

    private var confPart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Открыть файл…") { vm.openFile() }
                Text("или вставь текст конфига:").foregroundStyle(.secondary)
            }
            TextEditor(text: $vm.conf)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 170)
                .border(Color.secondary.opacity(0.3))
        }
        .padding(.leading, 12)
    }
}

// MARK: - Первая установка: источники и кого пускать — одним листом

struct InstallSheet: View {
    let req: InstallRequest
    let store: XuiStore
    let log: (String) -> Void
    let finish: ((sources: [CascadeSource], env: [(String, String)])?) -> Void
    @State private var sources: [CascadeSource] = []
    @State private var reserve = ""
    @State private var xray = true
    @State private var awg = true
    @State private var mtp = true
    @State private var sel: String?
    @State private var status = ""
    @State private var xuiReq: XuiSourceRequest?
    @State private var wgReq: WgSourceRequest?

    private var taken: Set<String> { Set(sources.map(\.name)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Установка каскада · \(req.server.name)").font(.title3.bold())
            Text("1. Источники нод — минимум один. Лучше свой клиент каскада на панели 3x-ui с нужным набором серверов (единая подписка " +
                 "клиентов не трогается), можно и подписки отдельных нод, и WireGuard/AWG (например, резервом).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("＋ Клиент на панели 3x-ui…") { xuiReq = XuiSourceRequest(server: req.server.name, edit: nil, taken: taken) }
                Button("＋ Ссылка подписки…") {
                    var n = "SUB"
                    if taken.contains(n) { var i = 2; while taken.contains("SUB-\(i)") { i += 1 }; n = "SUB-\(i)" }
                    if let s = CascadeLinkForm.ask(edit: nil, taken: taken, defName: n) { sources.append(s) }
                }
                Button("＋ WireGuard / AWG…") { wgReq = WgSourceRequest(server: req.server.name, edit: nil, isReserve: reserve.isEmpty, taken: taken) }
                Button("Убрать") {
                    guard let s = sel else { return }
                    sources.removeAll { $0.name == s }
                    if reserve == s { reserve = "" }
                }
                .disabled(sel == nil)
            }
            List(selection: $sel) {
                ForEach(sources) { s in
                    Text("\(s.name)   ·   \(s.origin)\(s.name == reserve ? "   · резерв" : "")").tag(s.name)
                }
            }
            .frame(minHeight: 150)
            Text("2. Кого сразу пустить через каскад (поменять можно потом — «Кто идёт в каскад»). Чего на сервере нет — пропустится само.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("клиенты 3x-ui этого сервера (VLESS, Hysteria, встроенный AWG)", isOn: $xray)
            Toggle("клиенты AWG-панели этого сервера (интерфейсы wg* / awg*)", isOn: $awg)
            Toggle("MTProto-прокси этого сервера (mtg, teleproxy, telemt, WEB): Telegram — по правилам TG", isOn: $mtp)
            Text(status).foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Отмена") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Установить") {
                    if sources.isEmpty { status = "✗ нужен хотя бы один источник нод"; return }
                    finish((sources, [("QC_XRAY_MODE", xray ? "all" : "off"), ("QC_XRAY_LIST", ""),
                                      ("QC_AWG_MODE", awg ? "all" : "off"), ("QC_MTP", mtp ? "on" : "off"),
                                      ("QC_RESERVE", reserve)]))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 760, height: 620)
        .sheet(item: $xuiReq) { r in
            XuiSourceSheet(req: r, store: store, log: log) { s in xuiReq = nil; if let s { sources.append(s) } }
        }
        .sheet(item: $wgReq) { r in
            WgSourceSheet(req: r, store: store, log: log) { res in
                wgReq = nil
                if let res { sources.append(res.source); if res.reserve { reserve = res.source.name } }
            }
        }
    }
}
