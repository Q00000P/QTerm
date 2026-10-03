import SwiftUI
import AppKit

// Состояние окна «Ноды 3x-ui»: главная + её узлы (встроенный мультинод 3x-ui v3), AWG-панели.
// Порт XuiWindow.xaml.cs / XuiWindow.Awg.cs.

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let kind: LogKind
    var color: Color {
        switch kind {
        case .ok: return .green
        case .warn: return .orange
        case .err: return .red
        case .head: return .accentColor
        case .dim: return .secondary
        case .info: return .primary
        }
    }
}

struct ServerCol: Identifiable {
    let id: String
    let title: String
    let nodeId: Int?
    let index: Int
}

struct ClientRow: Identifiable {
    var id: String { src.email }
    let src: XClient
    let dot: Color
    let merged: Bool
    let enabled: String
    let traffic: String
    let expiry: String
    let cells: [(String, Color)]
    var email: String { src.email }
    var subId: String { src.subId }
}

struct MonRow: Identifiable {
    let id: String
    let name: String
    let status: String
    let statusColor: Color
    let ping, cpu, ram, uptime, xray, clients, net, error: String
}

struct NodeRow: Identifiable {
    var id: Int { src.id }
    let src: XNode
    let saved: XuiPanel?
    let status: String
    let statusColor: Color
    var name: String { src.name }
    var address: String { "\(src.scheme)://\(src.address):\(src.port)\(src.basePath == "/" || src.basePath.isEmpty ? "" : src.basePath)" }
}

struct AwgRow: Identifiable {
    var id: String { src.id }
    let src: AwgClient
    let iface: String
    let handshake: String
    let traffic: String
    let dot: Color
}

/// Запрос плана с галками (лист в окне), ответ — через continuation.
final class PlanRequest: Identifiable {
    let id = UUID()
    let title: String
    let summary: String
    let note: String
    let items: [PlanItem]
    let resultHeader: String
    let fromHeader: String
    let forceApply: Bool
    var done: ((Bool) -> Void)?

    init(title: String, summary: String, note: String, items: [PlanItem], resultHeader: String = "Итоговое имя",
         fromHeader: String = "Сейчас (записи)", forceApply: Bool = false) {
        self.title = title; self.summary = summary; self.note = note; self.items = items
        self.resultHeader = resultHeader; self.fromHeader = fromHeader; self.forceApply = forceApply
    }
}

/// Адрес + токен ноды (подключение / ревизия / токен).
final class ConnectRequest: Identifiable {
    let id = UUID()
    let saved: [XuiPanel]
    let url: String
    let name: String
    let tokenOnly: Bool
    var done: ((ConnectResult?) -> Void)?
    init(saved: [XuiPanel], url: String = "", name: String = "", tokenOnly: Bool = false) {
        self.saved = saved; self.url = url; self.name = name; self.tokenOnly = tokenOnly
    }
}

struct ConnectResult {
    var url: String
    var token: String
    var verifyTls: Bool
    var name: String?
    var attachOthers: Bool
    var saveToken: Bool
}

@MainActor
final class XuiModel: ObservableObject {
    enum Seg: String, CaseIterable, Identifiable {
        case monitor = "Монитор", clients = "Клиенты", nodes = "Узлы", names = "Ревизия имён", awg = "AWG"
        var id: String { rawValue }
    }

    // хранилище
    var store: XuiStore { XuiCenter.shared.store! }

    @Published var masters: [XuiPanel] = []
    @Published var masterId: String = "" { didSet { if oldValue != masterId { masterChanged() } } }
    @Published var seg: Seg = .monitor { didSet { if seg == .awg && oldValue != .awg { Task { await refreshAwg() } } } }
    @Published var status = ""
    @Published var logLines: [LogLine] = []
    @Published var busy = false

    // данные главной
    private(set) var masterPanel: XuiPanel?
    private(set) var master: XuiAPI?
    @Published var clients: [XClient] = []
    @Published var inbounds: [XInbound] = []
    @Published var nodes: [XNode] = []
    @Published var settings: JObj = [:]
    @Published var online: Set<String> = []
    @Published var statusObj: JObj?
    private var refreshing = false
    private static var lastMaster: String?

    // таблицы
    @Published var search = ""
    @Published var clientSel = Set<String>()
    @Published var nodeSel: Int?
    @Published var namesText = ""
    @Published var planText = ""

    // AWG
    @Published var awgPanels: [XuiPanel] = []
    @Published var awgPick: String = "" { didSet { if oldValue != awgPick { Task { await refreshAwg() } } } }
    @Published var awgClients: [AwgClient] = []
    @Published var awgIfaces: [String: [AwgInterface]] = [:]
    @Published var awgSearch = ""
    @Published var awgSel = Set<String>()
    @Published var awgStatus = ""
    private var awgLoading = false

    // листы
    @Published var planRequest: PlanRequest?
    @Published var connectRequest: ConnectRequest?
    @Published var showPanels = false
    @Published var nodeAdd: NodeAddRequest?
    @Published var qr: XuiQRInfo?

    // первая настройка
    @Published var setupName = "MSK"
    @Published var setupUrl = ""
    @Published var setupToken = ""
    @Published var setupVerify = true
    @Published var setupResult = ""

    var noMaster: Bool { masters.isEmpty }

    init() {
        namesText = store.names().lines.joined(separator: "\n")
        loadMasters()
        loadAwgPanels()
    }

    // MARK: лог

