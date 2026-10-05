import Foundation
import CryptoKit

// «Каскад» (порт QTerm Windows, волна 37): сервер с 3x-ui (+ AWG) как маршрутизатор «как на Кинетике» —
// mihomo с правилами роутеров, ноды из Clash-подписки главной, трафик клиентов 3x-ui перехватывается в mihomo.
// На сервере — qcascade (scripts/vpn-cascade.sh, вшит в QTerm: CascadeScript.swift генерится make-app.sh).
// Записи — в vault.secrets под "xui.cascade:<UUID>", тот же JSON, что пишет Windows; синк LWW как xui.panel.

struct CascadeServer: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString.lowercased()
    var name = ""
    /// id SSH-сессии QTerm этого сервера.
    var ssh = ""
    /// Клиент главной, чья Clash-подписка стоит на сервере (для показа; ссылка — только на сервере).
    var client: String?
    var updatedAt: String?
    var deleted: Bool?

    enum CodingKeys: String, CodingKey { case id, name, ssh, client, updatedAt, deleted }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        ssh = try c.decodeIfPresent(String.self, forKey: .ssh) ?? ""
        client = try c.decodeIfPresent(String.self, forKey: .client)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
    }

    var key: String { (UUID(uuidString: id)?.uuidString ?? id).uppercased() }
    var sessionID: UUID? { UUID(uuidString: ssh) }
}

/// Операции qcascade на сервере поверх exec-канала SSH-сессии (терминал не трогается).
/// Каждая команда: stderr в stdout, код возврата — маркером @@QCRC в конце вывода (так exec не падает на ненулевом коде).
@MainActor
final class CascadeRemote {
    static let bin = "/usr/local/sbin/qcascade"
    private static let script = "vpn-cascade.sh"           // в домашней папке пользователя SSH
    private static let instLog = ".qcascade-install.log"
    private static let instRc = ".qcascade-install.rc"
    private static let chunk = 60000                       // base64 на команду: < 128 КБ на аргумент bash -c

    struct Result {
        let rc: Int
        let out: String
        var ok: Bool { rc == 0 }
    }

    private let exec: (String, Int) async throws -> String
    private var sudo: String?

    init(_ exec: @escaping (String, Int) async throws -> String) { self.exec = exec }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func short(_ s: String) -> String { s.count > 300 ? String(s.prefix(300)) + "…" : s }

