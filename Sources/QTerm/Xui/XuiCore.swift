import Foundation
import SessionVaultKit

// «Ноды 3x-ui» (порт QTerm Windows, волны 22–24): модели, адреса панелей, хранение в вейлте.
// Записи живут в vault.secrets под ключами "xui.panel:<UUID>" и "xui.names" — тот же JSON,
// что пишет Windows; синк по LWW (updatedAt внутри записи) — см. XuiStore.remoteNewer.

struct XuiError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum LogKind { case info, ok, warn, err, head, dim }

typealias JObj = [String: Any]

/// Терпимые геттеры JSON: строки/числа/булевы могут прийти чем угодно.
enum J {
    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func str(_ o: JObj, _ k: String, _ def: String = "") -> String {
        guard let v = o[k], !(v is NSNull) else { return def }
        if let s = v as? String { return s }
        if isBool(v) { return (v as! NSNumber).boolValue ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        return def
    }

    static func long(_ o: JObj, _ k: String) -> Int64 {
        guard let v = o[k], !(v is NSNull), !isBool(v) else { return 0 }
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let p = Int64(s) { return p }
        return 0
    }

    static func int(_ o: JObj, _ k: String) -> Int { Int(long(o, k)) }

    static func dbl(_ o: JObj, _ k: String) -> Double {
        guard let v = o[k], !isBool(v), let n = v as? NSNumber else { return 0 }
        return n.doubleValue
    }

    static func bool(_ o: JObj, _ k: String, _ def: Bool = false) -> Bool {
        guard let v = o[k], isBool(v) else { return def }
        return (v as! NSNumber).boolValue
    }

    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func data(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data("{}".utf8)
    }
}

/// Процентное кодирование сегмента пути (как Uri.EscapeDataString).
func xuiEscape(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

func xuiNowISO() -> String { ISO8601DateFormatter().string(from: Date()) }

/// Адрес панели как в браузере → схема/хост/порт/базовый путь (без /panel/…).
struct PanelURL: Equatable, Hashable {
    let scheme: String
    let host: String
    let port: Int
    let basePath: String

    var hostForURL: String { host.contains(":") ? "[\(host)]" : host }
    var base: String { "\(scheme)://\(hostForURL):\(port)\(basePath)" }
    var basePathOrSlash: String { basePath.isEmpty ? "/" : basePath + "/" }

    static func parse(_ raw: String) throws -> PanelURL {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { throw XuiError("пустой адрес панели") }
        if !url.contains("://") { url = "https://" + url }
        guard let c = URLComponents(string: url), let host = c.host, !host.isEmpty else {
            throw XuiError("не разобрал адрес панели: \(url)")
        }
        let scheme = (c.scheme ?? "https").lowercased()
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        var path = c.path
        if let r = path.range(of: "/panel(/|$)", options: .regularExpression) {
            path = String(path[..<r.lowerBound])
        }
        path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return PanelURL(scheme: scheme, host: h, port: port, basePath: path == "/" ? "" : path)
    }

    static func tryParse(_ raw: String) -> PanelURL? { try? parse(raw) }

    func sameAs(_ address: String, _ port: Int, _ basePath: String?) -> Bool {
        let slash = CharacterSet(charactersIn: "/")
        return address.caseInsensitiveCompare(host) == .orderedSame && port == self.port &&
            (basePath ?? "/").trimmingCharacters(in: slash) == self.basePath.trimmingCharacters(in: slash)
    }
}

// MARK: - DTO

struct XClient: Identifiable {
    var id: String { email }
    var rid = 0
    var email = ""
    var subId = ""
    var uuid = ""
    var auth = ""
    var password = ""
    var flow = ""
    var enable = true
    var totalBytes: Int64 = 0
    var expiryTime: Int64 = 0
    var up: Int64 = 0
    var down: Int64 = 0
    var comment = ""
    var inboundIds: [Int] = []
    var raw: JObj = [:]
}

struct XInbound: Identifiable {
    var id = 0
    var remark = ""
    var tag = ""
    var proto = ""
    var port = 0
    var nodeId: Int?
    var enable = true
    var clientEmails: [String] = []

    var multiUser: Bool { ["vless", "vmess", "trojan", "shadowsocks", "hysteria", "tuic"].contains(proto) }
    var isHys: Bool { proto == "hysteria" }
}

struct XNode: Identifiable {
    var id = 0
    var name = ""
    var scheme = "https"
    var address = ""
    var port = 0
    var basePath = "/"
    var enable = true
    var status = "unknown"
    var latencyMs = 0
    var cpuPct = 0.0
    var memPct = 0.0
    var uptimeSecs: Int64 = 0
    var netUp: Int64 = 0
    var netDown: Int64 = 0
    var xrayVersion = ""
    var panelVersion = ""
    var xrayState = ""
    var lastError = ""
    var inboundCount = 0
    var clientCount = 0
    var onlineCount = 0
}

// MARK: - Хранение

/// Панель 3x-ui (главная/нода) или AWG-панель: адрес как в браузере + доступ.
struct XuiPanel: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString.lowercased()
    var name = ""
    /// master | node | awg (awg-panel, wg-easy v15) | awg1 (старая amnezia-wg-easy)
    var role = "node"
    var url = ""
    /// 3x-ui — API-токен; awg-panel — пароль админа; старая amnezia-wg-easy — пароль панели.
    var token = ""
    var login = ""
    /// 3x-ui: пароль админа (чтобы перевыпустить токен).
    var pass: String?
    /// AWG: имена клиентов на момент последнего обновления (для пересоздания после переустановки).
    var clients: [String]?
    var verifyTls = true
    var updatedAt: String?
    var deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, role, url, token, login, pass, clients, verifyTls, updatedAt, deleted
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "node"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        login = try c.decodeIfPresent(String.self, forKey: .login) ?? ""
        pass = try c.decodeIfPresent(String.self, forKey: .pass)
        clients = try c.decodeIfPresent([String].self, forKey: .clients)
        verifyTls = try c.decodeIfPresent(Bool.self, forKey: .verifyTls) ?? true
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
    }

