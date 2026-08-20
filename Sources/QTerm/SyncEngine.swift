import SwiftUI
import AppKit
import Foundation
import Darwin
import CryptoKit
import SessionVaultKit
import Argon2Swift

// MARK: - Конфиг синка (живёт ТОЛЬКО в локальном вейлте, в облако не уходит)

struct SyncConfig: Codable, Equatable {
    var url: String = ""            // WebDAV: полный URL файла
    var login: String = ""          // WebDAV Basic
    var webdavPassword: String = ""
    var encPassword: String = ""    // пароль шифрования блоба (общий для всех устройств)
    var enabled: Bool = false

    /// "webdav" (nil = webdav) | "gdrive". Опциональные поля — старый конфиг декодится.
    var backend: String?
    var gdFolder: String?           // папка на Диске по имени, дефолт QTerm
    var gdRefreshToken: String?
    /// Легаси: раньше credentials вводились руками. Читаются, но не пишутся.
    var gdClientId: String?
    var gdClientSecret: String?

    var isGDrive: Bool { backend == "gdrive" }
    var gdConnected: Bool { !(gdRefreshToken ?? "").isEmpty }

    /// OAuth-клиент QTerm Desktop (Google Cloud Console, проект QTerm).
    /// Для десктопных приложений это публичный клиент: secret не является
    /// тайной (он извлекается из любого бинаря), подлинность даёт loopback.
    /// Один клиент на все десктопные ОС — mac/win/linux.
    static let googleClientId = "422218910721-oankvt8u3bp377g6ejmvr4p4s5437plj.apps.googleusercontent.com"
    static let googleClientSecret = "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"

    /// Ключ в vault.secrets, под которым лежит конфиг. Всё с префиксом
    /// "sync." вырезается из облачной копии.
    static let secretKey = "sync.config"
}

/// Общий интерфейс транспорта: WebDAV и Google Drive.
protocol SyncTransport {
    func get() async throws -> Data?   // nil = файла ещё нет (первый пуш)
    func put(_ data: Data) async throws
}
extension WebDAV: SyncTransport {}

// MARK: - QTS1: формат облачного блоба (контракт с Android)

/// "QTS1"(4) + t(1) + p(1) + m_kib(4 LE) + salt(16) + nonce(12)
/// + AES-256-GCM(ciphertext + tag). Ключ = Argon2id(пароль, salt, t, m, p, 32).
enum QTS1 {
    static let magic = Data("QTS1".utf8)
    static let tCost: UInt8 = 3
    static let pCost: UInt8 = 2
    static let mKib: UInt32 = 65536

    enum BlobError: LocalizedError {
        case badMagic, tooShort, decryptFailed
        var errorDescription: String? {
            switch self {
            case .badMagic: return "Файл на сервере — не QTS1-блоб (чужой файл по этому URL?)"
            case .tooShort: return "Блоб повреждён (обрезан)"
            case .decryptFailed: return "Не расшифровалось — проверь пароль шифрования"
            }
        }
    }

    static func deriveKey(password: String, salt: Data, t: UInt8, m: UInt32, p: UInt8) throws -> SymmetricKey {
        let result = try Argon2Swift.hashPasswordBytes(
            password: Data(password.utf8),
            salt: Salt(bytes: salt),
            iterations: Int(t),
            memory: Int(m),
            parallelism: Int(p),
            length: 32,
            type: .id
        )
        return SymmetricKey(data: result.hashData())
    }

    static func pack(payload: Data, password: String) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = try deriveKey(password: password, salt: salt, t: tCost, m: mKib, p: pCost)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(payload, using: key, nonce: nonce)

