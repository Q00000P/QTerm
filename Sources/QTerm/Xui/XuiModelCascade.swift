import SwiftUI
import AppKit
import SessionVaultKit

// Раздел «Каскад» (порт XuiWindow.Cascade.cs): каскад-сервер — SSH-сессия QTerm с 3x-ui (+ AWG);
// на нём qcascade (mihomo с правилами Кинетиков, ноды из подписки главной, перехват клиентов 3x-ui).
// QTerm заливает скрипт сам и управляет им отдельным exec-каналом SSH, терминал не трогается.

struct CascRow: Identifiable {
    var id: String { name }
    let name: String
    let node: String
    let delay: String
    let dot: Color
}

/// Большой текст: правка (nil — отмена/без изменений) или просмотр.
final class TextEditRequest: Identifiable {
    let id = UUID()
    let title: String
    let caption: String
    let text: String
    let readOnly: Bool
    var done: ((String?) -> Void)?
    init(title: String, caption: String, text: String, readOnly: Bool = false) {
        self.title = title; self.caption = caption; self.text = text; self.readOnly = readOnly
    }
}

/// Список с галками: nil — отмена, иначе отмеченные ключи.
final class CheckRequest: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let items: [(key: String, text: String)]
    let selected: Set<String>
    var done: (([String]?) -> Void)?
    init(title: String, text: String, items: [(key: String, text: String)], selected: Set<String>) {
        self.title = title; self.text = text; self.items = items; self.selected = selected
    }
}

extension XuiModel {
    static let cascConf = "/etc/qcascade"

    var cascSel: CascadeServer? { cascades.first { $0.id == cascId } }

