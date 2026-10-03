import Foundation

// AWG-панели: новая awg-panel (wg-easy v15, Basic-авторизация) и старая amnezia-wg-easy
// (wg-easy v14, вход паролем → cookie-сессия). Порт AwgApi.cs.

struct AwgClient: Identifiable {
    var id: String { panelId + "|" + cid }
    var panel = ""        // имя AWG-ноды в QTerm
    var panelId = ""
    var cid = ""
    var name = ""
    var interfaceId = ""
    var address = ""
    var enabled = true
    var expiresAt: String?
    var handshake: Date?
    var rx: Int64 = 0
    var tx: Int64 = 0
}

struct AwgInterface {
    var name = ""
    var port = 0
    var enabled = true
    var isAwg31 = false
    var label: String { "\(name) · AWG \(isAwg31 ? "3.1" : "2.0")" }
}

protocol AwgAPI: AnyObject {
    var label: String { get }
    func interfaces() async throws -> [AwgInterface]
    func clients(_ p: XuiPanel) async throws -> [AwgClient]
    func create(_ name: String, interfaceId: String?) async throws
    func delete(_ id: String) async throws
    func enable(_ id: String, _ on: Bool) async throws
    func config(_ id: String) async throws -> String
}

enum Awg {
    /// Клиент API под роль панели: «awg» — awg-panel, «awg1» — старая amnezia-wg-easy.
    static func api(_ p: XuiPanel) throws -> AwgAPI {
        p.isAwgLegacy
            ? try AwgLegacyAPI(label: p.name, url: p.url, password: p.token, verifyTls: p.verifyTls)
            : try AwgPanelAPI(label: p.name, url: p.url, login: p.login, password: p.token, verifyTls: p.verifyTls)
    }

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func msg(_ data: Data) -> String? {
        guard let o = J.parse(data) as? JObj else { return nil }
        return (o["message"] as? String) ?? (o["error"] as? String)
    }
}

/// awg-panel (wg-easy v15): Basic логин/пароль админа. С включённой 2FA Basic не пускает.
final class AwgPanelAPI: AwgAPI {
    let label: String
    private let base: String
    private let auth: String
    private let http: XuiHTTP

    init(label: String, url: String, login: String, password: String, verifyTls: Bool) throws {
        self.label = label
        base = try PanelURL.parse(url).base
        auth = "Basic " + Data("\(login):\(password)".utf8).base64EncodedString()
        http = XuiHTTP(label: label, verifyTls: verifyTls, cookies: false, timeout: 30)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, _ body: Any? = nil) async throws -> Data {
        let (code, data) = try await http.send(method, base + "/api" + path, json: body, headers: ["Authorization": auth])
        if code == 401 { throw XuiError("\(label): логин/пароль не подошли (401). С включённой 2FA вход по API невозможен") }
        if code == 403 { throw XuiError("\(label): 403 — \(Awg.msg(data) ?? "доступ запрещён")") }
        if code == 404 { throw XuiError("\(label): 404 на \(path) — это точно адрес awg-panel?") }
        if code >= 400 { throw XuiError("\(label): HTTP \(code) \(Awg.msg(data) ?? "")") }
        return data
    }

    func interfaces() async throws -> [AwgInterface] {
        let arr = (J.parse(try await send("GET", "/interfaces")) as? [Any]) ?? []
        return arr.compactMap { $0 as? JObj }.map {
            AwgInterface(name: J.str($0, "name"), port: J.int($0, "port"),
                         enabled: J.bool($0, "enabled", true), isAwg31: J.bool($0, "isAwg31"))
        }
    }

    func clients(_ p: XuiPanel) async throws -> [AwgClient] {
        let arr = (J.parse(try await send("GET", "/client")) as? [Any]) ?? []
        return arr.compactMap { $0 as? JObj }.map { o in
            var c = AwgClient()
            c.panel = p.name; c.panelId = p.id
            c.cid = J.str(o, "id")
            c.name = J.str(o, "name")
            c.interfaceId = J.str(o, "interfaceId", "wg0")
            c.address = J.str(o, "ipv4Address")
            c.enabled = J.bool(o, "enabled", true)
            c.expiresAt = o["expiresAt"] as? String
            c.handshake = Awg.date(o["latestHandshakeAt"])
            c.rx = J.long(o, "transferRx")
            c.tx = J.long(o, "transferTx")
            return c
        }
    }

    func create(_ name: String, interfaceId: String?) async throws {
        var body: JObj = ["name": name, "expiresAt": NSNull()]
        if let interfaceId { body["interfaceId"] = interfaceId }
        try await send("POST", "/client", body)
    }

    func delete(_ id: String) async throws { try await send("DELETE", "/client/" + xuiEscape(id)) }
    func enable(_ id: String, _ on: Bool) async throws {
        try await send("POST", "/client/" + xuiEscape(id) + (on ? "/enable" : "/disable"))
    }
    func config(_ id: String) async throws -> String {
        String(decoding: try await send("GET", "/client/" + xuiEscape(id) + "/configuration"), as: UTF8.self)
    }
}

