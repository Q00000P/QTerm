import SwiftUI
import AppKit
import SessionVaultKit

// Окно «Каскад» (порт CascadeWindow Windows, волна 38) — отдельное окно рядом с терминалом и «Нодами 3x-ui»:
// каскад-серверы слева; справа — обзор, источники нод (две логики: свой клиент каскада на любой панели 3x-ui
// с нужным набором инбаундов и подписки отдельных нод / WireGuard), кто идёт в каскад (3x-ui, AWG-панель,
// MTProto), группы, правила, журнал. qcascade на сервере управляется exec-каналом SSH, терминал не трогается.

struct CascGroupRow: Identifiable {
    var id: String { name }
    let name: String
    let node: String
    let delay: String
    let dot: Color
}

struct CascSourceRow: Identifiable {
    var id: String { src.name }
    let src: CascadeSource
    let nodes: String
    let state: String
    let dot: Color
    var name: String { src.name }
    var typeText: String { src.isWg ? "WireGuard" : "подписка" }
}

/// Что известно о сервере по последнему опросу.
struct CascSrvState {
    var checked = false
    var version: String?
    var status: JObj?
    var detect: JObj?
    var pending = false
    var error: String?
    var at = Date()
}

struct CascCard {
    enum Action { case add, refresh, install }
    let title: String
    let text: String
    let button: String
    let action: Action
}

/// Лист «свой клиент каскада на панели 3x-ui».
final class XuiSourceRequest: Identifiable {
    let id = UUID()
    let server: String
    let edit: CascadeSource?
    let taken: Set<String>
    var done: ((CascadeSource?) -> Void)?
    init(server: String, edit: CascadeSource?, taken: Set<String>) { self.server = server; self.edit = edit; self.taken = taken }
    func finish(_ v: CascadeSource?) { let d = done; done = nil; d?(v) }
}

/// Лист «WireGuard / AWG».
final class WgSourceRequest: Identifiable {
    let id = UUID()
    let server: String
    let edit: CascadeSource?
    let isReserve: Bool
    let taken: Set<String>
    var done: (((source: CascadeSource, reserve: Bool)?) -> Void)?
    init(server: String, edit: CascadeSource?, isReserve: Bool, taken: Set<String>) {
        self.server = server; self.edit = edit; self.isReserve = isReserve; self.taken = taken
    }
    func finish(_ v: (source: CascadeSource, reserve: Bool)?) { let d = done; done = nil; d?(v) }
}

/// Лист первой установки: источники и кого пускать через каскад.
final class InstallRequest: Identifiable {
    let id = UUID()
    let server: CascadeServer
    var done: (((sources: [CascadeSource], env: [(String, String)])?) -> Void)?
    init(server: CascadeServer) { self.server = server }
    func finish(_ v: (sources: [CascadeSource], env: [(String, String)])?) { let d = done; done = nil; d?(v) }
}

@MainActor
final class CascadeModel: ObservableObject {
    enum Seg: String, CaseIterable, Identifiable {
        case overview = "Обзор", sources = "Источники нод", who = "Кто идёт в каскад"
        case groups = "Группы", rules = "Правила", journal = "Журнал"
        var id: String { rawValue }
    }

    static let etc = "/etc/qcascade"
    static let noReserve = "— без резерва —"

    var store: XuiStore { XuiCenter.shared.store! }

    @Published var servers: [CascadeServer] = []
    @Published var selId: String = "" { didSet { if oldValue != selId && !loading { selChanged() } } }
    @Published var seg: Seg = .overview { didSet { if oldValue != seg { segChanged() } } }
    @Published var states: [String: CascSrvState] = [:]
    @Published var logLines: [LogLine] = []
    @Published var busy = false
    private var refreshing = false
    private var loading = false
    private var remotes: [String: CascadeRemote] = [:]

    /// exec по SSH-сессии: (id сессии, команда, таймаут с) → stdout. Ставит окно — из AppState.
    var execInSession: ((UUID, String, Int) async throws -> String)?
    /// Живое ли соединение сессии — автообновление не открывает вкладки само.
    var sessionConnected: ((UUID) -> Bool)?

    // листы
    @Published var pickRequest: PickRequest?
    @Published var xuiSource: XuiSourceRequest?
    @Published var wgSource: WgSourceRequest?
    @Published var install: InstallRequest?

