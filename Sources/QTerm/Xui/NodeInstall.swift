import Foundation

// «Нода из выделения»: разбор итога установщика, определение вида панели, вход в 3x-ui по паролю
// и выпуск API-токена. Порт NodeInstall.cs.

/// Одна панель из итога установщика. kind — догадка по заголовку раздела («xui» | «awg» | «»).
final class InstallBlock {
    var kind = ""
    var url = ""
    var login = ""
    var password = ""
    var server = ""
    var title = ""

    init(title: String = "") { self.title = title }

    /// Имя ноды по умолчанию — первая метка домена: design.repmac.shop → DESIGN.
    func suggestName() -> String {
        guard let h = PanelURL.tryParse(url)?.host else { return "" }
        if h.contains(":") || h.split(separator: ".").allSatisfy({ Int($0) != nil }) { return h }
        return String(h.split(separator: ".").first ?? "").uppercased()
    }

    var host: String { PanelURL.tryParse(url)?.host ?? "" }
}

private extension NSRegularExpression {
    /// Группы первого совпадения (0 — всё совпадение) или nil.
    func groups(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            let r = m.range(at: $0)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
    func matches(_ s: String) -> Bool { groups(s) != nil }
}

/// Разбор итога установщика (selfsni / 3x-ui install.sh / awg-v2 / awg-panel).
/// Разделы «=== … ===» / «### … ###»: AdGuard, команды, обфускация пропускаются (у AdGuard свои логин/пароль).
/// В одном выделении может быть несколько панелей (selfsni печатает и 3x-ui, и AWG).
enum InstallParser {
    private static let ansi = try! NSRegularExpression(pattern: "\\x1B\\[[0-9;?]*[A-Za-z]|\\x1B\\][^\\x07]*\\x07")
    private static let section = try! NSRegularExpression(pattern: "^\\s*[=#\\-*]{2,}\\s*(.*?)\\s*[=#\\-*]{2,}\\s*$")
    private static let kv = try! NSRegularExpression(pattern: "^\\s*([A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё0-9 _/\\-]{0,30}?)\\s*:\\s+(\\S.*?)\\s*$")
    private static let http = try! NSRegularExpression(pattern: "https?://[^\\s'\"<>]+", options: [.caseInsensitive])

    private static let urlKeys: Set<String> = ["panel", "panel url", "url", "web ui", "webui", "web", "access url",
                                               "web panel", "панель", "адрес", "адрес панели", "url панели"]
    private static let passKeys: Set<String> = ["password", "pass", "admin password", "пароль"]
    private static let userKeys: Set<String> = ["username", "user", "login", "логин", "пользователь"]
    private static let serverKeys: Set<String> = ["server", "endpoint", "сервер"]

    private static func kindOf(_ title: String) -> String {
        let t = title.lowercased()
        if ["3x-ui", "x-ui", "xui", "vless", "reality"].contains(where: { t.contains($0) }) { return "xui" }
        if ["amnezia", "awg", "wireguard"].contains(where: { t.contains($0) }) { return "awg" }
        return ""
    }

    private static func skip(_ title: String) -> Bool {
        let t = title.lowercased()
        return ["adguard", "command", "команд", "obfusc", "обфуск"].contains(where: { t.contains($0) })
    }

    private static func isAdg(_ url: String) -> Bool {
        var u = url
        while u.hasSuffix("/") { u.removeLast() }
        return u.lowercased().hasSuffix("/adg")
    }

    static func parse(_ input: String?) -> [InstallBlock] {
        var list: [InstallBlock] = []
        guard let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return list }
        let text = ansi.stringByReplacingMatches(in: input, range: NSRange(location: 0, length: (input as NSString).length),
                                                 withTemplate: "")
        var cur = InstallBlock()
        var skipping = false
        var title = ""

        func flush() {
            if !cur.url.isEmpty {
                list.append(cur)
            } else if let last = list.last, !cur.password.isEmpty, last.password.isEmpty {
                // пароль ниже URL, но в своём «разделе» (3x-ui печатает их между ####-полосками)
                last.password = cur.password
                if last.login.isEmpty { last.login = cur.login }
            }
            cur = InstallBlock(title: cur.title)
        }

        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            var line = raw
            while let c = line.last, c.isWhitespace { line.removeLast() }
            if line.range(of: "INSTALLATION COMPLETE", options: .caseInsensitive) != nil {
                if let i = line.firstIndex(of: "-") {
                    title = String(line[line.index(after: i)...]).trimmingCharacters(in: CharacterSet(charactersIn: " =-#"))
                } else { title = "" }
                cur.title = title
                continue
            }
            if let sm = section.groups(line), !kv.matches(line) {
                let name = sm[1]
                // голая полоска «#####» без названия: после пропускаемого раздела — новый блок;
                // иначе не новый раздел, пока в текущем нет адреса и пароля
                if name.isEmpty && !skipping && (cur.url.isEmpty || cur.password.isEmpty) { continue }
                flush()
                skipping = skip(name)
                cur.kind = kindOf(name)
                if !name.isEmpty && !skipping { cur.title = title.isEmpty ? name : "\(title) · \(name)" }
                continue
            }
            if skipping { continue }
            guard let m = kv.groups(line) else { continue }
            let key = m[1].trimmingCharacters(in: .whitespaces).lowercased()
            let val = m[2].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if urlKeys.contains(key) {
                guard let u = http.groups(val)?.first, !isAdg(u) else { continue }
                if !cur.url.isEmpty && cur.url != u {
                    // вторая панель без заголовка раздела — новый блок
                    let kind = cur.kind
                    flush()
                    cur.kind = kind
                }
                cur.url = u
            } else if passKeys.contains(key) {
                if cur.password.isEmpty { cur.password = val }
            } else if userKeys.contains(key) {
                if cur.login.isEmpty { cur.login = val }
            } else if serverKeys.contains(key) {
                if cur.server.isEmpty { cur.server = val }
            }
        }
        flush()
        // одна и та же панель дважды — оставляем первую с паролем
        var out: [InstallBlock] = []
        var seen: [String: Int] = [:]
        for b in list {
            var k = b.url.lowercased()
            while k.hasSuffix("/") { k.removeLast() }
            if let i = seen[k] {
                if out[i].password.isEmpty && !b.password.isEmpty { out[i] = b }
            } else {
                seen[k] = out.count
                out.append(b)
            }
        }
        return out
    }
}