/// Старая amnezia-wg-easy: только пароль. Вход — POST {base}/api/session {password} → cookie;
/// клиенты — /api/wireguard/client. Интерфейс один (wg0, AWG 2.0).
final class AwgLegacyAPI: AwgAPI {
    let label: String
    private let base: String
    private let password: String
    private let http: XuiHTTP
    private var authed = false

    init(label: String, url: String, password: String, verifyTls: Bool) throws {
        self.label = label
        base = try PanelURL.parse(url).base
        self.password = password
        http = XuiHTTP(label: label, verifyTls: verifyTls, cookies: true, timeout: 30)
    }

    private func login() async throws {
        let (code, data) = try await http.send("POST", base + "/api/session", json: ["password": password])
        if code == 401 {
            // панель без пароля (PASSWORD не задан) — API открыт и так
            let (c2, t2) = try await http.send("GET", base + "/api/session")
            if c2 == 200, let o = J.parse(t2) as? JObj, J.isBool(o["requiresPassword"]), !J.bool(o, "requiresPassword") {
                authed = true
                return
            }
            throw XuiError("\(label): пароль не подошёл (401)")
        }
        if code == 404 { throw XuiError("\(label): 404 на /api/session — проверь адрес панели (с секретным путём в конце)") }
        if code >= 400 { throw XuiError("\(label): вход — HTTP \(code) \(Awg.msg(data) ?? "")") }
        authed = true
    }

    @discardableResult
    private func send(_ method: String, _ path: String, _ body: Any? = nil) async throws -> Data {
        if !authed { try await login() }
        var (code, data) = try await http.send(method, base + "/api" + path, json: body)
        if code == 401 {
            // сессия протухла (контейнер перезапускали — секрет сессий новый) — один перелогин
            authed = false
            try await login()
            (code, data) = try await http.send(method, base + "/api" + path, json: body)
        }
        if code == 401 { throw XuiError("\(label): панель не пускает (401) — пароль сменился?") }
        if code == 404 { throw XuiError("\(label): 404 на \(path) — это точно старая amnezia-wg-easy?") }
        if code >= 400 { throw XuiError("\(label): HTTP \(code) \(Awg.msg(data) ?? "")") }
        return data
    }

    func interfaces() async throws -> [AwgInterface] { [AwgInterface(name: "wg0", enabled: true, isAwg31: false)] }

    func clients(_ p: XuiPanel) async throws -> [AwgClient] {
        guard let arr = J.parse(try await send("GET", "/wireguard/client")) as? [Any] else {
            throw XuiError("\(label): вместо списка клиентов пришёл не JSON — адрес панели без секретного пути?")
        }
        return arr.compactMap { $0 as? JObj }.map { o in
            var c = AwgClient()
            c.panel = p.name; c.panelId = p.id
            c.cid = J.str(o, "id")
            c.name = J.str(o, "name")
            c.interfaceId = "wg0"
            c.address = J.str(o, "address")
            c.enabled = J.bool(o, "enabled", true)
            c.handshake = Awg.date(o["latestHandshakeAt"])
            c.rx = J.long(o, "transferRx")
            c.tx = J.long(o, "transferTx")
            return c
        }
    }

    func create(_ name: String, interfaceId: String?) async throws { try await send("POST", "/wireguard/client", ["name": name]) }
    func delete(_ id: String) async throws { try await send("DELETE", "/wireguard/client/" + xuiEscape(id)) }
    func enable(_ id: String, _ on: Bool) async throws {
        try await send("POST", "/wireguard/client/" + xuiEscape(id) + (on ? "/enable" : "/disable"))
    }
    func config(_ id: String) async throws -> String {
        String(decoding: try await send("GET", "/wireguard/client/" + xuiEscape(id) + "/configuration"), as: UTF8.self)
    }
}

/// Проверка AWG-панели: вид определяется сам (правит role), вход, чтение клиентов.
enum AwgProbe {
    static func test(_ p: inout XuiPanel) async throws -> String {
        var kind = try await PanelProbe.detect(p.url, verifyTls: p.verifyTls)
        if kind == PanelProbe.xui { throw XuiError("по этому адресу 3x-ui, а не AWG") }
        if kind == nil { kind = p.login.isEmpty ? PanelProbe.awgOld : PanelProbe.awg }
        p.role = kind!
        if kind == PanelProbe.awg && p.login.isEmpty { throw XuiError("это новая awg-panel — нужен логин админа") }
        if kind == PanelProbe.awgOld { p.login = "" }
        let api = try Awg.api(p)
        let ifs = try await api.interfaces()
        let cl = try await api.clients(p)
        return "✓ \(PanelProbe.text(kind)): \(ifs.map(\.label).joined(separator: ", ")); клиентов \(cl.count)"
    }
}