        var out = Data()
        out.append(magic)
        out.append(tCost)
        out.append(pCost)
        var m = mKib.littleEndian
        withUnsafeBytes(of: &m) { out.append(contentsOf: $0) }
        out.append(salt)
        out.append(Data(nonce))
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    static func unpack(_ blob: Data, password: String) throws -> Data {
        // Индексация с нуля независимо от происхождения Data.
        let d = Data(blob)
        guard d.count > 4 + 1 + 1 + 4 + 16 + 12 + 16 else { throw BlobError.tooShort }
        guard d.prefix(4) == magic else { throw BlobError.badMagic }
        var idx = 4
        let t = d[idx]; idx += 1
        let p = d[idx]; idx += 1
        let mBytes = d.subdata(in: idx ..< idx + 4); idx += 4
        let m = mBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        let salt = d.subdata(in: idx ..< idx + 16); idx += 16
        let nonceData = d.subdata(in: idx ..< idx + 12); idx += 12
        let ctAndTag = d.subdata(in: idx ..< d.count)
        guard ctAndTag.count >= 16 else { throw BlobError.tooShort }
        let ciphertext = ctAndTag.prefix(ctAndTag.count - 16)
        let tag = ctAndTag.suffix(16)

        let key = try deriveKey(password: password, salt: salt, t: t, m: m, p: p)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonceData),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(box, using: key)
        } catch {
            throw BlobError.decryptFailed
        }
    }
}

// MARK: - JSON вейлта для облака (совместим с .qtvault/Android)

enum SyncJSON {
    /// КАНОН кроссплатформенной схемы (мак/андроид/будущие винда-линукс-iOS):
    /// даты — ISO8601-строки БЕЗ долей секунд ("2026-08-20T12:00:00Z"),
    /// UUID — строки в верхнем регистре (Swift так и пишет). Числовые даты
    /// сюда писать нельзя: kotlinx на андроиде ждёт String.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Decoder терпимый к датам: double referenceDate (мак), epoch seconds/ms,
    /// ISO8601-строка — на случай, если другая сторона пишет иначе.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let num = try? c.decode(Double.self) {
                if num > 1_000_000_000_000 { return Date(timeIntervalSince1970: num / 1000) }
                if num > 1_000_000_000 { return Date(timeIntervalSince1970: num) }
                return Date(timeIntervalSinceReferenceDate: num)
            }
            if let str = try? c.decode(String.self) {
                let iso = ISO8601DateFormatter()
                if let date = iso.date(from: str) { return date }
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: str) { return date }
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Неизвестный формат даты")
        }
        return d
    }
}

// MARK: - Мини-WebDAV (GET/PUT c Basic)

struct WebDAV {
    let url: URL
    let login: String
    let password: String

    enum DAVError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(let code):
                switch code {
                case 401: return "WebDAV: неверный логин/пароль (401)"
                case 403: return "WebDAV: доступ запрещён (403)"
                default: return "WebDAV: HTTP \(code)"
                }
            }
        }
    }

    private var authHeader: String {
        "Basic " + Data("\(login):\(password)".utf8).base64EncodedString()
    }

    private func request(_ method: String) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 25)
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return r
    }

    /// nil = файла ещё нет (404) — первый пуш.
    func get() async throws -> Data? {
        let (data, resp) = try await URLSession.shared.data(for: request("GET"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard (200..<300).contains(code) else { throw DAVError.http(code) }
        return data
    }

    func put(_ data: Data) async throws {
        var r = request("PUT")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: r, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw DAVError.http(code) }
    }
}

// MARK: - LWW-merge (зеркало Android VaultRepo.applySyncMerge)