/// Что за панель по адресу — без входа.
/// 3x-ui v3: GET {base}/csrf-token → {"success":true}; старая amnezia-wg-easy: GET {base}/api/session → 200 {requiresPassword};
/// awg-panel (wg-easy v15): GET {base}/api/session → 401.
enum PanelProbe {
    static let xui = "xui", awg = "awg", awgOld = "awg1"

    static func detect(_ url: String, verifyTls: Bool) async throws -> String? {
        let b = try PanelURL.parse(url).base
        let http = XuiHTTP(label: "панель", verifyTls: verifyTls, cookies: false, timeout: 15)
        let (c1, t1) = try await http.send("GET", b + "/csrf-token")
        let s1 = String(decoding: t1, as: UTF8.self)
        if c1 == 200 && s1.contains("\"success\"") { return xui }
        if c1 == 403 && t1.isEmpty {
            throw XuiError("403 — панель 3x-ui пускает только по своему домену (webDomain): открой по нему, не по IP")
        }
        let (c2, t2) = try await http.send("GET", b + "/api/session")
        if c2 == 200 && String(decoding: t2, as: UTF8.self).contains("requiresPassword") { return awgOld }
        if c2 == 401 { return awg }
        return nil
    }

    static func text(_ kind: String?) -> String {
        switch kind ?? "" {
        case xui: return "3x-ui"
        case awg: return "AWG · awg-panel"
        case awgOld: return "AWG · старая amnezia-wg-easy"
        default: return "не определена"
        }
    }
}

/// Вход в 3x-ui по логину/паролю (cookie-сессия + CSRF) и выпуск API-токена — как «Новый токен» в настройках.
enum XuiLogin {
    struct Result {
        var token: String?
        var needTwoFactor: Bool
        var message: String
        var ok = false
    }

    /// tokenName nil — только проверить вход, токен не выпускать.
    static func issueToken(url: String, login: String, password: String, twoFactor: String?,
                           verifyTls: Bool, tokenName: String?, scope: String = "admin") async throws -> Result {
        let b = try PanelURL.parse(url).base
        let http = XuiHTTP(label: "3x-ui", verifyTls: verifyTls, cookies: true, timeout: 30)
        let xhr = ["X-Requested-With": "XMLHttpRequest"]

        func ok(_ js: JObj?) -> Bool { js.map { J.bool($0, "success") } ?? false }

        func csrf() async throws -> String {
            let (code, data) = try await http.send("GET", b + "/csrf-token", headers: xhr)
            if code == 403 { throw XuiError("403 — 3x-ui пускает только по своему домену (webDomain)") }
            let js = J.parse(data) as? JObj
            guard ok(js), let t = js?["obj"] as? String, !t.isEmpty else {
                throw XuiError("не 3x-ui v3 или неверный путь панели (csrf-token: HTTP \(code))")
            }
            return t
        }

        var token = try await csrf()
        let (lc, ld) = try await http.send("POST", b + "/login",
                                           json: ["username": login, "password": password, "twoFactorCode": twoFactor ?? ""],
                                           headers: xhr.merging(["X-CSRF-Token": token]) { $1 })
        if lc == 403 { throw XuiError("вход: 403 (CSRF/домен)") }
        let lj = J.parse(ld) as? JObj
        if !ok(lj) {
            let (_, td) = try await http.send("POST", b + "/getTwoFactorEnable", json: JObj(),
                                              headers: xhr.merging(["X-CSRF-Token": token]) { $1 })
            let tj = J.parse(td) as? JObj
            let need = ok(tj) && J.bool(tj ?? [:], "obj")
            if need && (twoFactor ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                return Result(token: nil, needTwoFactor: true, message: "включена 2FA — введи код из приложения")
            }
            let msg = lj.map { J.str($0, "msg") } ?? ""
            return Result(token: nil, needTwoFactor: false,
                          message: "логин/пароль\(need ? "/код 2FA" : "") не подошли" + (msg.isEmpty ? "" : " (\(msg))"))
        }
        guard let tokenName else { return Result(token: nil, needTwoFactor: false, message: "✓ вход по логину и паролю работает", ok: true) }
        token = try await csrf()
        let (tc, td) = try await http.send("POST", b + "/panel/api/setting/apiTokens/create",
                                           json: ["name": tokenName, "scope": scope, "expiresAt": 0] as JObj,
                                           headers: xhr.merging(["X-CSRF-Token": token]) { $1 })
        let tj = J.parse(td) as? JObj
        guard ok(tj) else { throw XuiError("токен не выпустился: HTTP \(tc) \(tj.map { J.str($0, "msg") } ?? "")") }
        guard let plain = (tj?["obj"] as? JObj)?["token"] as? String, !plain.isEmpty else {
            throw XuiError("токен выпущен, но панель не вернула его текст")
        }
        return Result(token: plain, needTwoFactor: false, message: "✓ вход по паролю, выпущен API-токен «\(tokenName)» (\(scope))", ok: true)
    }
}
