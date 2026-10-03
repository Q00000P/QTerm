import Foundation

// REST API 3x-ui v3 (Bearer-токен) и общий HTTP-слой (свой URLSession на панель:
// «не проверять сертификат», cookie-сессия для старой AWG-панели).

final class XuiTLSDelegate: NSObject, URLSessionDelegate {
    let verify: Bool
    init(verify: Bool) { self.verify = verify }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if !verify, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Сессия на одну панель. ephemeral — своя память cookie, ничего не пишется на диск.
final class XuiHTTP {
    let session: URLSession
    let label: String

    init(label: String, verifyTls: Bool, cookies: Bool, timeout: TimeInterval = 40) {
        self.label = label
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpShouldSetCookies = cookies
        cfg.httpCookieAcceptPolicy = cookies ? .always : .never
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: XuiTLSDelegate(verify: verifyTls), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Запрос с готовым телом (multipart и т.п.).
    func sendRaw(_ method: String, _ urlString: String, body: Data, contentType: String,
                 headers: [String: String] = [:]) async throws -> (Int, Data) {
        guard let url = URL(string: urlString) else { throw XuiError("\(label): кривой адрес \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let e as URLError {
            throw XuiError(e.code == .timedOut ? "\(label): таймаут" : "\(label): нет связи (\(e.localizedDescription))")
        }
    }

    /// Запрос → (код, тело). Сетевые ошибки — в понятные XuiError.
    func send(_ method: String, _ urlString: String, json: Any? = nil,
              headers: [String: String] = [:]) async throws -> (Int, Data) {
        guard let url = URL(string: urlString) else { throw XuiError("\(label): кривой адрес \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.httpBody = J.data(json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let e as URLError {
            switch e.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .secureConnectionFailed, .clientCertificateRejected:
                throw XuiError("\(label): сертификат не прошёл проверку (\(e.localizedDescription))")
            case .timedOut:
                throw XuiError("\(label): таймаут")
            default:
                throw XuiError("\(label): нет связи (\(e.localizedDescription))")
            }
        }
    }
}

final class XuiAPI {
    let label: String
    let url: PanelURL
    let verifyTls: Bool
    private var token: String
    private let http: XuiHTTP
    /// Перевыпуск токена при 401 (сохранённые логин/пароль админа). Один раз на объект API.
    var reauth: (() async -> String?)?
    private var reauthTask: Task<String?, Never>?
    private let reauthLock = NSLock()

    init(label: String, url: String, token: String, verifyTls: Bool = true) throws {
        self.label = label
        self.url = try PanelURL.parse(url)
        self.verifyTls = verifyTls
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        http = XuiHTTP(label: label, verifyTls: verifyTls, cookies: false)
    }

    static func forPanel(_ p: XuiPanel) throws -> XuiAPI {
        let api = try XuiAPI(label: p.name, url: p.url, token: p.token, verifyTls: p.verifyTls)
        if p.isXui, !p.login.isEmpty, !(p.pass ?? "").isEmpty {
            let pid = p.id
            api.reauth = { @MainActor in await XuiCenter.shared.reissueToken(pid) }
        }
        return api
    }

    /// 401 от панели: токен в QTerm ей неизвестен (удалён/выключен/истёк или панель переустановлена).
    static func unauthorized(_ label: String) -> XuiError {
        XuiError("\(label): панель не принимает токен (401) — его удалили, выключили, он истёк или панель переустановлена. "
                 + "«Панели и токены…» → панель → логин и пароль админа → «Выпустить токен» (с сохранённым паролем QTerm дальше перевыпускает сам)")
    }

    /// Новый токен (один перевыпуск на объект; параллельные запросы ждут тот же).
    private func renewToken() async -> String? {
        guard let reauth else { return nil }
        let task: Task<String?, Never> = reauthLock.withLock {
            if let t = reauthTask { return t }
            let t = Task { await reauth() }
            reauthTask = t
            return t
        }
        guard let t = await task.value, !t.isEmpty else { return nil }
        reauthLock.withLock { token = t }
        return t
    }

    private var bearer: [String: String] { ["Authorization": "Bearer " + reauthLock.withLock { token }] }

    private func raw(_ method: String, _ path: String, _ body: Any?) async throws -> (Int, Data) {
        let r = try await http.send(method, url.base + "/panel/api" + path, json: body, headers: bearer)
        guard r.0 == 401, await renewToken() != nil else { return r }
        return try await http.send(method, url.base + "/panel/api" + path, json: body, headers: bearer)
    }

    @discardableResult
    func call(_ method: String, _ path: String, _ body: Any? = nil) async throws -> Any? {
        let (code, data) = try await raw(method, path, body)
        switch code {
        case 401: throw Self.unauthorized(label)
        case 403: throw XuiError("\(label): 403 — токену не хватает прав или адрес не совпадает с доменом панели (webDomain)")
        case 404: throw XuiError("\(label): 404 на \(path) — проверь базовый путь панели")
        default: break
        }
        guard let js = J.parse(data) as? JObj else { throw XuiError("\(label): ответ не JSON (HTTP \(code))") }
        if !J.bool(js, "success") {
            let msg = J.str(js, "msg")
            throw XuiError("\(label): \(path): \(msg.isEmpty ? "ошибка" : msg)")
        }
        let obj = js["obj"]
        return obj is NSNull ? nil : obj
    }

    @discardableResult
    func get(_ path: String) async throws -> Any? { try await call("GET", path) }
    @discardableResult
    func post(_ path: String, _ body: Any? = nil) async throws -> Any? { try await call("POST", path, body ?? JObj()) }

    // MARK: чтение

    func status() async throws -> JObj { (try await get("/server/status") as? JObj) ?? [:] }
    func settings() async throws -> JObj { (try await post("/setting/all") as? JObj) ?? [:] }

    func clients() async throws -> [XClient] {
        let arr = (try await get("/clients/list") as? [Any]) ?? []
        return arr.compactMap { $0 as? JObj }.map { o in
            var c = XClient()
            c.raw = o
            c.rid = J.int(o, "id")
            c.email = J.str(o, "email")
            c.subId = J.str(o, "subId")
            c.uuid = J.str(o, "uuid")
            c.auth = J.str(o, "auth")
            c.password = J.str(o, "password")
            c.flow = J.str(o, "flow")
            c.enable = J.bool(o, "enable", true)
            c.totalBytes = J.long(o, "totalGB")
            c.expiryTime = J.long(o, "expiryTime")
            c.comment = J.str(o, "comment")
            c.inboundIds = ((o["inboundIds"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            if let t = o["traffic"] as? JObj {
                c.up = J.long(t, "up")
                c.down = J.long(t, "down")
            }
            return c
        }
    }

    func inbounds() async throws -> [XInbound] {
        let arr = (try await get("/inbounds/list") as? [Any]) ?? []
        return arr.compactMap { $0 as? JObj }.map { o in
            var ib = XInbound()
            ib.id = J.int(o, "id")
            ib.remark = J.str(o, "remark")
            ib.tag = J.str(o, "tag")
            ib.proto = J.str(o, "protocol")
            ib.port = J.int(o, "port")
            ib.enable = J.bool(o, "enable", true)
            if let n = o["nodeId"] as? NSNumber, !J.isBool(n) { ib.nodeId = n.intValue }
            var settings: Any? = o["settings"]
            if let s = settings as? String, !s.isEmpty { settings = J.parse(Data(s.utf8)) }
            if let st = settings as? JObj, let cl = st["clients"] as? [Any] {
                ib.clientEmails = cl.compactMap { ($0 as? JObj)?["email"] as? String }
            }
            return ib
        }
    }

    func nodes() async throws -> [XNode] {
        let arr = (try await get("/nodes/list") as? [Any]) ?? []
        return arr.compactMap { $0 as? JObj }.map { o in
            var n = XNode()
            n.id = J.int(o, "id")
            n.name = J.str(o, "name")
            n.scheme = J.str(o, "scheme", "https")
            n.address = J.str(o, "address")
            n.port = J.int(o, "port")
            n.basePath = J.str(o, "basePath", "/")
            n.enable = J.bool(o, "enable", true)
            n.status = J.str(o, "status", "unknown")
            n.latencyMs = J.int(o, "latencyMs")
            n.cpuPct = J.dbl(o, "cpuPct")
            n.memPct = J.dbl(o, "memPct")
            n.uptimeSecs = J.long(o, "uptimeSecs")
            n.netUp = J.long(o, "netUp")
            n.netDown = J.long(o, "netDown")
            n.xrayVersion = J.str(o, "xrayVersion")
            n.panelVersion = J.str(o, "panelVersion")
            n.xrayState = J.str(o, "xrayState")
            n.lastError = J.str(o, "lastError")
            n.inboundCount = J.int(o, "inboundCount")
            n.clientCount = J.int(o, "clientCount")
            n.onlineCount = J.int(o, "onlineCount")
            return n
        }
    }

    func onlines() async -> Set<String> {
        // старые панели / нет прав — не критично
        guard let arr = try? await post("/clients/onlines") as? [Any] else { return [] }
        return Set(arr.compactMap { $0 as? String })
    }

    func getDb() async throws -> Data {
        let (code, data) = try await raw("GET", "/server/getDb", nil)
        if code == 401 { throw Self.unauthorized(label) }
        if code == 403 { throw XuiError("\(label): токену не хватает прав на скачивание базы (403) — нужен токен с правами admin") }
        guard code == 200, data.count >= 16, String(data: data.prefix(15), encoding: .ascii) == "SQLite format 3" else {
            throw XuiError("\(label): не удалось скачать базу (HTTP \(code))")
        }
        return data
    }

    // MARK: клиенты

    /// ClientRecord из /clients/list → тело /clients/update (model.Client).
    static func clientPayload(_ c: XClient, email: String? = nil, creds: [String: String]? = nil,
                              enable: Bool? = nil, subId: String? = nil) -> JObj {
        let r = c.raw
        var o: JObj = [
            "id": J.str(r, "uuid"),
            "security": J.str(r, "security"),
            "password": J.str(r, "password"),
            "flow": J.str(r, "flow"),
            "auth": J.str(r, "auth"),
            "email": email ?? c.email,
            "limitIp": J.long(r, "limitIp"),
            "totalGB": J.long(r, "totalGB"),
            "expiryTime": J.long(r, "expiryTime"),
            "enable": enable ?? J.bool(r, "enable", true),
            "tgId": J.long(r, "tgId"),
            "subId": subId ?? J.str(r, "subId"),
            "group": J.str(r, "group"),
            "comment": J.str(r, "comment"),
            "reset": J.long(r, "reset"),
            "resetDay": J.long(r, "resetDay"),
            "resetWeekday": J.long(r, "resetWeekday"),
            "resetMax": J.long(r, "resetMax"),
            "trafficReset": J.str(r, "trafficReset", "never"),
            "trafficResetDay": max(1, J.long(r, "trafficResetDay")),
            "limitHwid": J.long(r, "limitHwid"),
        ]
        for (k, v) in creds ?? [:] { o[k] = v }
        return o
    }

    func updateClient(_ email: String, _ body: JObj) async throws { try await post("/clients/update/\(xuiEscape(email))", body) }
    func deleteClient(_ email: String) async throws { try await post("/clients/del/\(xuiEscape(email))") }
    func attach(_ email: String, _ ids: [Int]) async throws {
        try await post("/clients/\(xuiEscape(email))/attach", ["inboundIds": ids])
    }
    func detach(_ email: String, _ ids: [Int]) async throws {
        try await post("/clients/\(xuiEscape(email))/detach", ["inboundIds": ids])
    }
    func addClient(_ email: String, _ ids: [Int]) async throws {
        let client: JObj = ["email": email, "enable": true]
        try await post("/clients/add", ["client": client, "inboundIds": ids] as JObj)
    }

    // MARK: узлы

    @discardableResult
    func addNode(_ body: JObj) async throws -> JObj? { try await post("/nodes/add", body) as? JObj }
    func setNodeEnable(_ id: Int, _ enable: Bool) async throws { try await post("/nodes/setEnable/\(id)", ["enable": enable]) }
    func probeNode(_ id: Int) async throws { try await post("/nodes/probe/\(id)") }
    func nodeGet(_ id: Int) async throws -> JObj { (try await get("/nodes/get/\(id)") as? JObj) ?? [:] }
    func nodeUpdate(_ id: Int, _ body: JObj) async throws { try await post("/nodes/update/\(id)", body) }

    func createToken(_ name: String, scope: String) async throws -> String? {
        let o = try await post("/setting/apiTokens/create", ["name": name, "scope": scope, "expiresAt": 0] as JObj) as? JObj
        return o?["token"] as? String
    }

    // MARK: обновления панели / ядро Xray / база

    /// Текущая и последняя версия панели (панель сама спрашивает GitHub). nil — не достучалась.
    func updateInfo() async -> JObj? { try? await get("/server/getPanelUpdateInfo") as? JObj }

    /// Самообновление панели (update.sh в отдельном юните systemd). Возвращает runId для опроса статуса.
    func startUpdate() async throws -> String? { (try await post("/server/updatePanel") as? JObj)?["runId"] as? String }

    /// {runId, state: pending|success|failed, exitCode, finishedAt} последнего самообновления.
    func updateStatus() async throws -> JObj? { try await get("/server/getUpdateStatus") as? JObj }

    /// Версии Xray-core, доступные для установки (панель берёт их с GitHub).
    func xrayVersions() async throws -> [String] {
        ((try await get("/server/getXrayVersion") as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    func installXray(_ version: String) async throws { try await post("/server/installXray/" + xuiEscape(version)) }
    func updateGeo() async throws { try await post("/server/updateGeofile") }

    /// Загрузить базу в панель (её адреса/сертификаты/привязка узла сохраняются). Панель перезапустится.
    func importDb(_ db: Data) async throws {
        let boundary = "qterm-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"db\"; filename=\"x-ui.db\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(db)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        func send() async throws -> (Int, Data) {
            try await http.sendRaw("POST", url.base + "/panel/api/server/importDB", body: body,
                                   contentType: "multipart/form-data; boundary=\(boundary)", headers: bearer)
        }
        var (code, data) = try await send()
        if code == 401, await renewToken() != nil { (code, data) = try await send() }
        if code == 401 { throw Self.unauthorized(label) }
        if code == 403 { throw XuiError("\(label): токену не хватает прав на загрузку базы (403) — нужен токен с правами admin") }
        let js = J.parse(data) as? JObj
        if !(js.map { J.bool($0, "success") } ?? false) {
            throw XuiError("\(label): база не загрузилась: \(js.map { J.str($0, "msg") } ?? "HTTP \(code)")")
        }
    }

    /// Ссылка подписки по настройкам панели (subURI → иначе схема/домен/порт/путь).
    static func subLink(_ st: JObj, _ panel: PanelURL, _ subId: String, clash: Bool = false) -> String? {
        if !J.bool(st, clash ? "subClashEnable" : "subEnable", !clash) { return nil }
        let uri = J.str(st, clash ? "subClashURI" : "subURI")
        if !uri.isEmpty {
            var u = uri
            while u.hasSuffix("/") { u.removeLast() }
            return u + "/" + subId
        }
        let https = !J.str(st, "subCertFile").isEmpty || !J.str(st, "subKeyFile").isEmpty
        var host = J.str(st, "subDomain")
        if host.isEmpty { host = panel.hostForURL }
        let port = J.int(st, "subPort")
        var path = J.str(st, clash ? "subClashPath" : "subPath", "/sub/")
        if !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }
        let scheme = https ? "https" : "http"
        let portPart = (https && port == 443) || (!https && port == 80) || port == 0 ? "" : ":\(port)"
        return "\(scheme)://\(host)\(portPart)\(path)\(subId)"
    }
}