    func askText(_ req: TextEditRequest) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            req.done = { cont.resume(returning: $0) }
            textEditRequest = req
        }
    }

    func askChecks(_ req: CheckRequest) async -> [String]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String]?, Never>) in
            req.done = { cont.resume(returning: $0) }
            checkRequest = req
        }
    }

    func cascLoad(pick: String? = nil) {
        let keep = pick ?? cascSel?.id
        cascLoading = true
        cascades = store.cascades()
        cascId = cascades.first(where: { $0.id == keep })?.id ?? cascades.first?.id ?? ""
        cascLoading = false
        if cascades.isEmpty {
            cascStatus = nil
            cascVersion = nil
            cascStatusText = "Нет каскад-серверов — «＋ Сервер…»"
            renderCascade()
        }
    }

    func cascChanged() {
        cascStatus = nil
        cascVersion = nil
        renderCascade()
        Task { await refreshCascade() }
    }

    private func sessionExists(_ c: CascadeServer) -> UUID? {
        guard let id = c.sessionID, store.sessions().contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func remote(_ c: CascadeServer) throws -> CascadeRemote {
        guard let exec = execInSession else { throw XuiError("SSH QTerm недоступен из этого окна") }
        guard let sid = sessionExists(c) else { throw XuiError("у «\(c.name)» нет SSH-сессии в QTerm — убери сервер и добавь заново") }
        if let r = cascRemotes[c.id] { return r }
        let r = CascadeRemote { cmd, t in try await exec(sid, cmd, t) }
        cascRemotes[c.id] = r
        return r
    }

    /// Одна операция за раз; ошибки — в лог; после — статус.
    func cascOp(_ title: String, refresh: Bool = true, _ op: @escaping @MainActor (CascadeServer, CascadeRemote) async throws -> Void) async {
        if cascBusy || busy || updBusy { log("! дождись окончания текущей операции", .warn); return }
        guard let c = cascSel else { XuiDialog.info("Сначала добавь каскад-сервер: «＋ Сервер…»"); return }
        cascBusy = true
        log("━━ \(title) · \(c.name)", .head)
        do { try await op(c, try remote(c)) } catch { log("✗ " + error.localizedDescription, .err) }
        cascBusy = false
        if refresh { await refreshCascade(quiet: true) }
    }

    /// Вывод qcascade — в лог построчно, с цветом по [ok] / [!!] / [ERR].
    func logQc(_ text: String) {
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            let k: LogKind = l.hasPrefix("[ok]") ? .ok : l.hasPrefix("[!!]") ? .warn : l.hasPrefix("[ERR]") ? .err : l.hasPrefix("──") ? .head : .info
            log("  " + raw.trimmingCharacters(in: .whitespacesAndNewlines), k)
        }
    }

    func cascTick() async {
        guard !cascBusy, !cascRefreshing, let c = cascSel, let sid = sessionExists(c),
              sessionConnected?(sid) == true else { return }
        await refreshCascade(quiet: true)
    }

    func refreshCascade(quiet: Bool = false) async {
        guard let c = cascSel else { cascStatus = nil; renderCascade(); return }
        guard execInSession != nil, !cascRefreshing else { return }
        cascRefreshing = true
        defer { cascRefreshing = false }
        if !quiet { cascStatusText = "опрашиваю «\(c.name)»…" }
        do {
            let r = try remote(c)
            let ver = try await r.remoteVersion()
            guard cascSel?.id == c.id else { return }
            cascVersion = ver
            guard let ver else {
                cascStatus = nil
                cascStatusText = "«\(c.name)»: каскад не установлен — «Установить / обновить…»"
                renderCascade()
                return
            }
            let st = try await r.status()
            guard cascSel?.id == c.id else { return }
            cascStatus = st
            let mine = CascadeRemote.scriptVersion
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            cascStatusText = "«\(c.name)» · qcascade \(ver)" +
                (CascadeRemote.newer(mine, ver) ? " — в QTerm новее (\(mine)): «Установить / обновить…»" : "") +
                " · \(f.string(from: Date()))"
            renderCascade()
        } catch {
            cascStatusText = "✗ " + error.localizedDescription
            if !quiet { log("✗ " + error.localizedDescription, .err) }
        }
    }

    private static func list(_ o: JObj?, _ k: String) -> [String] {
        ((o?[k] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    private static func xrayText(_ x: String) -> String {
        switch x {
        case "off": return "выключен — клиенты идут напрямую"
        case "all": return "все клиенты 3x-ui"
        case "нет 3x-ui": return "на сервере нет 3x-ui"
        default:
            if x.hasPrefix("users: ") { return "клиенты: " + x.dropFirst(7) }
            if x.hasPrefix("inbounds: ") { return "инбаунды: " + x.dropFirst(10) }
            return x
        }
    }

    func renderCascade() {
        guard let st = cascStatus else {
            cascRows = []
            if cascSel == nil {
                cascInfo = "Каскад: сервер с 3x-ui (и AWG) становится маршрутизатором «как на Кинетике».\n\n" +
                    "• mihomo с правилами и группами роутеров (TG, EU, FII, T, MSK…)\n" +
                    "• ноды — из Clash-подписки главной (единая подписка)\n" +
                    "• трафик клиентов 3x-ui (VLESS, Hysteria, встроенный AWG) уходит в mihomo\n\n" +
                    "«＋ Сервер…» → выбрать SSH-сессию → «Установить / обновить…»."
            } else if cascVersion == nil && cascStatusText.contains("не установлен") {
                cascInfo = "qcascade на сервере нет.\n\n«Установить / обновить…»: QTerm сам зальёт скрипт, спросит подписку и кого каскадить, " +
                    "установка пойдёт на сервере в фоне (переживёт обрыв SSH), ход — в логе внизу.\n\nНужен root (или sudo без пароля)."
            } else { cascInfo = "" }
            return
        }
        var rows: [CascRow] = []
        for case let g as JObj in (st["groups"] as? [Any]) ?? [] {
            let name = J.str(g, "name")
            if J.bool(g, "missing") { rows.append(CascRow(name: name, node: "—", delay: "нет группы", dot: .red)); continue }
            let node = J.str(g, "node")
            let raw = g["delay"]
            let direct = ["DIRECT", "REJECT", "REJECT-DROP"].contains(node) || raw == nil || raw is NSNull
            let d = direct ? 0 : J.int(g, "delay")
            rows.append(CascRow(name: name, node: node,
                                delay: direct ? "напрямую" : d > 0 ? "\(d) мс" : "нет ответа",
                                dot: direct ? .orange : d > 0 ? .green : .red))
        }
        cascRows = rows

        let mh = st["mihomo"] as? JObj ?? [:]
        let env = st["env"] as? JObj ?? [:]
        let state = st["state"] as? JObj
        var lines: [String] = []
        lines.append("mihomo:      \(J.bool(mh, "active") ? "работает" : "НЕ РАБОТАЕТ — «Журнал mihomo»") \(J.str(mh, "version"))")
        let nodes = Self.list(state, "nodes")
        var built = J.str(state ?? [:], "built")
        if let d = ISO8601DateFormatter().date(from: built) {
            let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"; built = f.string(from: d)
        }
        lines.append(J.bool(env, "subSet")
                     ? "подписка:    \(nodes.count) нод · клиент \(cascSel?.client ?? "—") · сборка \(built)"
                     : "подписка:    НЕ ЗАДАНА — «Подписка…»")
        if !nodes.isEmpty { lines.append("ноды:        " + nodes.joined(separator: ", ")) }
        lines.append("перехват:    " + Self.xrayText(J.str(st, "xray")))
        let dt = J.str(env, "directTarget")
        lines.append("DIRECT →     " + (dt.isEmpty ? "DIRECT" : dt))
        let mu = J.str(env, "mihomoUrl")
        if !mu.isEmpty { lines.append("ядро:        своя сборка — " + mu) }
        let miss = Self.list(state, "missingRulesets")
        if !miss.isEmpty { lines.append("\n[!] нет rule-set на сервере (правила пропущены): " + miss.joined(separator: ", ")) }
        let ph = Self.list(state, "placeholders")
        if !ph.isEmpty { lines.append("[!] правила ссылаются на то, чего нет в подписке (→ DIRECT): " + ph.joined(separator: ", ")) }
        let empty = Self.list(state, "emptyGroups")
        if !empty.isEmpty { lines.append("[!] группы без нод из подписки (→ DIRECT): " + empty.joined(separator: ", ")) }
        let api = J.str(env, "api")
        if let colon = api.lastIndex(of: ":") {
            let port = api[api.index(after: colon)...]
            lines.append("\nпанель mihomo (zashboard): ssh -L \(port):\(api) → http://127.0.0.1:\(port)/ui")
            lines.append("secret — на сервере: grep QC_SECRET /etc/qcascade/env")
        }
        cascInfo = lines.joined(separator: "\n")
    }

    // MARK: сервер

    func cascAdd() async {
        let sessions = store.sessions()
        if sessions.isEmpty { XuiDialog.info("В QTerm нет SSH-сессий — сначала добавь ноду сервера"); return }
        let items = sessions.map { "\($0.name)   ·   \($0.username.isEmpty ? "" : $0.username + "@")\($0.host)" }
        guard let pick = await askPick(PickRequest(
            title: "Каскад-сервер",
            text: "SSH-сессия сервера, где стоят 3x-ui (и AWG). Он станет каскадом: трафик его клиентов пойдёт в mihomo с правилами как на Кинетике, ноды — из единой подписки.",
            items: items, selected: nil, ok: "Добавить", field: "Сессия")) else { return }
        let typed = pick.trimmingCharacters(in: .whitespaces)
        let s: Session? = items.firstIndex(of: pick).map { sessions[$0] }
            ?? sessions.first(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame })
        guard let s else { XuiDialog.info("Нет SSH-сессии «\(pick)»"); return }
        if let dup = store.cascades().first(where: { UUID(uuidString: $0.ssh) == s.id }) {
            cascLoad(pick: dup.id)
            XuiDialog.info("«\(s.name)» уже в списке каскадов")
            return
        }
        var c = CascadeServer()
        c.name = s.name
        c.ssh = s.id.uuidString.lowercased()
        store.saveCascade(c)
        log("✓ каскад-сервер «\(c.name)» добавлен", .ok)
        cascLoad(pick: c.id)
        await refreshCascade()
    }

    // MARK: подписка

    private static func cascClientName(_ c: CascadeServer) -> String {
        let n = String(c.name.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        return n.isEmpty ? "CASCADE" : n
    }

    /// Clash-ссылка для каскада: клиент главной / новый клиент на всех серверах / своя ссылка.
    func chooseSubscription(_ c: CascadeServer) async -> (url: String, client: String?)? {
        let hasMaster = master != nil && !clients.isEmpty
        var opts: [String] = []
        if hasMaster {
            opts.append("Клиент главной — выбрать из списка")
            opts.append("Новый клиент «\(Self.cascClientName(c))» на всех серверах")
        }
        opts.append("Своя ссылка (Clash / Mihomo)")
        guard let pick = await askPick(PickRequest(
            title: "Подписка каскада",
            text: "Откуда каскаду брать ноды. Нужна Clash/Mihomo-подписка единой подписки главной: имена нод = имена инбаундов " +
                  "(шаблон {{INBOUND}}), клиент привязан ко всем серверам. Ссылка уйдёт только на сервер (/etc/qcascade/env, 600)." +
                  (hasMaster ? "" : "\n\nГлавная 3x-ui в QTerm не подключена — только своя ссылка."),
            items: opts, selected: opts[0], ok: "Дальше", field: "Источник")) else { return nil }
        var choice = opts.firstIndex(of: pick) ?? -1
        if !hasMaster && choice >= 0 { choice += 2 }
        do {
            if choice == 0 || choice == 1 {
                guard let m = master else { return nil }
                if settings.isEmpty { settings = try await m.settings() }
                var cl: XClient?
                if choice == 0 {
                    let emails = clients.map(\.email).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    guard let em = await askPick(PickRequest(
                        title: "Подписка каскада",
                        text: "Клиент главной, чью подписку возьмёт каскад (лучше отдельный — у роутеров свои):",
                        items: emails, selected: c.client.flatMap { emails.contains($0) ? $0 : nil }, field: "Клиент")) else { return nil }
                    cl = clients.first { $0.email == em }
                    if cl == nil { XuiDialog.info("Нет клиента «\(em)»"); return nil }
                } else {
                    guard let name = XuiDialog.ask("Имя клиента каскада (создастся на всех серверах):", value: Self.cascClientName(c)) else { return nil }
                    cl = try await createCascClient(name)
                    if cl == nil { return nil }
                }
                guard let cl, let link = linkOf(cl, clash: true) else {
                    XuiDialog.info("В главной выключена Clash-подписка (или у клиента нет ID подписки): Настройки панели → Подписка → Clash / Mihomo — включить")
                    return nil
                }
                return (link, cl.email)
            }
            if choice < 0 { return nil }
            guard let f = XuiDialog.form("Clash/Mihomo-ссылка подписки — уйдёт только на сервер, в QTerm не хранится.",
                                         title: "Подписка каскада", [.init(label: "Ссылка", secure: true)], ok: "Дальше") else { return nil }
            let url = f[0].trimmingCharacters(in: .whitespaces)
            if url.isEmpty { return nil }
            guard url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") else {
                XuiDialog.info("Нужна http(s)-ссылка подписки"); return nil
            }
            return (url, nil)
        } catch {
            log("✗ подписка: " + error.localizedDescription, .err)
            return nil
        }
    }

    /// Клиент каскада на всех серверах единой подписки (имя через «Ревизию имён», как «＋ Клиент»).
    private func createCascClient(_ name: String) async throws -> XClient? {
        guard let m = master else { return nil }
        let u = unifier()
        let toks = XuiOps.stripTokens(inbounds, nodes)
        let key = u.analyze(name, toks).key
        if let exist = clients.first(where: { u.analyze($0.email, toks).key == key }) {
            return XuiDialog.confirm("Клиент «\(exist.email)» уже есть — взять его подписку?", title: "Подписка каскада", yes: "Взять") ? exist : nil
        }
        let ids = inbounds.filter { $0.multiUser && $0.enable }.map(\.id)
        if ids.isEmpty { XuiDialog.info("На главной нет подходящих входящих"); return nil }
        let (pv, ph) = XuiOps.protos(ids, XuiOps.byId(inbounds))
        let display = u.displayFor(key, [name], name, vless: pv, hys: ph)
        try await m.addClient(display, ids)
        log("  ✓ клиент каскада \(display): входящих \(ids.count) на всех серверах", .ok)
        clients = try await m.clients()
        guard let c = clients.first(where: { $0.email == display }) else {
            throw XuiError("клиент \(display) создан, но главная его не вернула — обнови и выбери из списка")
        }
        return c
    }

    func cascSub() async {
        guard let c = cascSel else { XuiDialog.info("Сначала добавь каскад-сервер"); return }
        guard cascVersion != nil else { XuiDialog.info("Каскад на сервере не установлен — «Установить / обновить…» спросит подписку сам"); return }
        guard let s = await chooseSubscription(c) else { return }
        await cascOp("Подписка") { cs, r in
            try await r.set([("QC_SUB_URL", s.url)])
            var cc = cs
            cc.client = s.client
            self.store.saveCascade(cc)
            self.cascades = self.store.cascades()
            self.log("  ✓ подписка: \(s.client.map { "клиент " + $0 } ?? "своя ссылка")", .ok)
            try await self.cascApplyCore(r)
        }
    }

    // MARK: установка

    func cascInstall() async {
        guard let c = cascSel else { XuiDialog.info("Сначала добавь каскад-сервер: «＋ Сервер…»"); return }
        if cascBusy || busy || updBusy { log("! дождись окончания текущей операции", .warn); return }
        let ver: String?
        do { ver = try await remote(c).remoteVersion() } catch { log("✗ " + error.localizedDescription, .err); return }
        let mine = CascadeRemote.scriptVersion
        var sub: (url: String, client: String?)?
        var mode = "all"
        if ver == nil {
            guard XuiDialog.confirm(
                "Поставить каскад на «\(c.name)»?\n\n" +
                "• mihomo (ядро MetaCubeX) отдельным сервисом, слушает только 127.0.0.1\n" +
                "• правила и группы как на Кинетиках (свои .mrs роутеров встроены), ноды — из подписки главной\n" +
                "• в шаблон Xray 3x-ui — выход в mihomo и правило перехвата; перед правкой бэкап базы, при сбое откат\n" +
                "• таймер раз в час сверяет подписку и добавляет группы новым нодам\n\n" +
                "Нужен root (или sudo без пароля) и 3x-ui на сервере.",
                title: "Каскад", yes: "Дальше") else { return }
            guard let s = await chooseSubscription(c) else { return }
            sub = s
            let all = "Всех клиентов (VLESS, Hysteria, AWG)"
            guard let m = await askPick(PickRequest(
                title: "Каскад",
                text: "Кого пускать через каскад сразу после установки? Поменять можно потом — «Кого каскадить…».",
                items: [all, "Никого — только поставить mihomo"], selected: all, ok: "Установить", field: "Режим")) else { return }
            mode = m.hasPrefix("Никого") ? "off" : "all"
        } else if !XuiDialog.confirm(
            "На «\(c.name)» qcascade \(ver!), в QTerm — \(mine).\n\nЗалить скрипт из QTerm и прогнать установку заново? " +
            "Подписка, правила, группы и режим перехвата на сервере сохраняются.",
            title: "Каскад", yes: "Обновить") { return }

        let subNow = sub, modeNow = mode
        await cascOp(ver == nil ? "Установка каскада" : "Обновление каскада \(ver!) → \(mine)") { cs, r in
            self.log("  заливаю скрипт qcascade \(mine)…", .dim)
            try await r.uploadScript()
            if let s = subNow {
                try await r.set([("QC_SUB_URL", s.url), ("QC_XRAY_MODE", modeNow), ("QC_XRAY_LIST", "")], viaScript: true)
                var cc = cs
                cc.client = s.client
                self.store.saveCascade(cc)
                self.cascades = self.store.cascades()
            }
            self.log("  установка идёт на сервере в фоне (переживёт обрыв SSH):", .dim)
            try await r.startInstall()
            var have = 0, fails = 0
            let t0 = Date()
            var rc: Int?
            while rc == nil {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Date().timeIntervalSince(t0) > 20 * 60 {
                    throw XuiError("установка идёт дольше 20 минут — лог на сервере: ~/.qcascade-install.log")
                }
                do {
                    let p = try await r.pollInstall(have)
                    self.logQc(p.lines.joined(separator: "\n"))
                    have = p.total
                    rc = p.rc
                    fails = 0
                } catch {
                    fails += 1
                    if fails >= 10 { throw error }
                    if fails == 1 { self.log("  … связь с сервером: \(error.localizedDescription) — жду", .warn) }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            if rc != 0 { throw XuiError("установка закончилась с ошибкой (код \(rc!)) — причина выше") }
            self.log("  ✓ каскад на «\(cs.name)» работает", .ok)
        }
    }

    func cascApplyCore(_ r: CascadeRemote) async throws {
        let res = try await r.qc("apply", 300)
        logQc(res.out)
        if !res.ok { throw XuiError("конфиг не применён — работает прежний (причина выше)") }
    }

    func cascApply() async {
        await cascOp("Применить") { _, r in try await self.cascApplyCore(r) }
    }

    // MARK: кого каскадить

    func cascWho() async {
        guard let c = cascSel, cascVersion != nil else { XuiDialog.info("Каскад на сервере не установлен"); return }
        let lst: JObj
        do { lst = try await remote(c).xrayList() } catch { log("✗ " + error.localizedDescription, .err); return }
        guard J.bool(lst, "xui") else { XuiDialog.info("На сервере нет 3x-ui — перехватывать нечего"); return }
        let env = cascStatus?["env"] as? JObj ?? [:]
        let cur = J.str(env, "xrayMode")
        let curList = Set(J.str(env, "xrayList").split(separator: " ").map(String.init))
        let opts = ["Всех клиентов (VLESS, Hysteria, AWG)", "Выбранные инбаунды…", "Выбранных клиентов…", "Никого — выключить перехват"]
        let curText = cur == "inbounds" ? opts[1] : cur == "users" ? opts[2] : cur == "off" ? opts[3] : opts[0]
        guard let pick = await askPick(PickRequest(
            title: "Кого каскадить",
            text: "Кого пускать через каскад. Остальные идут напрямую с сервера, как без каскада.",
            items: opts, selected: curText, ok: "Дальше", field: "Режим")) else { return }
        let mode: String
        switch opts.firstIndex(of: pick) { case 1: mode = "inbounds"; case 2: mode = "users"; case 3: mode = "off"; default: mode = "all" }
        var list = ""
        if mode == "inbounds" || mode == "users" {
            let items: [(key: String, text: String)] = mode == "inbounds"
                ? ((lst["inbounds"] as? [Any]) ?? []).compactMap { $0 as? JObj }.map {
                    (key: J.str($0, "tag"), text: "\(J.str($0, "remark"))   ·   \(J.str($0, "protocol"))   ·   \(J.str($0, "tag"))")
                  }
                : Self.list(lst, "emails").map { (key: $0, text: $0) }
            guard let sel = await askChecks(CheckRequest(
                title: "Кого каскадить",
                text: mode == "inbounds" ? "Инбаунды 3x-ui, чьи клиенты идут через каскад:"
                                         : "Клиенты (VLESS, Hysteria и AWG по имени), которые идут через каскад:",
                items: items, selected: cur == mode ? curList : [])) else { return }
            if sel.isEmpty { XuiDialog.info("Ничего не выбрано"); return }
            list = sel.joined(separator: " ")
        }
        let l = list
        await cascOp("Кого каскадить") { _, r in
            try await r.set([("QC_XRAY_MODE", mode), ("QC_XRAY_LIST", l)])
            self.log("  3x-ui перезапускается — клиенты переподключатся", .dim)
            let res = try await r.qc(mode == "off" ? "xray off" : "xray on", 180)
            self.logQc(res.out)
            if !res.ok { throw XuiError("перехват не переключился — 3x-ui в прежнем состоянии (причина выше)") }
        }
    }

    // MARK: DIRECT

    func cascDirect() async {
        guard cascSel != nil, let st = cascStatus else { XuiDialog.info("Каскад на сервере не установлен"); return }
        let direct = "DIRECT — напрямую с этого сервера"
        let groups = ((st["groups"] as? [Any]) ?? []).compactMap { $0 as? JObj }.map { J.str($0, "name") }.filter { !$0.isEmpty }
        let cur = J.str(st["env"] as? JObj ?? [:], "directTarget")
        guard let pick = await askPick(PickRequest(
            title: "DIRECT →",
            text: "Куда отправлять DIRECT из правил — ru-трафик, госуслуги, MATCH. DIRECT = IP этого сервера: если он за границей, российское лучше вести через MSK.",
            items: [direct] + groups, selected: cur.isEmpty || cur == "DIRECT" ? direct : cur, ok: "Применить", field: "Куда")) else { return }
        let target = pick == direct ? "DIRECT" : pick.trimmingCharacters(in: .whitespaces)
        await cascOp("DIRECT → \(target)") { _, r in
            try await r.set([("QC_DIRECT_TARGET", target)])
            try await self.cascApplyCore(r)
        }
    }

    // MARK: группы и правила

    func cascGroups() async {
        await cascEditRemote("\(Self.cascConf)/groups.conf", "Группы каскада",
            "Составные группы, как на Кинетиках: ИМЯ ТИП ИНТЕРВАЛ УЧАСТНИКИ… (по приоритету). На каждую ноду подписки группа с тем же " +
            "именем создаётся сама. Участники, которых нет в подписке, пропускаются. Сохранение = применение с проверкой и откатом.")
    }

    func cascRules() async {
        await cascEditRemote("\(Self.cascConf)/rules.yaml", "Правила каскада",
            "rule-providers и rules — тот же формат, что в config.yaml Кинетика (пути /opt/etc/mihomo/… переписываются сами). " +
            "Сохранение = применение: конфиг с ошибкой не встанет, работает прежний.")
    }

    private func cascEditRemote(_ path: String, _ title: String, _ caption: String) async {
        guard let c = cascSel, cascVersion != nil else { XuiDialog.info("Каскад на сервере не установлен"); return }
        let text: String
        do { text = try await remote(c).readRootFile(path) } catch { log("✗ " + error.localizedDescription, .err); return }
        guard let edited = await askText(TextEditRequest(title: "\(title) · \(c.name)", caption: caption + "\n" + path, text: text)) else { return }
        await cascOp("\(title): сохранить и применить") { _, r in
            try await r.writeRootFile(path, edited)
            self.log("  ✓ \(path) записан", .ok)
            try await self.cascApplyCore(r)
        }
    }

    // MARK: ядро, журнал, удаление

    func cascCore() async {
        guard cascSel != nil, cascVersion != nil else { XuiDialog.info("Каскад на сервере не установлен"); return }
        let cur = J.str(cascStatus?["env"] as? JObj ?? [:], "mihomoUrl")
        guard let f = XuiDialog.form(
            "Ядро mihomo. Пусто — последний стоковый MetaCubeX. Своя сборка (например ff148 с firefox-отпечатком) — прямая ссылка " +
            "на .gz или бинарь под архитектуру сервера. Новое ядро сначала проверяет текущий конфиг, при сбое — откат.",
            title: "Ядро mihomo", [.init(label: "Ссылка на ядро (пусто — стоковое)", value: cur)], ok: "Обновить") else { return }
        let url = f[0].trimmingCharacters(in: .whitespaces)
        await cascOp("Ядро mihomo") { _, r in
            if url != cur { try await r.set([("QC_MIHOMO_URL", url)]) }
            let res = try await r.qc("update-core", 600)
            self.logQc(res.out)
            if !res.ok { throw XuiError("ядро не обновилось (причина выше)") }
        }
    }

    func cascLogs() async {
        guard let c = cascSel, cascVersion != nil else { XuiDialog.info("Каскад на сервере не установлен"); return }
        do {
            let res = try await remote(c).qc("logs 300", 60)
            _ = await askText(TextEditRequest(title: "Журнал mihomo · \(c.name)", caption: "journalctl -u qcascade, последние 300 строк",
                                              text: res.out, readOnly: true))
        } catch { log("✗ " + error.localizedDescription, .err) }
    }

    func cascRemove() async {
        guard let c = cascSel else { return }
        var opts: [String] = []
        if cascVersion != nil {
            opts.append("Снять перехват и удалить qcascade (правила и подписку на сервере оставить)")
            opts.append("Удалить с сервера полностью (--purge)")
        }
        opts.append("Только убрать сервер из списка QTerm")
        guard let pick = await askPick(PickRequest(
            title: "Убрать каскад",
            text: "«\(c.name)»: что сделать? Перехват снимается первым — клиенты 3x-ui снова пойдут напрямую.",
            items: opts, selected: opts.last, ok: "Выполнить", field: "Действие")), opts.contains(pick) else { return }
        if pick.hasPrefix("Только") {
            store.deleteCascade(c.id)
            cascRemotes[c.id] = nil
            log("✓ «\(c.name)» убран из QTerm (на сервере ничего не трогал)", .ok)
            cascLoad()
            await refreshCascade()
            return
        }
        let purge = pick.contains("--purge")
        guard XuiDialog.confirm("Точно \(purge ? "удалить каскад полностью" : "удалить qcascade") с «\(c.name)»?", title: "Убрать каскад", yes: "Удалить") else { return }
        await cascOp("Удаление каскада", refresh: false) { cs, r in
            let res = try await r.qc(purge ? "uninstall --purge" : "uninstall", 300)
            self.logQc(res.out)
            if !res.ok { throw XuiError("не удалилось (причина выше)") }
            self.store.deleteCascade(cs.id)
            self.cascRemotes[cs.id] = nil
            self.log("  ✓ каскад с «\(cs.name)» снят, сервер убран из QTerm", .ok)
        }
        cascLoad()
        await refreshCascade()
    }
}

// MARK: - листы

struct TextEditSheet: View {
    let req: TextEditRequest
    let finish: (String?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(req.title).font(.title3.bold())
            Text(req.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 360)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button(req.readOnly ? "Закрыть" : "Отмена") { finish(nil) }.keyboardShortcut(.cancelAction)
                if !req.readOnly {
                    Button("Сохранить и применить") { finish(text != req.text ? text : nil) }
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { text = req.text }
    }
}

struct CheckSheet: View {
    let req: CheckRequest
    let finish: ([String]?) -> Void
    @State private var on = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(req.title).font(.title3.bold())
            Text(req.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(req.items, id: \.key) { it in
                Toggle(it.text, isOn: Binding(
                    get: { on.contains(it.key) },
                    set: { v in if v { on.insert(it.key) } else { on.remove(it.key) } }))
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Отмена") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { finish(req.items.map(\.key).filter { on.contains($0) }) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 520)
        .onAppear { on = req.selected }
    }
}