    func log(_ s: String, _ k: LogKind = .info) {
        logLines.append(LogLine(text: s, kind: k))
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    private var logger: (String, LogKind) -> Void { { [weak self] s, k in self?.log(s, k) } }

    func unifier() -> NameUnifier { NameUnifier(store.names()) }

    // MARK: главная

    func loadMasters() {
        masters = store.panels().filter(\.isMaster)
        let want = masterPanel?.id ?? Self.lastMaster
        let pick = masters.first { $0.id == want } ?? masters.first
        if let pick {
            if let cur = masterPanel, cur.id == pick.id,
               cur.url != pick.url || cur.token != pick.token || cur.verifyTls != pick.verifyTls {
                setMaster(pick)   // токен/адрес поменялись — пересоздать клиента
            }
            if masterId != pick.id { masterId = pick.id } else if master == nil { setMaster(pick) }
        } else {
            status = "Нет главной панели"
            setMaster(nil)
            masterId = ""
        }
    }

    private func masterChanged() {
        guard let p = masters.first(where: { $0.id == masterId }) else { return }
        if p.id != masterPanel?.id || master == nil {
            setMaster(p)
            Task { await refresh() }
        }
    }

    private func setMaster(_ p: XuiPanel?) {
        masterPanel = p
        master = nil
        settings = [:]
        clients = []; inbounds = []; nodes = []; online = []; statusObj = nil
        guard let p else { return }
        Self.lastMaster = p.id
        do { master = try XuiAPI.forPanel(p) } catch { status = error.localizedDescription }
    }

    func refresh(quiet: Bool = false) async {
        guard let m = master, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if !quiet { status = "обновляю…" }
        do {
            statusObj = try await m.status()
            nodes = try await m.nodes()
            inbounds = try await m.inbounds()
            clients = try await m.clients()
            online = await m.onlines()
            if settings.isEmpty { settings = try await m.settings() }
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            status = "\(masterPanel?.name ?? ""): узлов \(nodes.count), клиентов \(clients.count), онлайн \(online.count) · \(f.string(from: Date()))"
        } catch {
            status = error.localizedDescription
            if !quiet { log("✗ " + error.localizedDescription, .err) }
        }
    }

    func tick() async {
        guard !busy else { return }
        if seg == .awg { await refreshAwg(quiet: true) }
        else if seg != .names { await refresh(quiet: true) }
    }

    /// Обёртка операций: одна за раз, ошибки — в лог, после — обновление.
    func runOp(_ title: String, _ op: @escaping @MainActor (XuiAPI) async throws -> Void) async {
        if busy { log("! дождись окончания текущей операции", .warn); return }
        guard let m = master else { XuiDialog.info("Сначала выбери главную панель"); return }
        busy = true
        log("━━ \(title)", .head)
        do { try await op(m) } catch { log("✗ " + error.localizedDescription, .err) }
        busy = false
        await refresh(quiet: true)
    }

    /// Панели поменялись (окно панелей, «Нода из выделения», синк) — перечитать всё.
    func reloadPanels() async {
        loadMasters()
        loadAwgPanels()
        if seg == .awg { await refreshAwg() } else { await refresh() }
    }

    func setupSave() async {
        var p = XuiPanel()
        p.name = setupName.trimmingCharacters(in: .whitespaces).isEmpty ? "MSK" : setupName.trimmingCharacters(in: .whitespaces)
        p.role = "master"
        p.url = setupUrl.trimmingCharacters(in: .whitespaces)
        p.token = setupToken.trimmingCharacters(in: .whitespaces)
        p.verifyTls = setupVerify
        if p.token.isEmpty { setupResult = "✗ нужен API-токен"; return }
        setupResult = "проверяю…"
        do {
            let api = try XuiAPI.forPanel(p)
            let st = try await api.status()
            let nn = try await api.nodes()
            store.save(p)
            setupResult = ""
            setupToken = ""
            log("✓ главная «\(p.name)»: 3x-ui \(J.str(st, "panelVersion")), узлов \(nn.count) — сохранена в вейлт", .ok)
            await reloadPanels()
        } catch { setupResult = "✗ " + error.localizedDescription }
    }

    // MARK: форматирование

    static func bytes(_ v: Double) -> String {
        let u = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
        var b = v, i = 0
        while b >= 1024 && i < u.count - 1 { b /= 1024; i += 1 }
        return i == 0 ? String(format: "%.0f %@", b, u[i]) : String(format: "%.2f %@", b, u[i])
            .replacingOccurrences(of: ".00 ", with: " ")
    }

    static func uptime(_ s: Int64) -> String {
        if s <= 0 { return "—" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d >= 1 ? "\(d) д \(h) ч" : "\(h) ч \(m) мин"
    }

    static func expiry(_ ms: Int64) -> String {
        if ms == 0 { return "∞" }
        if ms < 0 { return "\(-ms / 86_400_000) д. с 1-го входа" }
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"
        return d < Date() ? "\(f.string(from: d)) ⛔" : f.string(from: d)
    }

    // MARK: Монитор

    var monRows: [MonRow] {
        var rows: [MonRow] = []
        if let mp = masterPanel, let st = statusObj {
            let mem = st["mem"] as? JObj
            let memPct = mem.map { 100.0 * Double(J.long($0, "current")) / Double(max(1, J.long($0, "total"))) } ?? 0
            let xray = st["xray"] as? JObj
            let net = st["netIO"] as? JObj
            let localIb = Set(inbounds.filter { $0.nodeId == nil }.map(\.id))
            let local = clients.filter { $0.inboundIds.contains(where: localIb.contains) }
            let running = xray == nil || J.str(xray!, "state") == "running"
            rows.append(MonRow(
                id: "master", name: mp.name + " (главная)",
                status: running ? "online" : "xray: " + J.str(xray ?? [:], "state"),
                statusColor: running ? .green : .orange, ping: "—",
                cpu: String(format: "%.0f%%", J.dbl(st, "cpu")), ram: String(format: "%.0f%%", memPct),
                uptime: Self.uptime(J.long(st, "uptime")), xray: xray.map { J.str($0, "version") } ?? "",
                clients: "\(local.filter { online.contains($0.email) }.count) / \(local.count)",
                net: net.map { "\(Self.bytes(Double(J.long($0, "up"))))/с ↑  \(Self.bytes(Double(J.long($0, "down"))))/с ↓" } ?? "",
                error: xray.map { J.str($0, "errorMsg") } ?? ""))
        }
        for n in nodes.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let on = n.status == "online"
            rows.append(MonRow(
                id: "n\(n.id)", name: n.name, status: !n.enable ? "выключен" : n.status,
                statusColor: !n.enable ? .secondary : on ? (n.xrayState.isEmpty || n.xrayState == "running" ? .green : .orange) : .red,
                ping: on ? "\(n.latencyMs) мс" : "—", cpu: on ? String(format: "%.0f%%", n.cpuPct) : "—",
                ram: on ? String(format: "%.0f%%", n.memPct) : "—", uptime: on ? Self.uptime(n.uptimeSecs) : "—",
                xray: n.xrayVersion, clients: "\(n.onlineCount) / \(n.clientCount)",
                net: on ? "\(Self.bytes(Double(n.netUp)))/с ↑  \(Self.bytes(Double(n.netDown)))/с ↓" : "",
                error: n.lastError))
        }
        return rows
    }

    // MARK: Клиенты

    var servers: [ServerCol] {
        var list = [ServerCol(id: "m", title: masterPanel?.name ?? "главная", nodeId: nil, index: 0)]
        for (i, n) in nodes.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).enumerated() {
            list.append(ServerCol(id: "n\(n.id)", title: n.name, nodeId: n.id, index: i + 1))
        }
        return list
    }