enum SyncMerge {
    /// Побеждает бОльший updatedAt (ISO8601 лексикографически); nil — древний;
    /// ничья — локальный. Tombstones участвуют как обычные записи.
    static func newer(_ localTime: String?, _ remoteTime: String?) -> Bool {
        // true = берём remote
        switch (localTime, remoteTime) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let l?, let r?): return r > l
        }
    }

    static func mergeList<T: Identifiable>(
        local: [T], remote: [T],
        time: (T) -> String?
    ) -> [T] where T.ID: Hashable {
        var byID: [T.ID: T] = [:]
        var order: [T.ID] = []
        for item in local {
            byID[item.id] = item
            order.append(item.id)
        }
        for item in remote {
            if let existing = byID[item.id] {
                if newer(time(existing), time(item)) { byID[item.id] = item }
            } else {
                byID[item.id] = item
                order.append(item.id)
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Секреты: локальный приоритет + доливка недостающих; "sync.*" не мержим.
    static func mergeSecrets(local: [String: String], remote: [String: String]) -> [String: String] {
        var out = local
        for (k, v) in remote where out[k] == nil && !k.hasPrefix("sync.") {
            out[k] = v
        }
        return out
    }

    /// Журнал команд. Обычные записи — идемпотентно (count = max,
    /// lastUsed = max). Если любая из сторон tombstone — LWW по lastUsed:
    /// удаление с более свежим временем побеждает, повторный ввод воскрешает.
    static func mergeCmdHistory(local: [String: CmdStat], remote: [String: CmdStat]) -> [String: CmdStat] {
        var out = local
        for (cmd, r) in remote {
            if var l = out[cmd] {
                if l.deleted == true || r.deleted == true {
                    out[cmd] = (r.lastUsed ?? "") > (l.lastUsed ?? "") ? r : l
                } else {
                    l.count = max(l.count, r.count)
                    l.lastUsed = max(l.lastUsed ?? "", r.lastUsed ?? "")
                    if l.lastUsed?.isEmpty == true { l.lastUsed = nil }
                    out[cmd] = l
                }
            } else {
                out[cmd] = r
            }
        }
        if out.count > 500 {
            let sorted = out.sorted { ($0.value.lastUsed ?? "") > ($1.value.lastUsed ?? "") }
            out = Dictionary(uniqueKeysWithValues: sorted.prefix(500).map { ($0.key, $0.value) })
        }
        return out
    }

    static func merge(local: SessionVault, remote: SessionVault) -> SessionVault {
        var out = local
        out.sessions = mergeList(local: local.sessions, remote: remote.sessions) { $0.updatedAt }
        out.sshKeys = mergeList(local: local.sshKeys ?? [], remote: remote.sshKeys ?? []) { $0.updatedAt }
        out.snippets = mergeList(local: local.snippets ?? [], remote: remote.snippets ?? []) { $0.updatedAt }
        out.secrets = mergeSecrets(local: local.secrets ?? [:], remote: remote.secrets ?? [:])
        out.cmdHistory = mergeCmdHistory(local: local.cmdHistory ?? [:], remote: remote.cmdHistory ?? [:])
        out.updatedAt = Date()
        return out
    }
}

// MARK: - Google Drive (контракт как на Android: drive.file, папка по имени,
// файл vault.qtsync, создание метадата POST → PATCH upload)

struct GDrive: SyncTransport {
    let clientId: String
    let clientSecret: String
    let refreshToken: String
    let folderName: String

    enum GDError: LocalizedError {
        case tokenRefresh(String)
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .tokenRefresh(let d): return "Google: не обновился токен (\(d)) — «Войти в Google» заново"
            case .http(let c, let ctx): return "Google Drive: HTTP \(c) (\(ctx))"
            }
        }
    }

    private static let fileName = "vault.qtsync"

    // MARK: HTTP-обвязка

    private func request(_ url: URL, _ method: String, token: String? = nil,
                         body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        return r
    }

    private func run(_ r: URLRequest, ctx: String) async throws -> (Data, Int) {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) && code != 404 {
            throw GDError.http(code, ctx)
        }
        return (data, code)
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: Токен (refresh на каждый цикл, как на ведре)

    func accessToken() async throws -> String {
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "client_secret", value: clientSecret),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "grant_type", value: "refresh_token"),
        ]
        let body = Data((comps.percentEncodedQuery ?? "").utf8)
        let r = request(URL(string: "https://oauth2.googleapis.com/token")!, "POST",
                        body: body, contentType: "application/x-www-form-urlencoded")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = json(data)
        guard code == 200, let token = obj["access_token"] as? String else {
            let detail = (obj["error"] as? String) ?? "HTTP \(code)"
            throw GDError.tokenRefresh(detail)
        }
        return token
    }

    // MARK: Папка/файл по имени (scope drive.file видит только своё)

    private func query(_ token: String, q: String, ctx: String) async throws -> [[String: Any]] {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "q", value: q),
            .init(name: "fields", value: "files(id,name)"),
            .init(name: "spaces", value: "drive"),
        ]
        let (data, _) = try await run(request(comps.url!, "GET", token: token), ctx: ctx)
        return (json(data)["files"] as? [[String: Any]]) ?? []
    }

    private func folderId(_ token: String, createIfMissing: Bool) async throws -> String? {
        let name = folderName.replacingOccurrences(of: "'", with: "\\'")
        let found = try await query(token,
            q: "name = '\(name)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
            ctx: "поиск папки")
        if let id = found.first?["id"] as? String { return id }
        guard createIfMissing else { return nil }
        let meta = try JSONSerialization.data(withJSONObject: [
            "name": folderName,
            "mimeType": "application/vnd.google-apps.folder",
        ])
        let (data, _) = try await run(request(
            URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!,
            "POST", token: token, body: meta, contentType: "application/json"), ctx: "создание папки")
        return json(data)["id"] as? String
    }

    private func fileId(_ token: String, in folder: String) async throws -> String? {
        let found = try await query(token,
            q: "name = '\(Self.fileName)' and '\(folder)' in parents and trashed = false",
            ctx: "поиск файла")
        return found.first?["id"] as? String
    }

    // MARK: SyncTransport

    func get() async throws -> Data? {
        let token = try await accessToken()
        guard let folder = try await folderId(token, createIfMissing: false),
              let file = try await fileId(token, in: folder) else { return nil }
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(file)?alt=media")!
        let (data, code) = try await run(request(url, "GET", token: token), ctx: "скачивание")
        return code == 404 ? nil : data
    }

    func put(_ data: Data) async throws {
        let token = try await accessToken()
        let folder = try await folderId(token, createIfMissing: true)!
        var file = try await fileId(token, in: folder)
        if file == nil {
            // Метадата POST (имя+родитель), контент — отдельным PATCH, как на ведре.
            let meta = try JSONSerialization.data(withJSONObject: [
                "name": Self.fileName,
                "parents": [folder],
            ])
            let (resp, _) = try await run(request(
                URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!,
                "POST", token: token, body: meta, contentType: "application/json"), ctx: "создание файла")
            file = json(resp)["id"] as? String
        }
        guard let file else { throw GDError.http(0, "нет id файла") }
        let up = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(file)?uploadType=media")!
        _ = try await run(request(up, "PATCH", token: token, body: data,
                                  contentType: "application/octet-stream"), ctx: "заливка")
    }
}