    func run(_ cmd: String, _ timeout: Int = 60) async throws -> Result {
        let out = try await exec("{ " + cmd + "\n} 2>&1; printf '\\n@@QCRC=%d\\n' $?", timeout)
        guard let r = out.range(of: "@@QCRC=", options: .backwards) else {
            return Result(rc: -1, out: out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let rc = Int(out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        var body = String(out[..<r.lowerBound])
        while let last = body.last, last == "\n" || last == "\r" { body.removeLast() }
        return Result(rc: rc, out: body)
    }

    /// "" под root, "sudo -n " — если не root, но sudo без пароля есть.
    func sudoPrefix() async throws -> String {
        if let s = sudo { return s }
        let r = try await run("id -u", 30)
        guard r.ok else { throw XuiError("сервер не выполняет команды: " + r.out) }
        if r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "0" { sudo = ""; return "" }
        guard try await run("sudo -n true", 30).ok else {
            throw XuiError("нужен root или sudo без пароля — войди в SSH-сессии под root")
        }
        sudo = "sudo -n "
        return "sudo -n "
    }

    func qc(_ args: String, _ timeout: Int = 120) async throws -> Result {
        try await run(try await sudoPrefix() + Self.bin + " " + args, timeout)
    }

    /// Версия qcascade на сервере; nil — не установлен.
    func remoteVersion() async throws -> String? {
        let r = try await run("[ -x \(Self.bin) ] && \(Self.bin) version", 30)
        guard r.ok, let m = r.out.range(of: #"qcascade\s+\S+"#, options: .regularExpression) else { return nil }
        return r.out[m].split(separator: " ", omittingEmptySubsequences: true).last.map(String.init)
    }

    private static func obj(_ s: String) -> JObj? {
        guard let i = s.firstIndex(of: "{") else { return nil }
        return J.parse(Data(s[i...].utf8)) as? JObj
    }

    func status() async throws -> JObj {
        let r = try await qc("status --json 2>/dev/null", 60)
        guard let o = Self.obj(r.out) else { throw XuiError("qcascade status не вернул JSON: " + Self.short(r.out)) }
        return o
    }

    /// Инбаунды и клиенты 3x-ui сервера — для выбора «кого каскадить».
    func xrayList() async throws -> JObj {
        let r = try await qc("xray list 2>/dev/null", 60)
        guard let o = Self.obj(r.out) else { throw XuiError("qcascade xray list не вернул JSON: " + Self.short(r.out)) }
        return o
    }

    // MARK: файлы

    /// Заливка в файл (путь от домашней папки или абсолютный): base64-чанки + сверка sha256.
    func upload(_ path: String, _ data: Data, mode: String? = nil) async throws {
        let b64 = data.base64EncodedString()
        let tmp = path + ".b64"
        var r = try await run(": > \(Self.q(tmp))", 30)
        guard r.ok else { throw XuiError("не пишется файл на сервере: " + r.out) }
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: Self.chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            r = try await run("printf %s \(Self.q(String(b64[i..<j]))) >> \(Self.q(tmp))", 60)
            guard r.ok else { throw XuiError("заливка оборвалась: " + r.out) }
            i = j
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        r = try await run("base64 -d \(Self.q(tmp)) > \(Self.q(path)) && rm -f \(Self.q(tmp))" +
                          (mode.map { " && chmod \($0) \(Self.q(path))" } ?? "") + " && sha256sum \(Self.q(path))", 60)
        guard r.ok, r.out.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(sha) else {
            throw XuiError("файл доехал до сервера битым: " + Self.short(r.out))
        }
    }

    func readRootFile(_ path: String) async throws -> String {
        let r = try await run(try await sudoPrefix() + "cat " + Self.q(path), 60)
        guard r.ok else { throw XuiError("не прочитался \(path): \(Self.short(r.out))") }
        return r.out.replacingOccurrences(of: "\r\n", with: "\n")
    }

    func writeRootFile(_ path: String, _ text: String) async throws {
        let tmp = ".qcascade-upload.tmp"
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        if !body.hasSuffix("\n") { body += "\n" }
        try await upload(tmp, Data(body.utf8))
        let r = try await run("\(try await sudoPrefix())install -m 644 \(Self.q(tmp)) \(Self.q(path)) && rm -f \(Self.q(tmp))", 60)
        guard r.ok else { throw XuiError("не записался \(path): \(Self.short(r.out))") }
    }

    // MARK: скрипт

    static var scriptData: Data {
        var t = CascadeScript.text.replacingOccurrences(of: "\r\n", with: "\n")
        if !t.hasSuffix("\n") { t += "\n" }
        return Data(t.utf8)
    }

    static let scriptVersion: String = {
        let t = CascadeScript.text
        guard let r = t.range(of: #"VERSION="[^"]+""#, options: .regularExpression) else { return "?" }
        return String(t[r]).replacingOccurrences(of: "VERSION=", with: "").replacingOccurrences(of: "\"", with: "")
    }()

    /// a новее b (семвер).
    static func newer(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        let pa = a.split(separator: ".").compactMap { Int($0) }, pb = b.split(separator: ".").compactMap { Int($0) }
        for k in 0..<max(pa.count, pb.count) {
            let x = k < pa.count ? pa[k] : 0, y = k < pb.count ? pb[k] : 0
            if x != y { return x > y }
        }
        return false
    }

    func uploadScript() async throws { try await upload(Self.script, Self.scriptData, mode: "700") }

    /// Настройки qcascade строками K=V через stdin (не аргументами — ссылка подписки не светится в ps).
    func set(_ env: [(String, String)], viaScript: Bool = false) async throws {
        let lines = env.map { "\($0.0)=\($0.1.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " "))\n" }.joined()
        let b64 = Data(lines.utf8).base64EncodedString()
        let target = viaScript ? "bash ./\(Self.script)" : Self.bin
        let r = try await run("printf %s \(Self.q(b64)) | base64 -d | \(try await sudoPrefix())\(target) set -", 60)
        guard r.ok else { throw XuiError("настройки не сохранились: " + Self.short(r.out)) }
    }

    /// Установка в фоне (setsid nohup): переживает обрыв SSH; лог и код — в домашней папке.
    func startInstall() async throws {
        let s = try await sudoPrefix()
        let r = try await run("rm -f \(Self.instRc); setsid nohup sh -c '\(s)env QC_NONINTERACTIVE=1 bash ./\(Self.script) install; echo $? > \(Self.instRc)' " +
                              "> \(Self.instLog) 2>&1 < /dev/null &", 30)
        guard r.ok else { throw XuiError("установка не запустилась: " + Self.short(r.out)) }
    }

    /// Новые строки лога установки, сколько строк всего и код возврата (когда закончилась).
    func pollInstall(_ have: Int) async throws -> (lines: [String], total: Int, rc: Int?) {
        // код читаем ДО подсчёта строк: появился код — лог уже дописан целиком
        let r = try await run("r=$(cat \(Self.instRc) 2>/dev/null); t=$(wc -l < \(Self.instLog) 2>/dev/null || echo 0); " +
                              "echo \"@@RC=$r\"; echo \"@@T=$t\"; [ \"$t\" -gt \(have) ] && sed -n \"$((\(have)+1)),${t}p\" \(Self.instLog); true", 60)
        var rc: Int?
        var total = have
        var body: [String] = []
        for l in r.out.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            if l.hasPrefix("@@RC=") { rc = Int(l.dropFirst(5).trimmingCharacters(in: .whitespaces)) }
            else if l.hasPrefix("@@T=") { if let t = Int(l.dropFirst(4).trimmingCharacters(in: .whitespaces)) { total = max(have, t) } }
            else { body.append(l) }
        }
        return (body, total, rc)
    }
}