    var isMaster: Bool { role == "master" }
    var isAwg: Bool { role == "awg" || role == "awg1" }
    var isAwgLegacy: Bool { role == "awg1" }
    var isXuiNode: Bool { role == "node" }
    var isXui: Bool { role == "master" || role == "node" }
    var roleText: String {
        switch role {
        case "master": return "3x-ui · главная"
        case "awg": return "AWG-панель"
        case "awg1": return "AWG-панель (старая)"
        default: return "3x-ui · нода"
        }
    }
    var display: String { "\(name)  ·  \(roleText)" }
    var key: String { (UUID(uuidString: id)?.uuidString ?? id).uppercased() }
}

/// Канонические имена клиентов (+ «СИНОНИМ = ИМЯ»).
struct XuiNamesConfig: Codable {
    static let defaultNames = ["PC", "OP12", "S26", "OP9", "Lap", "LT", "MAMA",
                               "VI", "MAC", "NC", "GIGA", "PEAK", "GIANT", "ULTRA"]
    var lines: [String] = defaultNames
    var suffix: String = ""
    var v: Int = 2
    var updatedAt: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? Self.defaultNames
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 0
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        if v < 2 && suffix == "-HYS" { suffix = "" }
        v = 2
    }
}

/// Панели и список имён в vault.secrets (DPAPI на винде, Keychain/SE на маке, QTS1 в облаке).
@MainActor
final class XuiStore {
    static let panelPrefix = "xui.panel:"
    static let namesKey = "xui.names"

    private let store: SessionStore
    private let onChange: () -> Void

    init(store: SessionStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    private func secrets() -> [String: String] { (try? store.load().secrets) ?? [:] }

    private func put(_ key: String, _ value: String) {
        var s = secrets()
        s[key] = value
        try? store.save(secrets: s)
        onChange()
    }

    private static func encode<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return String(data: (try? e.encode(v)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    func panels() -> [XuiPanel] {
        var list: [XuiPanel] = []
        for (k, v) in secrets() where k.hasPrefix(Self.panelPrefix) {
            guard let p = try? JSONDecoder().decode(XuiPanel.self, from: Data(v.utf8)), p.deleted != true else { continue }
            list.append(p)
        }
        func rank(_ p: XuiPanel) -> Int { p.isMaster ? 0 : p.isXuiNode ? 1 : 2 }
        return list.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1)
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func panel(_ id: String) -> XuiPanel? { panels().first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }

    func save(_ panel: XuiPanel) {
        var p = panel
        p.updatedAt = xuiNowISO()
        p.deleted = nil
        put(Self.panelPrefix + p.key, Self.encode(p))
    }

    /// Удаление = tombstone без секретов (иначе запись вернётся с другого устройства).
    func delete(_ id: String) {
        var stub = XuiPanel()
        stub.id = id
        stub.deleted = true
        stub.updatedAt = xuiNowISO()
        put(Self.panelPrefix + stub.key, Self.encode(stub))
    }

    func names() -> XuiNamesConfig {
        if let v = secrets()[Self.namesKey],
           let cfg = try? JSONDecoder().decode(XuiNamesConfig.self, from: Data(v.utf8)) { return cfg }
        return XuiNamesConfig()
    }

    func saveNames(_ cfg: XuiNamesConfig) {
        var c = cfg
        c.updatedAt = xuiNowISO()
        c.v = 2
        put(Self.namesKey, Self.encode(c))
    }

    // MARK: синк: записи xui.* — LWW по встроенному updatedAt (остальные секреты — локальный приоритет)

    nonisolated static func isLww(_ key: String) -> Bool { key.hasPrefix("xui.") }

    nonisolated private static func updatedAt(_ json: String) -> String? {
        guard let o = J.parse(Data(json.utf8)) as? JObj else { return nil }
        return o["updatedAt"] as? String
    }

    /// true — брать удалённую версию (строго новее; ничья = локальная).
    nonisolated static func remoteNewer(local: String, remote: String) -> Bool {
        guard let r = updatedAt(remote) else { return false }
        guard let l = updatedAt(local) else { return true }
        return r > l
    }
}