// MARK: - OAuth для десктопа: браузер + loopback-редирект на 127.0.0.1

enum GDriveOAuth {

    enum OAuthError: LocalizedError {
        case denied, badResponse(String)
        var errorDescription: String? {
            switch self {
            case .denied: return "Доступ не выдан (отменено в браузере)"
            case .badResponse(let d): return "OAuth: \(d)"
            }
        }
    }

    /// Полная петля: локальный листенер → браузер → code → обмен на refresh token.
    static func signIn(clientId: String, clientSecret: String) async throws -> String {
        let server = try LoopbackServer()
        defer { server.stop() }
        let port = server.port
        let redirect = "http://127.0.0.1:\(port)"
        let state = UUID().uuidString

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        await MainActor.run { NSWorkspace.shared.open(auth.url!) }

        let params = try await server.waitForRedirect()
        if params["error"] != nil { throw OAuthError.denied }
        guard params["state"] == state, let code = params["code"] else {
            throw OAuthError.badResponse("нет кода / чужой state")
        }

        var body = URLComponents()
        body.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: clientId),
            .init(name: "client_secret", value: clientSecret),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "grant_type", value: "authorization_code"),
        ]
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let refresh = obj["refresh_token"] as? String else {
            throw OAuthError.badResponse((obj["error_description"] as? String)
                ?? (obj["error"] as? String) ?? "обмен кода не удался")
        }
        return refresh
    }
}