    var clientRows: [ClientRow] {
        let srv = servers
        let ibById = XuiOps.byId(inbounds)
        let f = search.trimmingCharacters(in: .whitespaces)
        return clients
            .filter { f.isEmpty || $0.email.localizedCaseInsensitiveContains(f) || $0.subId.localizedCaseInsensitiveContains(f) }
            .sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
            .map { c in
                let cells: [(String, Color)] = srv.map { s in
                    let ibs = c.inboundIds.compactMap { ibById[$0] }.filter { $0.nodeId == s.nodeId }
                    let v = ibs.contains { !$0.isHys }, h = ibs.contains(where: \.isHys)
                    return (v && h ? "V · H" : v ? "V" : h ? "H" : "—", v && h ? .green : v ? .blue : h ? .purple : .secondary)
                }
                let (pv, ph) = XuiOps.protos(c.inboundIds, ibById)
                return ClientRow(src: c, dot: !c.enable ? .red : online.contains(c.email) ? .green : .secondary,
                                 merged: pv && ph, enabled: c.enable ? "да" : "нет",
                                 traffic: Self.bytes(Double(c.up + c.down)) + (c.totalBytes > 0 ? " / " + Self.bytes(Double(c.totalBytes)) : ""),
                                 expiry: Self.expiry(c.expiryTime), cells: cells)
            }
    }

    func selectedClients(_ ids: Set<String>? = nil) -> [XClient] {
        let s = ids ?? clientSel
        return clients.filter { s.contains($0.email) }
    }

    func clientNew() async {
        guard master != nil else { XuiDialog.info("Сначала подключи главную панель"); return }
        guard let name = XuiDialog.ask("Имя клиента (приведётся к списку имён):") else { return }
        let u = unifier()
        let toks = XuiOps.stripTokens(inbounds, nodes)
        let key = u.analyze(name, toks).key
        if clients.contains(where: { u.analyze($0.email, toks).key == key }) {
            XuiDialog.info("Клиент «\(NameUnifier.baseText(name))» уже есть — привяжи его к нужным серверам через меню или «Синхронизировать…»")
            return
        }
        let choice = XuiDialog.choose(
            "Новый клиент «\(NameUnifier.baseText(name))». Куда добавить?\n\nИмя получит индекс по протоколам: без индекса — VLESS, -HYS — Hysteria, -SYNC — оба.",
            title: "Новый клиент", ["Все серверы", "Только главная", "Отмена"])
        if choice < 0 || choice == 2 { return }
        let ids = inbounds.filter { $0.multiUser && $0.enable && (choice == 0 || $0.nodeId == nil) }.map(\.id)
        if ids.isEmpty { XuiDialog.info("Нет подходящих входящих"); return }
        let (pv, ph) = XuiOps.protos(ids, XuiOps.byId(inbounds))
        let display = u.displayFor(key, [name], name, vless: pv, hys: ph)
        await runOp("Новый клиент \(display)") { m in
            try await m.addClient(display, ids)
            self.log("  ✓ \(display): входящих \(ids.count)", .ok)
        }
    }

    func linkOf(_ c: XClient, clash: Bool = false) -> String? {
        guard let m = master, !c.subId.isEmpty else { return nil }
        return XuiAPI.subLink(settings, m.url, c.subId, clash: clash)
    }

    func copyLink(_ c: XClient, clash: Bool = false) {
        guard let link = linkOf(c, clash: clash) else {
            XuiDialog.info("Подписка выключена в настройках панели или у клиента нет ID подписки"); return
        }
        XuiDialog.copy(link)
        log("  ✓ ссылка \(clash ? "Mihomo" : "подписки") \(c.email) скопирована: \(link)", .ok)
    }

    func showQR(_ c: XClient) {
        guard let link = linkOf(c) else {
            XuiDialog.info("Подписка выключена в настройках панели или у клиента нет ID подписки"); return
        }
        qr = XuiQRInfo(title: "Подписка · " + c.email, text: link, clash: linkOf(c, clash: true))
    }

    func toggle(_ sel: [XClient]) async {
        guard !sel.isEmpty else { return }
        let target = !sel.allSatisfy(\.enable)
        await runOp(target ? "Включить" : "Выключить") { m in
            for c in sel {
                try await m.updateClient(c.email, XuiAPI.clientPayload(c, enable: target))
                self.log("  ✓ \(c.email): \(target ? "вкл" : "выкл")", .ok)
            }
        }
    }

    func delete(_ sel: [XClient]) async {
        guard !sel.isEmpty else { return }
        guard XuiDialog.confirm("Удалить со ВСЕХ серверов: \(sel.map(\.email).joined(separator: ", "))?",
                                title: "Удаление", yes: "Удалить") else { return }
        await runOp("Удаление") { m in
            for c in sel {
                try await m.deleteClient(c.email)
                self.log("  ✓ \(c.email) удалён", .ok)
            }
        }
    }