    // источники
    @Published var sourceSel: String?

    // группы, правила, журнал
    @Published var groupsText = ""
    @Published var rulesText = ""
    @Published var journalText = ""
    private var groupsOrig = "", rulesOrig = ""
    private var groupsFor: String?, rulesFor: String?

    // «кто идёт в каскад» — выбор на экране; автообновление его не трогает
    @Published var xrayMode = "all"
    @Published var xraySel = Set<String>()
    @Published var awgMode = "all"
    @Published var awgSel = Set<String>()
    @Published var awgSrc = ""
    @Published var mtpOn = false
    @Published var mtpUsers = "telemt mtproxy"
    /// Для какого сервера выбор «кто идёт» снят с сервера (автообновление его не перетирает).
    var whoFor: String?

    init() { load() }

    // MARK: лог

    func log(_ s: String, _ k: LogKind = .info) {
        logLines.append(LogLine(text: s, kind: k))
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    func logQc(_ text: String) {
        for raw in CascadeRemote.clean(text).replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            let k: LogKind = l.hasPrefix("[ok]") ? .ok : l.hasPrefix("[!!]") ? .warn : l.hasPrefix("──") ? .head : .info
            log("  " + raw.trimmingCharacters(in: .whitespacesAndNewlines), k)
        }
    }

    // MARK: серверы

    var sel: CascadeServer? { servers.first { $0.id == selId } }

    func st(_ c: CascadeServer) -> CascSrvState { states[c.id] ?? CascSrvState() }

    /// Выбранный сервер на qcascade 2.x с известным статусом.
    var ready: (c: CascadeServer, st: CascSrvState, status: JObj)? {
        guard let c = sel else { return nil }
        let s = st(c)
        guard let status = s.status, CascadeRemote.isV2(s.version) else { return nil }
        return (c, s, status)
    }

    func load(pick: String? = nil) {
        let keep = pick ?? sel?.id
        loading = true
        servers = store.cascades()
        selId = servers.first(where: { $0.id == keep })?.id ?? servers.first?.id ?? ""
        loading = false
    }

    private func selChanged() {
        whoFor = nil
        Task { await refresh() }
    }

    private func segChanged() {
        switch seg {
        case .who: Task { await refresh(quiet: true, detect: true) }
        case .groups: Task { await loadGroups() }
        case .rules: Task { await loadRules() }
        case .journal: Task { await loadJournal() }
        default: break
        }
    }