/// Одноразовый HTTP-листенер: ловит редирект гугла, отдаёт «можно закрыть».
final class LoopbackServer {
    private let socket: Int32
    let port: UInt16

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd); throw POSIXError(.EADDRINUSE)
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        self.socket = fd
        self.port = UInt16(bigEndian: bound.sin_port)
    }

    func stop() { close(socket) }

    /// Ждёт один GET, парсит query, отвечает страничкой.
    func waitForRedirect() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { [socket] in
                let client = accept(socket, nil, nil)
                guard client >= 0 else {
                    cont.resume(throwing: POSIXError(.ECONNABORTED)); return
                }
                defer { close(client) }
                var buffer = [UInt8](repeating: 0, count: 8192)
                let n = read(client, &buffer, buffer.count)
                let text = String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self)
                let html = "<html><body style='font-family:-apple-system'><h3>QTerm подключён к Google Drive</h3>Окно можно закрыть.</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                _ = response.withCString { write(client, $0, strlen($0)) }

                // "GET /?code=...&state=... HTTP/1.1"
                guard let line = text.split(separator: "\r\n").first,
                      let target = line.split(separator: " ").dropFirst().first,
                      let comps = URLComponents(string: String(target)) else {
                    cont.resume(throwing: GDriveOAuth.OAuthError.badResponse("не распарсился редирект"))
                    return
                }
                var params: [String: String] = [:]
                for item in comps.queryItems ?? [] { params[item.name] = item.value }
                cont.resume(returning: params)
            }
        }
    }
}

// MARK: - Движок

@MainActor
final class SyncEngine: ObservableObject {

    enum Status: Equatable {
        case idle
        case running
        case ok(String)      // «14:02:11 · слито»
        case error(String)
    }

    @Published private(set) var status: Status = .idle
    weak var app: AppState?

    private let store: SessionStore
    private var debounceTask: Task<Void, Never>?
    private var running = false
    private var rerunRequested = false

    init(store: SessionStore) {
        self.store = store
    }

    // MARK: Конфиг в локальном вейлте (secrets["sync.config"])