    func rename(_ c: XClient) async {
        guard let nn = XuiDialog.ask("Новое имя:", value: c.email), nn != c.email else { return }
        await runOp("Переименовать \(c.email)") { m in
            try await m.updateClient(c.email, XuiAPI.clientPayload(c, email: nn))
            self.log("  ✓ \(c.email) → \(nn)", .ok)
        }
    }

    func regenSubId(_ c: XClient) async {
        guard XuiDialog.confirm("Перевыпустить ID подписки \(c.email)? Старая ссылка перестанет работать — устройство надо будет переподписать.",
                                title: "Новый ID подписки", yes: "Перевыпустить") else { return }
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let sid = bytes.map { String(format: "%02x", $0) }.joined()
        await runOp("Новый ID подписки \(c.email)") { m in
            try await m.updateClient(c.email, XuiAPI.clientPayload(c, subId: sid))
            self.log("  ✓ \(c.email): \(sid)", .ok)
        }
    }

    func bind(_ sel: [XClient], _ ids: [Int], attach: Bool, _ what: String) async {
        await runOp("\(attach ? "Привязать к" : "Отвязать от") \(what)") { m in
            for c in sel {
                let need = attach ? ids.filter { !c.inboundIds.contains($0) } : ids.filter { c.inboundIds.contains($0) }
                if need.isEmpty { continue }
                if attach { try await m.attach(c.email, need) } else { try await m.detach(c.email, need) }
                self.log("  ✓ \(c.email): \(need.count) вх.", .ok)
            }
            try await XuiOps(self.unifier(), log: self.logger).normalizeIndex(m, sel.map(\.email))
        }
    }

    // MARK: синхронизация: одинаковые клиенты на всех серверах

    func serverName(_ nodeId: Int?) -> String {
        if let n = nodeId { return nodes.first { $0.id == n }?.name ?? "узел \(n)" }
        return masterPanel?.name ?? "главная"
    }

    /// Строки «клиент × входящий», где клиента нет. nodeFilter — только эти серверы (nil = все).
    func syncItems(_ who: [XClient], nodeFilter: [Int?]?) -> [PlanItem] {
        let targets = inbounds
            .filter { $0.multiUser && $0.enable && (nodeFilter == nil || nodeFilter!.contains($0.nodeId)) }
            .sorted { ($0.nodeId ?? 0, $0.remark.lowercased()) < ($1.nodeId ?? 0, $1.remark.lowercased()) }
        let u = unifier()
        let toks = XuiOps.stripTokens(inbounds, nodes)
        func canon(_ e: String) -> Bool { u.isCanonical(u.analyze(e, toks).key) }
        let ibAll = XuiOps.byId(inbounds)
        var items: [PlanItem] = []
        let ordered = who.sorted {
            (canon($0.email) ? 0 : 1, $0.email.lowercased()) < (canon($1.email) ? 0 : 1, $1.email.lowercased())
        }
        for c in ordered {
            let p = XuiOps.protos(c.inboundIds, ibAll)
            for ib in targets where !c.inboundIds.contains(ib.id) {
                items.append(PlanItem(
                    scope: serverName(ib.nodeId), kind: "attach", key: "\(c.email)|\(ib.id)", result: c.email,
                    from: "\(ib.remark)  (\(ib.proto):\(ib.port))",
                    note: !c.enable ? "клиент выключен" : canon(c.email) ? "те же ключи и та же подписка" : "не из списка имён — по умолчанию не отмечено",
                    apply: c.enable && canon(c.email), merged: p.v && p.h, email: c.email, ids: [ib.id]))
            }
        }
        return items
    }