    private func sid(_ c: CascadeServer) -> UUID? {
        guard let id = c.sessionID, store.sessions().contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func remote(_ c: CascadeServer) throws -> CascadeRemote {
        guard let exec = execInSession else { throw XuiError("SSH QTerm недоступен из этого окна") }
        guard let sid = sid(c) else { throw XuiError("у «\(c.name)» нет SSH-сессии в QTerm — убери сервер и добавь заново") }
        if let r = remotes[c.id] { return r }
        let r = CascadeRemote { cmd, t in try await exec(sid, cmd, t) }
        remotes[c.id] = r
        return r
    }

    private func edit(_ c: CascadeServer, _ f: (inout CascSrvState) -> Void) {
        var s = states[c.id] ?? CascSrvState()
        f(&s)
        states[c.id] = s
    }

    /// Одна операция за раз; ошибки — в лог; после — опрос. true — без ошибок.
    @discardableResult
    func op(_ title: String, refresh: Bool = true, _ body: @escaping @MainActor (CascadeServer, CascadeRemote) async throws -> Void) async -> Bool {
        if busy { log("! дождись окончания текущей операции", .warn); return false }
        guard let c = sel else { XuiDialog.info("Сначала добавь каскад-сервер: «＋ Сервер…»", title: "Каскад"); return false }
        busy = true
        log("━━ \(title) · \(c.name)", .head)
        var ok = false
        do { try await body(c, try remote(c)); ok = true } catch { log("✗ " + error.localizedDescription, .err) }
        busy = false
        if refresh { await self.refresh(quiet: true, detect: seg == .who) }
        return ok
    }

    func tick() async {
        guard !busy, !refreshing, let c = sel, let id = sid(c), sessionConnected?(id) == true else { return }
        await refresh(quiet: true)
    }

    func refresh(quiet: Bool = false, detect: Bool = false) async {
        guard let c = sel, execInSession != nil, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if !quiet { edit(c) { $0.error = nil } }
        do {
            let r = try remote(c)
            let ver = try await r.remoteVersion()
            var status: JObj?
            var det = st(c).detect
            if ver != nil {
                status = try await r.status()
                if CascadeRemote.isV2(ver) && (detect || det == nil || seg == .who) { det = try await r.detect() }
            }
            edit(c) { s in
                s.version = ver
                s.status = status
                s.detect = ver == nil ? nil : det
                if ver == nil { s.pending = false }
                if let p = status?["pending"] as? Bool, p { s.pending = true }
                s.error = nil
                s.checked = true
                s.at = Date()
            }
        } catch {
            edit(c) { $0.error = error.localizedDescription }
            if !quiet { log("✗ " + error.localizedDescription, .err) }
        }
        syncWho(full: whoFor != c.id)
    }

    // MARK: отрисовка

    static func list(_ o: Any?, _ k: String) -> [String] {
        (((o as? JObj)?[k] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    static func objs(_ o: Any?, _ k: String) -> [JObj] {
        (((o as? JObj)?[k] as? [Any]) ?? []).compactMap { $0 as? JObj }
    }

    func subtitle(_ c: CascadeServer) -> String {
        let s = st(c)
        if let e = s.error { return "✗ " + e }
        if !s.checked { return "не опрошен" }
        guard let v = s.version else { return "каскад не установлен" }
        if !CascadeRemote.isV2(v) { return "qcascade \(v) — нужно обновить" }
        let mh = s.status?["mihomo"] as? JObj ?? [:]
        if !J.bool(mh, "active") { return "mihomo не работает" }
        return "работает · нод \(Self.list(s.status?["state"], "nodes").count)" + (s.pending ? " · не применено" : "")
    }

    func dot(_ c: CascadeServer) -> Color {
        let s = st(c)
        if s.error != nil { return .red }
        guard s.checked, let v = s.version else { return .secondary }
        if !CascadeRemote.isV2(v) { return .orange }
        if !J.bool(s.status?["mihomo"] as? JObj ?? [:], "active") { return .red }
        return s.pending ? .orange : .green
    }

    var headStatus: String {
        guard let c = sel else { return "" }
        let s = st(c)
        if let e = s.error { return "✗ " + e }
        if !s.checked { return "опрашиваю…" }
        guard let v = s.version else { return "каскад не установлен" }
        let mh = s.status?["mihomo"] as? JObj ?? [:]
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return "qcascade \(v) · mihomo \(J.str(mh, "version")) " + (J.bool(mh, "active") ? "работает" : "НЕ РАБОТАЕТ") +
            (s.pending ? " · есть неприменённые изменения" : "") + " · \(f.string(from: s.at))"
    }

    var installTitle: String {
        guard let c = sel, let v = st(c).version else { return "Установить…" }
        let mine = CascadeRemote.scriptVersion
        return CascadeRemote.newer(mine, v) ? "Обновить до \(mine)…" : "Переустановить…"
    }

    var pending: Bool { sel.map { st($0).pending } ?? false }

    var card: CascCard? {
        guard let c = sel else {
            return CascCard(
                title: "Каскад-серверов пока нет",
                text: "Каскад — сервер (с 3x-ui, AWG-панелью, MTProto-прокси), который ведёт трафик своих клиентов через mihomo " +
                    "с правилами как на Кинетиках:\n\n" +
                    "• ноды — из своих источников: отдельный клиент каскада на любой панели 3x-ui со своим набором инбаундов, " +
                    "ссылки подписок отдельных нод, WireGuard/AWG (можно резервом);\n" +
                    "• через каскад идут клиенты 3x-ui (VLESS, Hysteria), AWG-панели и Telegram-трафик MTProto-прокси;\n" +
                    "• всё, что не DIRECT, при недоступности нод уходит в резерв.\n\n«＋ Сервер…» → SSH-сессия сервера → «Установить…».",
                button: "＋ Сервер…", action: .add)
        }
        let s = st(c)
        let mine = CascadeRemote.scriptVersion
        if !s.checked, let e = s.error {
            return CascCard(title: "Нет связи с «\(c.name)»",
                            text: e + "\n\nSSH-сессия сервера откроется вкладкой в QTerm (вход, ключи — как обычно).",
                            button: "Повторить", action: .refresh)
        }
        if s.checked && s.version == nil && s.error == nil {
            return CascCard(
                title: "Каскад на «\(c.name)» не установлен",
                text: "«Установить…»: выбрать источники нод и кого пускать через каскад — QTerm сам зальёт скрипт, установка пойдёт " +
                    "на сервере в фоне (переживёт обрыв SSH), ход — в логе внизу.\n\n" +
                    "• mihomo отдельным сервисом, слушает только 127.0.0.1\n" +
                    "• правила и группы как на Кинетиках (свои .mrs роутеров встроены)\n" +
                    "• перехват клиентов 3x-ui — правкой шаблона Xray (с бэкапом базы и откатом), AWG-панели и MTProto — nftables\n" +
                    "• таймер раз в час сверяет источники\n\nНужен root (или sudo без пароля).",
                button: "Установить…", action: .install)
        }
        if let v = s.version, !CascadeRemote.isV2(v), seg != .journal {
            return CascCard(
                title: "На «\(c.name)» qcascade \(v) — QTerm работает с \(mine)",
                text: "Нужно обновить скрипт на сервере. Подписка станет источником «SUB», правила, группы и перехват 3x-ui сохранятся. " +
                    "После обновления — свои источники нод, WireGuard и резерв, перехват AWG-панели и MTProto.",
                button: "Обновить до \(mine)…", action: .install)
        }
        return nil
    }

    func cardAction(_ a: CascCard.Action) async {
        switch a {
        case .add: await addServer()
        case .refresh: await refresh()
        case .install: await installTap()
        }
    }

    static func xrayText(_ x: String) -> String {
        switch x {
        case "off": return "никто — клиенты 3x-ui идут напрямую"
        case "all": return "все клиенты"
        case "нет 3x-ui": return "на сервере нет 3x-ui"
        default:
            if x.hasPrefix("users: ") { return "клиенты: " + x.dropFirst(7) }
            if x.hasPrefix("inbounds: ") { return "инбаунды: " + x.dropFirst(10) }
            return x
        }
    }

    var groupRows: [CascGroupRow] {
        guard let r = ready else { return [] }
        return Self.objs(r.status, "groups").map { g in
            let name = J.str(g, "name")
            if J.bool(g, "missing") { return CascGroupRow(name: name, node: "—", delay: "нет группы", dot: .red) }
            let direct = g["delay"] == nil || g["delay"] is NSNull
            let d = direct ? 0 : J.int(g, "delay")
            let res = J.bool(g, "reserve")
            return CascGroupRow(
                name: name, node: J.str(g, "node") + (res ? "  (резерв)" : ""),
                delay: direct ? "напрямую" : d > 0 ? "\(d) мс" : d < 0 ? "ещё не проверялась" : "нет ответа",
                dot: direct ? .orange : d > 0 ? (res ? .orange : .green) : d < 0 ? .secondary : .red)
        }
    }

    /// Источники из статуса — без ссылок и конфигов (их сервер в статус не отдаёт).
    var shownSources: [CascadeSource] {
        guard let r = ready else { return [] }
        return Self.objs(r.status, "sources").map(CascadeSource.init)
    }

    var reserve: String { J.str(ready?.status["env"] as? JObj ?? [:], "reserve") }
    var directTarget: String { let d = J.str(ready?.status["env"] as? JObj ?? [:], "directTarget"); return d.isEmpty ? "DIRECT" : d }

    var sourceRows: [CascSourceRow] {
        guard let r = ready else { return [] }
        let srcState = Self.objs(r.status["state"], "sources")
        let res = reserve
        return shownSources.map { x in
            let ss = srcState.first { J.str($0, "name") == x.name }
            let n = ss.map { J.int($0, "nodes") }
            let err = ss.map { J.str($0, "error") } ?? ""
            var state: String
            var dot: Color
            if !x.enabled { state = "выключен"; dot = .secondary }
            else if ss == nil { state = "не применён — «Применить»"; dot = .orange }
            else if !err.isEmpty { state = err; dot = (n ?? 0) > 0 ? .orange : .red }
            else if x.isWg { state = "ok"; dot = .green }
            else { state = (n ?? 0) > 0 ? "ok" : "нод нет"; dot = (n ?? 0) > 0 ? .green : .red }
            if x.name == res { state = "резерв · " + state }
            return CascSourceRow(src: x, nodes: x.isWg ? "1" : n.map(String.init) ?? "—", state: state, dot: dot)
        }
    }

    var reserveItems: [String] {
        guard let r = ready else { return [Self.noReserve] }
        var items = [Self.noReserve]
        items += shownSources.filter { $0.isWg && $0.enabled }.map(\.name)
        for n in Self.list(r.status["state"], "nodes") where !items.contains(n) { items.append(n) }
        let cur = reserve
        if !cur.isEmpty && !items.contains(cur) { items.append(cur) }
        return items
    }

    var directItems: [String] {
        guard let r = ready else { return ["DIRECT"] }
        var items = ["DIRECT"] + Self.objs(r.status, "groups").map { J.str($0, "name") }.filter { !$0.isEmpty }
        if !items.contains(directTarget) { items.append(directTarget) }
        return items
    }

    var info: String {
        guard let r = ready else { return "" }
        let s = r.status
        let env = s["env"] as? JObj ?? [:]
        let state = s["state"] as? JObj ?? [:]
        let mh = s["mihomo"] as? JObj ?? [:]
        var lines: [String] = []
        lines.append("mihomo      \(J.bool(mh, "active") ? "работает" : "НЕ РАБОТАЕТ — «Журнал»") \(J.str(mh, "version"))")
        var built = J.str(state, "built")
        if let d = ISO8601DateFormatter().date(from: built) { let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"; built = f.string(from: d) }
        lines.append("qcascade    \(r.st.version ?? "?") · конфиг собран \(built.isEmpty ? "—" : built)")
        let srcState = Self.objs(state, "sources")
        let srcs = shownSources
        if srcs.isEmpty { lines.append("источники   НЕТ — «Источники нод»") }
        else {
            lines.append("источники   " + srcs.map { x -> String in
                let ss = srcState.first { J.str($0, "name") == x.name }
                let what = !x.enabled ? "выкл" : x.isWg ? "WireGuard" : ss == nil ? "не применён" : "\(J.int(ss!, "nodes")) нод"
                return "\(x.name) (\(what))"
            }.joined(separator: ", "))
        }
        let nodes = Self.list(state, "nodes")
        if !nodes.isEmpty { lines.append("ноды        " + nodes.joined(separator: ", ")) }
        lines.append("резерв      " + (reserve.isEmpty ? "нет" : reserve))
        lines.append("DIRECT →    " + directTarget)
        lines.append("")
        lines.append("3x-ui       " + Self.xrayText(J.str(s, "xray")))
        let am = J.str(env, "awgMode")
        let awgText = am == "all" ? "все интерфейсы wg*/awg*" : am == "list" ? "интерфейсы: " + J.str(env, "awgIfaces") : "никто"
        lines.append("AWG-панель  " + awgText + (am != "off" && !J.str(env, "awgSrc").isEmpty ? " · только \(J.str(env, "awgSrc"))" : ""))
        lines.append("MTProto     " + (J.str(env, "mtp") == "on" ? "Telegram — через каскад" : "выключено"))
        if am != "off" || J.str(env, "mtp") == "on" {
            lines.append("nftables    " + (J.bool(s, "nf") ? "правила перехвата стоят" : "НЕ СТОЯТ — «Применить» или «Журнал»"))
        }
        var warn: [String] = []
        for x in srcState where !J.str(x, "error").isEmpty { warn.append("\(J.str(x, "name")): \(J.str(x, "error"))") }
        let dup = Self.list(state, "duplicates")
        if !dup.isEmpty { warn.append("одинаковые имена нод в разных источниках: \(dup.joined(separator: ", ")) — задай источнику префикс") }
        let rm = Self.list(state, "reserveMissing")
        if !rm.isEmpty { warn.append("резерв «\(rm.joined(separator: ", "))» не найден среди нод — резерв выключен") }
        let mr = Self.list(state, "missingRulesets")
        if !mr.isEmpty { warn.append("нет rule-set на сервере (правила пропущены): " + mr.joined(separator: ", ")) }
        let fb = reserve.isEmpty ? "DIRECT" : "резерв"
        let ph = Self.list(state, "placeholders")
        if !ph.isEmpty { warn.append("правила ссылаются на то, чего нет в источниках (→ \(fb)): " + ph.joined(separator: ", ")) }
        let eg = Self.list(state, "emptyGroups")
        if !eg.isEmpty { warn.append("группы без нод из источников (→ \(fb)): " + eg.joined(separator: ", ")) }
        if r.st.pending { warn.append("есть неприменённые изменения — «Применить»") }
        if !warn.isEmpty { lines.append(""); lines += warn.map { "[!] " + $0 } }
        return lines.joined(separator: "\n")
    }

    // MARK: сервер: добавить / убрать / установить / применить

    func askPick(_ req: PickRequest) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            req.done = { cont.resume(returning: $0) }
            pickRequest = req
        }
    }

    func addServer() async {
        let sessions = store.sessions()
        if sessions.isEmpty { XuiDialog.info("В QTerm нет SSH-сессий — сначала добавь ноду сервера", title: "Каскад"); return }
        let items = sessions.map { "\($0.name)   ·   \($0.username.isEmpty ? "" : $0.username + "@")\($0.host)" }
        guard let pick = await askPick(PickRequest(
            title: "Каскад-сервер",
            text: "SSH-сессия сервера, который станет каскадом: трафик его клиентов (3x-ui, AWG-панель, MTProto) пойдёт в mihomo " +
                  "с правилами как на Кинетиках. Нужен root или sudo без пароля.",
            items: items, selected: nil, ok: "Добавить", field: "Сессия")) else { return }
        let typed = pick.trimmingCharacters(in: .whitespaces)
        let s: Session? = items.firstIndex(of: pick).map { sessions[$0] }
            ?? sessions.first(where: { $0.name.caseInsensitiveCompare(typed) == .orderedSame })
        guard let s else { XuiDialog.info("Нет SSH-сессии «\(pick)»", title: "Каскад"); return }
        if let dup = store.cascades().first(where: { UUID(uuidString: $0.ssh) == s.id }) {
            load(pick: dup.id)
            XuiDialog.info("«\(s.name)» уже в списке каскадов", title: "Каскад")
            return
        }
        var c = CascadeServer()
        c.name = s.name
        c.ssh = s.id.uuidString.lowercased()
        store.saveCascade(c)
        log("✓ каскад-сервер «\(c.name)» добавлен", .ok)
        load(pick: c.id)
        await refresh()
    }

    func removeServer() async {
        guard let c = sel else { return }
        var opts: [String] = []
        if st(c).version != nil {
            opts.append("Снять перехват и удалить qcascade (источники, правила и группы на сервере оставить)")
            opts.append("Удалить с сервера полностью (--purge)")
        }
        opts.append("Только убрать сервер из списка QTerm")
        guard let pick = await askPick(PickRequest(
            title: "Убрать каскад",
            text: "«\(c.name)»: что сделать? Перехват снимается первым — клиенты сервера снова пойдут напрямую. " +
                  "Клиенты каскада на панелях 3x-ui и AWG остаются (удалить — в «Источниках нод» до удаления сервера).",
            items: opts, selected: opts.last, ok: "Выполнить", field: "Действие")), opts.contains(pick) else { return }
        if pick.hasPrefix("Только") {
            store.deleteCascade(c.id)
            remotes[c.id] = nil
            states[c.id] = nil
            log("✓ «\(c.name)» убран из QTerm (на сервере ничего не трогал)", .ok)
            load()
            await refresh()
            return
        }
        let purge = pick.contains("--purge")
        guard XuiDialog.confirm("Точно \(purge ? "удалить каскад полностью" : "удалить qcascade") с «\(c.name)»?", title: "Убрать каскад", yes: "Удалить") else { return }
        await op("Удаление каскада", refresh: false) { cs, r in
            let res = try await r.qc(purge ? "uninstall --purge" : "uninstall", 300)
            self.logQc(res.out)
            if !res.ok { throw XuiError("не удалилось (причина выше)") }
            self.store.deleteCascade(cs.id)
            self.remotes[cs.id] = nil
            self.states[cs.id] = nil
            self.log("  ✓ каскад с «\(cs.name)» снят, сервер убран из QTerm", .ok)
        }
        load()
        await refresh()
    }

    func installTap() async {
        guard let c = sel else { XuiDialog.info("Сначала добавь каскад-сервер: «＋ Сервер…»", title: "Каскад"); return }
        if busy { log("! дождись окончания текущей операции", .warn); return }
        let ver: String?
        do { ver = try await remote(c).remoteVersion() } catch { log("✗ " + error.localizedDescription, .err); return }
        let mine = CascadeRemote.scriptVersion
        var first: [CascadeSource]?
        var env: [(String, String)]?
        if ver == nil {
            let req = InstallRequest(server: c)
            let plan = await withCheckedContinuation { (cont: CheckedContinuation<(sources: [CascadeSource], env: [(String, String)])?, Never>) in
                req.done = { cont.resume(returning: $0) }
                install = req
            }
            guard let plan else { return }
            first = plan.sources
            env = plan.env
        } else {
            let v = ver!
            let text = CascadeRemote.newer(mine, v)
                ? "На «\(c.name)» qcascade \(v), в QTerm — \(mine).\n\nЗалить скрипт из QTerm и прогнать установку? Источники (подписка v1 станет источником «SUB»), правила, группы и режимы перехвата сохраняются."
                : CascadeRemote.newer(v, mine)
                    ? "На «\(c.name)» qcascade \(v) — новее, чем в QTerm (\(mine)). Всё равно поставить \(mine)?"
                    : "Переустановить qcascade \(mine) на «\(c.name)»? Настройки, источники, правила и группы сохраняются."
            guard XuiDialog.confirm(text, title: "Каскад", yes: CascadeRemote.newer(mine, v) ? "Обновить" : "Переустановить") else { return }
        }
        let firstNow = first, envNow = env
        await op(ver == nil ? "Установка каскада" : "Установка qcascade \(mine)") { cs, r in
            self.log("  заливаю скрипт qcascade \(mine)…", .dim)
            try await r.uploadScript()
            if let envNow { try await r.set(envNow, viaScript: true) }
            self.log("  установка идёт на сервере в фоне (переживёт обрыв SSH):", .dim)
            try await r.startInstall(sourcesJSON: firstNow.map(CascadeRemote.sourcesJSON))
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
            self.edit(cs) { $0.pending = false }
            self.whoFor = nil
            self.log("  ✓ каскад на «\(cs.name)» работает", .ok)
        }
    }

    func applyCore(_ c: CascadeServer, _ r: CascadeRemote) async throws {
        let res = try await r.qc("apply", 600)
        logQc(res.out)
        if !res.ok { throw XuiError("конфиг не применён — работает прежний (причина выше)") }
        edit(c) { $0.pending = false }
    }

    func apply() async {
        await op("Применить") { c, r in try await self.applyCore(c, r) }
    }

    // MARK: DIRECT, резерв

    func setDirect(_ target: String) async {
        guard ready != nil, target != directTarget else { return }
        await op("DIRECT → \(target)") { c, r in
            try await r.set([("QC_DIRECT_TARGET", target)])
            self.edit(c) { $0.pending = true }
            self.log("  ✓ сохранено — в работу по «Применить»", .ok)
        }
    }

    func setReserve(_ pick: String) async {
        let val = pick == Self.noReserve ? "" : pick
        guard ready != nil, val != reserve else { return }
        await op(val.isEmpty ? "Резерв выключен" : "Резерв → \(val)") { c, r in
            try await r.set([("QC_RESERVE", val)])
            self.edit(c) { $0.pending = true }
            self.log("  ✓ сохранено — в работу по «Применить»", .ok)
        }
    }

    // MARK: группы, правила, журнал

    func loadGroups(force: Bool = false) async {
        guard let r0 = ready else { groupsText = ""; groupsFor = nil; return }
        if !force && groupsFor == r0.c.id { return }
        do {
            let t = try await remote(r0.c).readRootFile("\(Self.etc)/groups.conf")
            guard sel?.id == r0.c.id else { return }
            groupsOrig = t; groupsText = t; groupsFor = r0.c.id
        } catch { log("✗ " + error.localizedDescription, .err) }
    }

    func loadRules(force: Bool = false) async {
        guard let r0 = ready else { rulesText = ""; rulesFor = nil; return }
        if !force && rulesFor == r0.c.id { return }
        do {
            let t = try await remote(r0.c).readRootFile("\(Self.etc)/rules.yaml")
            guard sel?.id == r0.c.id else { return }
            rulesOrig = t; rulesText = t; rulesFor = r0.c.id
        } catch { log("✗ " + error.localizedDescription, .err) }
    }

    func saveGroups() async {
        guard let r0 = ready, groupsFor == r0.c.id else { XuiDialog.info("Текст ещё не загружен с сервера — «Вернуть»", title: "Каскад"); return }
        let text = groupsText
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == groupsOrig.trimmingCharacters(in: .whitespacesAndNewlines) && !r0.st.pending {
            XuiDialog.info("Изменений нет", title: "Каскад"); return
        }
        await op("Группы: сохранить и применить") { c, r in
            try await r.writeRootFile("\(Self.etc)/groups.conf", text)
            self.groupsOrig = text
            self.log("  ✓ \(Self.etc)/groups.conf записан", .ok)
            try await self.applyCore(c, r)
        }
    }

    func saveRules() async {
        guard let r0 = ready, rulesFor == r0.c.id else { XuiDialog.info("Текст ещё не загружен с сервера — «Вернуть»", title: "Каскад"); return }
        let text = rulesText
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == rulesOrig.trimmingCharacters(in: .whitespacesAndNewlines) && !r0.st.pending {
            XuiDialog.info("Изменений нет", title: "Каскад"); return
        }
        await op("Правила: сохранить и применить") { c, r in
            try await r.writeRootFile("\(Self.etc)/rules.yaml", text)
            self.rulesOrig = text
            self.log("  ✓ \(Self.etc)/rules.yaml записан", .ok)
            try await self.applyCore(c, r)
        }
    }

    func loadJournal() async {
        guard let c = sel, st(c).version != nil else { journalText = ""; return }
        do {
            let t = try await remote(c).logs(300)
            if sel?.id == c.id { journalText = t }
        } catch { log("✗ " + error.localizedDescription, .err) }
    }

    func core() async {
        guard let r0 = ready else { XuiDialog.info("Каскад на сервере не установлен", title: "Каскад"); return }
        let cur = J.str(r0.status["env"] as? JObj ?? [:], "mihomoUrl")
        guard let f = XuiDialog.form(
            "Ядро mihomo. Пусто — последний стоковый MetaCubeX. Своя сборка (например ff148 с firefox-отпечатком) — прямая ссылка " +
            "на .gz или бинарь под архитектуру сервера. Новое ядро сначала проверяет текущий конфиг, при сбое — откат.",
            title: "Ядро mihomo", [.init(label: "Ссылка на ядро (пусто — стоковое)", value: cur)], ok: "Обновить") else { return }
        let url = f[0].trimmingCharacters(in: .whitespaces)
        await op("Ядро mihomo") { _, r in
            if url != cur { try await r.set([("QC_MIHOMO_URL", url)]) }
            let res = try await r.qc("update-core", 600)
            self.logQc(res.out)
            if !res.ok { throw XuiError("ядро не обновилось (причина выше)") }
        }
    }

    /// zashboard: API mihomo слушает только 127.0.0.1 сервера — туннель SSH, адрес и secret.
    func dashboard() async {
        guard let r0 = ready else { XuiDialog.info("Каскад на сервере не установлен", title: "Каскад"); return }
        let api = J.str(r0.status["env"] as? JObj ?? [:], "api")
        guard let colon = api.lastIndex(of: ":") else { XuiDialog.info("Сервер не сообщил адрес API mihomo", title: "Каскад"); return }
        let port = String(api[api.index(after: colon)...])
        let sess = sid(r0.c).flatMap { id in store.sessions().first { $0.id == id } }
        let target = sess.map { s in "\(s.username.isEmpty ? "" : s.username + "@")\(s.host)" + (s.port == 22 || s.port == 0 ? "" : " -p \(s.port)") } ?? "root@<сервер>"
        var secret = ""
        do {
            let env = try await remote(r0.c).readRootFile("\(Self.etc)/env")
            if let line = env.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("QC_SECRET=") }) {
                secret = String(line.dropFirst("QC_SECRET=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        } catch { log("✗ " + error.localizedDescription, .err); return }
        XuiDialog.secret("API mihomo слушает только \(api) на сервере. Туннель (в отдельном терминале):\n\n" +
                         "  ssh -N -L \(port):\(api) \(target)\n\nпотом в браузере: http://127.0.0.1:\(port)/ui " +
                         "(бэкенд 127.0.0.1:\(port)). Secret — ниже.", title: "Панель mihomo", value: secret)
    }
}