    var config: SyncConfig {
        get {
            guard let raw = (try? store.load().secrets)?[SyncConfig.secretKey],
                  let data = raw.data(using: .utf8),
                  let cfg = try? JSONDecoder().decode(SyncConfig.self, from: data)
            else { return SyncConfig() }
            return cfg
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8) else { return }
            var secrets = (try? store.load().secrets) ?? [:]
            secrets[SyncConfig.secretKey] = raw
            try? store.save(secrets: secrets)
        }
    }

    func reportError(_ text: String) { status = .error(text) }

    // MARK: Триггеры

    /// Пуш с дебаунсом 2с — дёргается после каждой мутации вейлта.
    func schedulePush() {
        guard config.enabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Пул на старте приложения.
    func pullOnLaunch() {
        guard config.enabled else { return }
        Task { await syncNow() }
    }

    // MARK: Полный цикл pull → merge → push

    func syncNow() async {
        let cfg = config
        guard cfg.enabled else { return }
        guard !cfg.encPassword.isEmpty else {
            status = .error("Пустой пароль шифрования")
            return
        }
        let transport: SyncTransport
        if cfg.isGDrive {
            guard cfg.gdConnected else {
                status = .error("Google не подключён — «Войти в Google»")
                return
            }
            transport = GDrive(
                clientId: SyncConfig.googleClientId,
                clientSecret: SyncConfig.googleClientSecret,
                refreshToken: cfg.gdRefreshToken ?? "",
                folderName: (cfg.gdFolder?.isEmpty == false ? cfg.gdFolder! : "QTerm")
            )
        } else {
            guard let url = URL(string: cfg.url), url.scheme?.hasPrefix("http") == true else {
                status = .error("Некорректный URL файла")
                return
            }
            transport = WebDAV(url: url, login: cfg.login, password: cfg.webdavPassword)
        }
        // Не гоняем два цикла параллельно; пришедший во время работы — после.
        if running { rerunRequested = true; return }
        running = true
        status = .running
        defer {
            running = false
            if rerunRequested {
                rerunRequested = false
                Task { await self.syncNow() }
            }
        }

        do {
            let local = try store.load()
            var merged = local
            var summary = "первый пуш"

            if let blob = try await transport.get() {
                let payload = try QTS1.unpack(blob, password: cfg.encPassword)
                let remote = try SyncJSON.decoder().decode(SessionVault.self, from: payload)
                merged = SyncMerge.merge(local: local, remote: remote)
                summary = "слито: сессий \(merged.sessions.count), ключей \((merged.sshKeys ?? []).count)"
            }

            // Локально: сохранить merge (конфиг синка в secrets уже внутри).
            try store.save(
                sessions: merged.sessions,
                snippets: merged.snippets,
                secrets: merged.secrets,
                sshKeys: merged.sshKeys,
                cmdHistory: merged.cmdHistory
            )
            app?.loadVault()

            // В облако: копия БЕЗ "sync.*"-секретов.
            var cloud = merged
            cloud.secrets = (merged.secrets ?? [:]).filter { !$0.key.hasPrefix("sync.") }
            let payload = try SyncJSON.encoder().encode(cloud)
            try await transport.put(try QTS1.pack(payload: payload, password: cfg.encPassword))

            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            status = .ok("\(f.string(from: Date())) · \(summary)")
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}

// MARK: - UI настроек

struct SyncSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine: SyncEngine

    @State private var cfg = SyncConfig()
    @State private var signingIn = false

    private func bind(_ path: WritableKeyPath<SyncConfig, String?>) -> Binding<String> {
        Binding(
            get: { cfg[keyPath: path] ?? "" },
            set: { cfg[keyPath: path] = $0.isEmpty ? nil : $0 }
        )
    }

    private func signIn() {
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                let token = try await GDriveOAuth.signIn(
                    clientId: SyncConfig.googleClientId,
                    clientSecret: SyncConfig.googleClientSecret
                )
                cfg.gdRefreshToken = token
                engine.config = cfg
            } catch {
                engine.reportError("Вход в Google: \(error.localizedDescription)")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Синхронизация вейлта").font(.headline)
            Text("Все устройства смотрят в один файл на WebDAV. Сервер видит только шифротекст (Argon2id + AES-256-GCM). Пароль шифрования должен совпадать на всех устройствах.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Бекенд", selection: Binding(
                get: { cfg.backend ?? "webdav" },
                set: { cfg.backend = $0 }
            )) {
                Text("WebDAV / Яндекс").tag("webdav")
                Text("Google Drive").tag("gdrive")
            }
            .pickerStyle(.segmented)

            Form {
                if cfg.isGDrive {
                    TextField("Папка на Диске", text: bind(\.gdFolder), prompt: Text("QTerm"))
                    HStack {
                        if cfg.gdConnected {
                            Label("Подключён", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Button("Выйти") { cfg.gdRefreshToken = nil }
                        } else {
                            Button("Войти в Google") { signIn() }
                        }
                        if signingIn {
                            ProgressView().controlSize(.small)
                        }
                    }
                } else {
                    TextField("URL файла", text: $cfg.url, prompt: Text("https://host/dav/qterm.qtsync"))
                        .autocorrectionDisabled()
                    TextField("Логин WebDAV", text: $cfg.login)
                        .autocorrectionDisabled()
                    SecureField("Пароль WebDAV", text: $cfg.webdavPassword)
                }
                SecureField("Пароль шифрования", text: $cfg.encPassword)
                Toggle("Синхронизация включена", isOn: $cfg.enabled)
            }
            .formStyle(.columns)

            HStack(spacing: 8) {
                statusView
                Spacer()
                Button("Синк сейчас") {
                    engine.config = cfg
                    Task { await engine.syncNow() }
                }
                .disabled(!cfg.enabled)
                Button("Закрыть") {
                    engine.config = cfg
                    if cfg.enabled { engine.schedulePush() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { cfg = engine.config }
    }

    @ViewBuilder
    private var statusView: some View {
        switch engine.status {
        case .idle:
            Text("—").font(.caption).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Синхронизация…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let text):
            Label(text, systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