    /// Показать план с галками и дождаться ответа.
    func askPlan(_ req: PlanRequest) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            req.done = { cont.resume(returning: $0) }
            planRequest = req
        }
    }

    func askConnect(_ req: ConnectRequest) async -> ConnectResult? {
        await withCheckedContinuation { (cont: CheckedContinuation<ConnectResult?, Never>) in
            req.done = { cont.resume(returning: $0) }
            connectRequest = req
        }
    }

    func runSync(_ title: String, _ summary: String, _ items: [PlanItem]) async {
        if items.isEmpty {
            XuiDialog.info("Синхронизировать нечего: выбранные клиенты уже есть на всех входящих выбранных серверов.")
            return
        }
        let ok = await askPlan(PlanRequest(
            title: title, summary: summary,
            note: "Имена клиентов не меняются (кроме индекса -HYS/-SYNC по протоколам). Добавляется только отмеченное; удаления нет.",
            items: items, resultHeader: "Клиент", fromHeader: "Куда добавить (входящий)"))
        if !ok { return }
        await runOp(title) { m in
            var groups: [String: [PlanItem]] = [:]
            for i in items where i.apply { groups[i.email, default: []].append(i) }
            for email in groups.keys.sorted() {
                let g = groups[email]!
                var ids: [Int] = []
                for i in g { for x in i.ids where !ids.contains(x) { ids.append(x) } }
                try await m.attach(email, ids)
                let whereText = g.map { "\($0.scope):" + ($0.from.components(separatedBy: "  (").first ?? $0.from) }.joined(separator: ", ")
                self.log("  ✓ \(email) → \(whereText)", .ok)
            }
            try await XuiOps(self.unifier(), log: self.logger).normalizeIndex(m, Array(groups.keys))
        }
    }

    func clientSync() async {
        guard master != nil else { XuiDialog.info("Сначала подключи главную панель"); return }
        let sel = selectedClients()
        let who = sel.isEmpty ? clients : sel
        await runSync("Синхронизация клиентов",
                      sel.isEmpty ? "Все клиенты (\(who.count)) → все серверы" : "Выделенные клиенты (\(sel.count)) → все серверы",
                      syncItems(who, nodeFilter: nil))
    }

    // MARK: Узлы

    func savedFor(_ n: XNode) -> XuiPanel? {
        store.panels().first { $0.isXuiNode && (PanelURL.tryParse($0.url)?.sameAs(n.address, n.port, n.basePath) ?? false) }
    }

    var nodeRows: [NodeRow] {
        let saved = store.panels().filter(\.isXuiNode)
        return nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { n in
            NodeRow(src: n,
                    saved: saved.first { PanelURL.tryParse($0.url)?.sameAs(n.address, n.port, n.basePath) ?? false },
                    status: !n.enable ? "выключен" : n.status,
                    statusColor: !n.enable ? .secondary : n.status == "online" ? .green : .red)
        }
    }

    var selectedNode: NodeRow? { nodeRows.first { $0.id == nodeSel } }

    private func needNode() -> NodeRow? {
        if let r = selectedNode { return r }
        XuiDialog.info("Выбери узел в списке")
        return nil
    }

    func nodeConnect() async {
        guard master != nil else { XuiDialog.info("Сначала выбери главную панель"); return }
        guard let r = await askConnect(ConnectRequest(saved: store.panels().filter(\.isXuiNode))) else { return }
        await connectOrRevise(url: r.url, token: r.token, verify: r.verifyTls, name: r.name, attachOthers: r.attachOthers, save: r.saveToken)
    }

    func nodeRevise() async {
        guard let r = needNode() else { return }
        guard let s = r.saved else { XuiDialog.info("Для ревизии нужен токен ноды — «Токен ноды…»"); return }
        await connectOrRevise(url: s.url, token: s.token, verify: s.verifyTls, name: r.name, attachOthers: false, save: false)
    }

    func connectOrRevise(url: String, token: String, verify: Bool, name: String?, attachOthers: Bool, save: Bool) async {
        await runOp("Нода " + url) { m in
            let node = try XuiAPI(label: "нода", url: url, token: token, verifyTls: verify)
            let ops = XuiOps(self.unifier(), log: self.logger)
            let plan = try await ops.planNode(m, node, token: token, newName: name, attachOthers: attachOthers)
            if save { self.saveNodePanel(plan.name, url, token, verify) }
            let items = ops.mergeItems(plan.masterMerge, scope: "главная", self.inbounds, self.nodes, owner: plan) + ops.nodeItems(plan)
            if items.isEmpty && plan.existing != nil {
                self.log("  ✓ нода «\(plan.name)»: всё в порядке, менять нечего", .ok)
                return
            }
            let summary = plan.existing == nil
                ? "Новая нода «\(plan.name)» (\(plan.node.url.host):\(plan.node.url.port)) — будет добавлена на главную «\(self.masterPanel?.name ?? "")»"
                : "Нода «\(plan.name)» уже на главной — привести клиентов к единым именам"
            let go = await self.askPlan(PlanRequest(
                title: "Нода " + plan.name, summary: summary,
                note: "Перед изменениями — бэкапы баз главной и ноды (\(XuiOps.backupDir.path))",
                items: items, forceApply: plan.existing == nil))
            if !go { self.log("  остановлено", .warn); return }
            XuiOps.applySelection(plan, items)
            try await ops.applyNode(m, plan)
            if plan.existing == nil {
                self.log("  Введённый токен ноды главной больше не нужен (у неё свой node-sync)." +
                         (save ? " Он сохранён в QTerm для ревизии." : " Можешь удалить его в панели ноды."), .dim)
            }
        }
    }

    func saveNodePanel(_ name: String, _ url: String, _ token: String, _ verify: Bool) {
        let pu = PanelURL.tryParse(url)
        var p = store.panels().first { $0.isXuiNode && PanelURL.tryParse($0.url) == pu } ?? {
            var n = XuiPanel(); n.role = "node"; return n
        }()
        p.name = name; p.url = url; p.token = token; p.verifyTls = verify
        store.save(p)
        log("  ✓ токен ноды «\(name)» сохранён в QTerm", .ok)
    }

    func nodeToggle() async {
        guard let r = needNode() else { return }
        await runOp("Узел \(r.name): \(r.src.enable ? "выключить" : "включить")") { m in
            try await m.setNodeEnable(r.src.id, !r.src.enable)
            self.log("  ✓ готово", .ok)
        }
    }

    func nodeProbe() async {
        guard let r = needNode() else { return }
        await runOp("Проверка \(r.name)") { m in
            try await m.probeNode(r.src.id)
            self.log("  ✓ узел отвечает", .ok)
        }
    }

    func nodeSync() async {
        guard let r = needNode() else { return }
        await runSync("Выровнять клиентов · " + r.name, "Все клиенты главной → узел «\(r.name)»",
                      syncItems(clients, nodeFilter: [r.src.id]))
    }

    func nodeToken() async {
        guard let r = needNode() else { return }
        guard let res = await askConnect(ConnectRequest(saved: [], url: r.saved?.url ?? r.address, name: r.name, tokenOnly: true)) else { return }
        await runOp("Токен \(r.name)") { _ in
            let node = try XuiAPI(label: r.name, url: res.url, token: res.token, verifyTls: res.verifyTls)
            _ = try await node.status()
            self.saveNodePanel(r.name, res.url, res.token, res.verifyTls)
        }
    }

    // MARK: Ревизия имён

    func namesFromEditor() -> XuiNamesConfig {
        var c = XuiNamesConfig()
        c.lines = namesText.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return c
    }

    func namesSave() {
        store.saveNames(namesFromEditor())
        log("✓ список имён сохранён (уедет синком)", .ok)
    }

    func namesDefault() { namesText = XuiNamesConfig.defaultNames.joined(separator: "\n") }

    /// Переезд на сдвоенных: записи одного устройства → одна (NAME-SYNC) на все входящие VLESS + Hysteria.
    func migrate() async {
        guard master != nil else { XuiDialog.info("Сначала подключи главную панель"); return }
        store.saveNames(namesFromEditor())
        await runOp("Переезд на SYNC") { m in
            let u = self.unifier()
            let ops = XuiOps(u, log: self.logger)
            let clients = try await m.clients()
            let inbounds = try await m.inbounds()
            let nodes = try await m.nodes()
            let ibById = XuiOps.byId(inbounds)
            let toks = XuiOps.stripTokens(inbounds, nodes)
            func srv(_ id: Int?) -> String {
                if let n = id { return nodes.first { $0.id == n }?.name ?? "узел \(n)" }
                return self.masterPanel?.name ?? "главная"
            }
            let merges = ops.planMerge(clients, inbounds, nodes)
            var items = ops.mergeItems(merges, scope: self.masterPanel?.name ?? "главная", inbounds, nodes)
            let targets = inbounds.filter { $0.multiUser && $0.enable }
                .sorted { ($0.nodeId ?? 0, $0.remark.lowercased()) < ($1.nodeId ?? 0, $1.remark.lowercased()) }
            var groups: [String: [XClient]] = [:]
            for c in clients { groups[u.analyze(c.email, toks).key, default: []].append(c) }
            for key in groups.keys.sorted() where u.isCanonical(key) {
                let g = groups[key]!
                let union = Set(g.flatMap(\.inboundIds))
                let p = XuiOps.protos(union, ibById)
                let merged = p.v && p.h && g.count == 1
                let final = NameUnifier.withIndex(u.canon[key] ?? key, vless: true, hys: true)
                for ib in targets where !union.contains(ib.id) {
                    items.append(PlanItem(scope: srv(ib.nodeId), kind: "attach", key: "\(key)|\(ib.id)", result: final,
                                          from: "\(ib.remark)  (\(ib.proto):\(ib.port))", note: "те же ключи и та же подписка",
                                          apply: true, merged: merged, clientKey: key, ids: [ib.id]))
                }
            }
            if items.isEmpty { self.log("  ✓ все клиенты из списка уже сдвоенные и есть на всех серверах", .ok); return }

            let go = await self.askPlan(PlanRequest(
                title: "Переезд на SYNC",
                summary: "Клиенты из списка имён → одна запись NAME-SYNC на всех входящих VLESS и Hysteria (главная «\(self.masterPanel?.name ?? "")» и узлы)",
                note: "Порядок: бэкап главной → склейка → добавление на входящие → индекс в имени. Ключи и ID подписки сохраняются.",
                items: items, resultHeader: "Клиент (станет)", fromHeader: "Записи / куда добавить"))
            if !go { self.log("  остановлено", .warn); return }

            let bp = try await ops.backup(m, "master")
            self.log("  ✓ бэкап главной → " + bp, .ok)
            let approved = Set(items.filter { $0.kind == "merge" && $0.apply }.map(\.key))
            if !approved.isEmpty {
                let fresh = ops.planMerge(try await m.clients(), try await m.inbounds(), try await m.nodes())
                    .filter { approved.contains($0.key) }
                XuiOps.applyOverrides(fresh, XuiOps.overrides(items))
                await ops.applyMerge(m, fresh)
            }
            // после склейки клиента ищем по ключу имени — имя могло поменяться
            let now = try await m.clients()
            var byKey: [String: XClient] = [:]
            for c in now {
                let k = u.analyze(c.email, toks).key
                if byKey[k] == nil { byKey[k] = c }
            }
            var touched: [String] = []
            var att: [String: [PlanItem]] = [:]
            for i in items where i.kind == "attach" && i.apply { att[i.clientKey, default: []].append(i) }
            for key in att.keys.sorted() {
                guard let c = byKey[key] else { self.log("  ✗ не нашёл клиента для \(key)", .err); continue }
                var ids: [Int] = []
                for i in att[key]! { for x in i.ids where !c.inboundIds.contains(x) && !ids.contains(x) { ids.append(x) } }
                if ids.isEmpty { continue }
                do {
                    try await m.attach(c.email, ids)
                    self.log("  ✓ \(c.email) → +\(ids.count) вх.", .ok)
                    touched.append(c.email)
                } catch { self.log("  ✗ \(c.email): \(error.localizedDescription)", .err) }
            }
            try await ops.normalizeIndex(m, Array(Set(touched + byKey.values.map(\.email))))
        }
    }

    func analyze() async {
        guard master != nil else { XuiDialog.info("Сначала выбери главную панель"); return }
        store.saveNames(namesFromEditor())
        var notes: [String] = []
        await runOp("Ревизия имён") { m in
            let ops = XuiOps(self.unifier(), log: self.logger)
            let inbounds = try await m.inbounds()
            let nodes = try await m.nodes()
            let revMaster = ops.planMerge(try await m.clients(), inbounds, nodes)
            var items = ops.mergeItems(revMaster, scope: self.masterPanel?.name ?? "главная", inbounds, nodes)
            var revNodes: [NodePlan] = []
            for n in nodes.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                guard let saved = self.savedFor(n) else {
                    notes.append("«\(n.name)»: токен ноды не сохранён — дубли на самой ноде не проверялись (Узлы → Токен ноды…)")
                    continue
                }
                do {
                    let api = try XuiAPI(label: n.name, url: saved.url, token: saved.token, verifyTls: saved.verifyTls)
                    let plan = try await ops.planNode(m, api, token: saved.token, newName: n.name, attachOthers: false)
                    plan.masterMerge = []   // главная — выше
                    plan.others = []        // ревизия ничего не привязывает
                    let ni = ops.nodeItems(plan)
                    if !ni.isEmpty { revNodes.append(plan); items += ni }
                } catch { notes.append("«\(n.name)»: \(error.localizedDescription)") }
            }
            if items.isEmpty { self.log("  ✓ всё уже в порядке", .ok); return }

            let go = await self.askPlan(PlanRequest(
                title: "Ревизия имён", summary: "Главная «\(self.masterPanel?.name ?? "")» и ноды с сохранённым токеном",
                note: (notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n") + "Перед изменениями — бэкапы баз (\(XuiOps.backupDir.path))",
                items: items))
            if !go { self.log("  остановлено", .warn); return }

            let approved = Set(items.filter { $0.owner == nil && $0.apply }.map(\.key))
            if !approved.isEmpty {
                let bp = try await ops.backup(m, "master")
                self.log("  ✓ бэкап главной → " + bp, .ok)
                let fresh = ops.planMerge(try await m.clients(), try await m.inbounds(), try await m.nodes())
                    .filter { approved.contains($0.key) }
                XuiOps.applyOverrides(fresh, XuiOps.overrides(items.filter { $0.owner == nil }))
                await ops.applyMerge(m, fresh)
            }
            for plan in revNodes {
                XuiOps.applySelection(plan, items)
                if !plan.replace.isEmpty || !plan.approvedKeep.isEmpty { try await ops.applyNode(m, plan) }
            }
            self.planText = items.map(\.asText).joined(separator: "\n") + (notes.isEmpty ? "" : "\n\n" + notes.joined(separator: "\n"))
        }
    }

    // MARK: AWG

    func loadAwgPanels() {
        awgPanels = store.panels().filter(\.isAwg)
        if !awgPick.isEmpty && !awgPanels.contains(where: { $0.id == awgPick }) { awgPick = "" }
    }

    private var awgTargets: [XuiPanel] {
        if let one = awgPanels.first(where: { $0.id == awgPick }) { return [one] }
        return awgPanels
    }

    func refreshAwg(quiet: Bool = false) async {
        if awgLoading { return }
        if awgPanels.isEmpty {
            awgStatus = "AWG-нод нет — «＋ Нода из выделения» (выдели итог установщика в терминале) или «Панели…»"
            awgClients = []
            return
        }
        awgLoading = true
        defer { awgLoading = false }
        if !quiet { awgStatus = "обновляю…" }
        let targets = awgTargets
        // все ноды параллельно: одна лежащая не тормозит остальные
        let results = await withTaskGroup(of: (XuiPanel, [AwgInterface], [AwgClient], String?).self) { g in
            for p in targets {
                g.addTask {
                    do {
                        let api = try Awg.api(p)
                        let ifs = try await api.interfaces()
                        let cl = try await api.clients(p)
                        return (p, ifs, cl, nil)
                    } catch { return (p, [], [], "\(p.name): \(error.localizedDescription)") }
                }
            }
            var out: [(XuiPanel, [AwgInterface], [AwgClient], String?)] = []
            for await r in g { out.append(r) }
            return out
        }
        var list: [AwgClient] = []
        var errors: [String] = []
        for (p, ifs, cl, err) in results {
            if let err { errors.append(err); continue }
            awgIfaces[p.id] = ifs
            list += cl
            snapshotAwgClients(p.id, cl)
        }
        awgClients = list
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        awgStatus = errors.isEmpty
            ? "нод \(targets.count), клиентов \(list.count), на связи \(list.filter { Self.fresh($0.handshake) }.count) · \(f.string(from: Date()))"
            : "✗ " + errors.joined(separator: " · ")
        if !errors.isEmpty && !quiet { for e in errors { log("✗ " + e, .err) } }
    }

    /// Имена клиентов ноды — в вейлт: после переустановки их можно пересоздать на новой панели.
    /// Пустой список старый не затирает — пустая свежая панель как раз и есть переустановка.
    private func snapshotAwgClients(_ id: String, _ cl: [AwgClient]) {
        let names = Array(Set(cl.map(\.name).filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard var fresh = store.panel(id) else { return }
        if names.isEmpty && !(fresh.clients ?? []).isEmpty { return }
        if fresh.clients == names { return }
        fresh.clients = names
        store.save(fresh)
    }

    static func fresh(_ hs: Date?) -> Bool { hs.map { Date().timeIntervalSince($0) < 180 } ?? false }

    static func ago(_ hs: Date?) -> String {
        guard let d = hs else { return "—" }
        let t = Date().timeIntervalSince(d)
        if t < 60 { return "\(Int(t)) с назад" }
        if t < 3600 { return "\(Int(t / 60)) мин назад" }
        if t < 48 * 3600 { return "\(Int(t / 3600)) ч назад" }
        return "\(Int(t / 86400)) д назад"
    }

    var awgRows: [AwgRow] {
        let f = awgSearch.trimmingCharacters(in: .whitespaces)
        return awgClients
            .filter { f.isEmpty || $0.name.localizedCaseInsensitiveContains(f) || $0.address.contains(f) }
            .sorted {
                $0.panel.localizedCaseInsensitiveCompare($1.panel) != .orderedSame
                    ? $0.panel.localizedCaseInsensitiveCompare($1.panel) == .orderedAscending
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { c in
                let i = awgIfaces[c.panelId]?.first { $0.name == c.interfaceId }
                return AwgRow(src: c, iface: i?.label ?? c.interfaceId, handshake: Self.ago(c.handshake),
                              traffic: "\(Self.bytes(Double(c.rx))) / \(Self.bytes(Double(c.tx)))",
                              dot: !c.enabled ? .red : Self.fresh(c.handshake) ? .green : .secondary)
            }
    }

    func awgSelected(_ ids: Set<String>? = nil) -> [AwgClient] {
        let s = ids ?? awgSel
        return awgClients.filter { s.contains($0.id) }
    }

    private func panelOf(_ c: AwgClient) -> XuiPanel? { awgPanels.first { $0.id == c.panelId } }

    func awgConfig(_ c: AwgClient) async -> String? {
        guard let p = panelOf(c) else { return nil }
        do { return try await Awg.api(p).config(c.cid) }
        catch { log("✗ " + error.localizedDescription, .err); return nil }
    }

    private func oneAwg() -> AwgClient? {
        let s = awgSelected()
        if s.count == 1 { return s[0] }
        XuiDialog.info("Выбери одного клиента")
        return nil
    }

    func awgCopy() async {
        guard let c = oneAwg(), let conf = await awgConfig(c) else { return }
        XuiDialog.copy(conf)
        log("✓ конфиг \(c.panel)/\(c.name) в буфере", .ok)
    }

    func awgQR(_ c: AwgClient? = nil) async {
        guard let c = c ?? oneAwg(), let conf = await awgConfig(c) else { return }
        qr = XuiQRInfo(title: "AWG · \(c.panel) · \(c.name)", text: conf, isConfig: true)
    }

    private static func safeFile(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" })
    }

    func awgSave() async {
        let sel = awgSelected()
        if sel.isEmpty { XuiDialog.info("Выдели клиентов"); return }
        if sel.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Self.safeFile("\(sel[0].panel)-\(sel[0].name)") + ".conf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if let conf = await awgConfig(sel[0]) {
                do { try conf.write(to: url, atomically: true, encoding: .utf8); log("✓ сохранено: " + url.path, .ok) }
                catch { log("✗ " + error.localizedDescription, .err) }
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Сохранить сюда"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for c in sel {
            guard let conf = await awgConfig(c) else { continue }
            let url = dir.appendingPathComponent(Self.safeFile("\(c.panel)-\(c.name)") + ".conf")
            do { try conf.write(to: url, atomically: true, encoding: .utf8); log("✓ " + url.path, .ok) }
            catch { log("✗ " + error.localizedDescription, .err) }
        }
    }

    func awgToggle() async {
        let sel = awgSelected()
        if sel.isEmpty { return }
        let on = !sel.allSatisfy(\.enabled)
        for c in sel {
            guard let p = panelOf(c) else { continue }
            do { try await Awg.api(p).enable(c.cid, on); log("✓ \(c.panel)/\(c.name): \(on ? "вкл" : "выкл")", .ok) }
            catch { log("✗ " + error.localizedDescription, .err) }
        }
        await refreshAwg(quiet: true)
    }

    func awgDelete() async {
        let sel = awgSelected()
        if sel.isEmpty { return }
        guard XuiDialog.confirm("Удалить клиентов AWG: \(sel.map { "\($0.panel)/\($0.name)" }.joined(separator: ", "))?\n\nУстройства с их конфигами перестанут подключаться.",
                                title: "Удаление", yes: "Удалить") else { return }
        for c in sel {
            guard let p = panelOf(c) else { continue }
            do { try await Awg.api(p).delete(c.cid); log("✓ \(c.panel)/\(c.name) удалён", .ok) }
            catch { log("✗ " + error.localizedDescription, .err) }
        }
        await refreshAwg(quiet: true)
    }

    func awgNew() async {
        if awgPanels.isEmpty { XuiDialog.info("Сначала добавь AWG-ноду («＋ Нода из выделения» или «Панели…»)"); return }
        guard let name = XuiDialog.ask("Имя клиента AWG:") else { return }
        let one = awgPanels.first { $0.id == awgPick }
        let targets = one.map { [$0] } ?? awgPanels
        if one == nil && awgPanels.count > 1 {
            if XuiDialog.choose("Создать «\(name)» на всех AWG-нодах (\(awgPanels.count))?\nЧтобы создать на одной — выбери её в списке слева сверху.",
                                title: "Новый клиент AWG", ["На всех", "Отмена"]) != 0 { return }
        }
        // версия AWG: если где-то есть и 2.0, и 3.1 — спросить
        let all = targets.flatMap { awgIfaces[$0.id] ?? [] }
        let has20 = all.contains { !$0.isAwg31 && $0.enabled }, has31 = all.contains { $0.isAwg31 && $0.enabled }
        var ver = 0 // 0 — интерфейс по умолчанию, 1 — 2.0, 2 — 3.1, 3 — оба
        if has20 && has31 {
            let v = XuiDialog.choose("На каком интерфейсе? (Keenetic понимает только AWG 2.0)", title: "Новый клиент AWG",
                                     ["AWG 2.0", "AWG 3.1", "Оба", "Отмена"])
            if v < 0 || v == 3 { return }
            ver = v + 1
        }
        for p in targets {
            let ifs = awgIfaces[p.id] ?? []
            var want: [AwgInterface]
            switch ver {
            case 1: want = Array(ifs.filter { !$0.isAwg31 && $0.enabled }.prefix(1))
            case 2: want = Array(ifs.filter { $0.isAwg31 && $0.enabled }.prefix(1))
            case 3:
                want = []
                if let a = ifs.first(where: { !$0.isAwg31 && $0.enabled }) { want.append(a) }
                if let b = ifs.first(where: { $0.isAwg31 && $0.enabled }) { want.append(b) }
            default: want = []
            }
            let list: [AwgInterface?] = want.isEmpty ? [nil] : want.map { Optional($0) }
            do {
                let api = try Awg.api(p)
                for iface in list {
                    let nm = ver == 3 && iface != nil ? "\(name)-\(iface!.isAwg31 ? "31" : "20")" : name
                    do {
                        try await api.create(nm, interfaceId: iface?.name)
                        log("✓ \(p.name): \(nm)\(iface == nil ? "" : " на " + iface!.name)", .ok)
                    } catch { log("✗ " + error.localizedDescription, .err) }
                }
            } catch { log("✗ " + error.localizedDescription, .err) }
        }
        await refreshAwg(quiet: true)
    }

    /// Открыть AWG на ноде (после «Нода из выделения»).
    func openAwg(_ id: String) {
        loadAwgPanels()
        if awgPanels.contains(where: { $0.id == id }) { awgPick = id }
        seg = .awg
    }

    /// После «Нода из выделения»: перечитать панели и показать результат.
    func afterNodeAdded(_ saved: [(id: String, role: String)], connectId: String?) async {
        for s in saved { if let p = store.panel(s.id) { log("✓ \(p.roleText) «\(p.name)» сохранена", .ok) } }
        await reloadPanels()
        if let cid = connectId, let node = store.panel(cid), master != nil {
            seg = .nodes
            await refresh()
            await connectOrRevise(url: node.url, token: node.token, verify: node.verifyTls, name: node.name, attachOthers: false, save: false)
            return
        }
        if let awg = saved.last(where: { $0.role == "awg" || $0.role == "awg1" }) { openAwg(awg.id); return }
        seg = .nodes
    }
}
