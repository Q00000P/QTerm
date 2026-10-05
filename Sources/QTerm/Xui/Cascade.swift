import Foundation
import CryptoKit

// «Каскад» (порт QTerm Windows, волна 38): сервер с 3x-ui / AWG-панелью / MTProto как маршрутизатор «как на Кинетике» —
// mihomo с правилами роутеров, ноды из своих источников (клиент каскада на любой панели 3x-ui, ссылки подписок,
// WireGuard/AWG — в т.ч. резерв), перехват клиентов сервера. На сервере — qcascade (scripts/vpn-cascade.sh,
// вшит в QTerm: CascadeScript.swift генерит make-app.sh). Записи — в vault.secrets под "xui.cascade:<UUID>",
// тот же JSON, что пишет Windows; синк LWW как xui.panel.

struct CascadeServer: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString.lowercased()
    var name = ""
    /// id SSH-сессии QTerm этого сервера.
    var ssh = ""
    /// Хост SSH-сессии — найти сервер, если сессию пересоздали или на другом устройстве у неё другой id.
    var host: String?
    /// v1: клиент главной, чья подписка стояла на сервере (только для показа).
    var client: String?
    var updatedAt: String?
    var deleted: Bool?

    enum CodingKeys: String, CodingKey { case id, name, ssh, host, client, updatedAt, deleted }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        ssh = try c.decodeIfPresent(String.self, forKey: .ssh) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
    }

    var key: String { (UUID(uuidString: id)?.uuidString ?? id).uppercased() }
    var sessionID: UUID? { UUID(uuidString: ssh) }
}

/// Источник нод каскада — запись /etc/qcascade/sources.json на сервере.
/// sub — Clash/Mihomo-подписка (свой клиент на панели 3x-ui или любая ссылка), wg — WireGuard/AmneziaWG-конфиг.
/// meta — откуда взят (kind: xui | link | awg | conf, панель, клиент, инбаунды); скрипт его не трогает.
struct CascadeSource: Identifiable {
    var id: String { name }
    var name = ""
    var type = "sub"
    var url = ""
    var conf = ""
    var enabled = true
    var prefix = ""
    var meta: JObj = [:]

    static func validName(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9._-]{1,32}$"#, options: .regularExpression) != nil }
    static func validPrefix(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9._-]{0,16}$"#, options: .regularExpression) != nil }

    var isWg: Bool { type == "wg" }
    var kind: String { let k = J.str(meta, "kind"); return k.isEmpty ? (isWg ? "conf" : "link") : k }
    func m(_ k: String) -> String { J.str(meta, k) }
    var panelId: String { m("panel").lowercased() }
    var metaInbounds: [Int] { ((meta["inbounds"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue } }

    init() {}

    init(_ o: JObj) {
        name = J.str(o, "name")
        let t = J.str(o, "type")
        type = t.isEmpty ? "sub" : t
        url = J.str(o, "url")
        conf = J.str(o, "conf")
        enabled = J.bool(o, "enabled", true)
        prefix = J.str(o, "prefix")
        meta = o["meta"] as? JObj ?? [:]
    }

    var json: JObj {
        var o: JObj = ["name": name, "type": type, "enabled": enabled, "prefix": prefix, "meta": meta]
        if isWg { o["conf"] = conf } else { o["url"] = url }
        return o
    }

    /// Откуда источник — для списка.
    var origin: String {
        switch kind {
        case "xui":
            let n = metaInbounds.count
            return "клиент \(m("client")) на панели \(m("panelName"))" + (n > 0 ? " · инбаундов \(n)" : "")
        case "awg":
            return "клиент \(m("client")) AWG-панели \(m("panelName"))" + (m("iface").isEmpty ? "" : " (\(m("iface")))")
        case "conf": return "конфиг WireGuard / AWG"
        default: return "ссылка подписки"
        }
    }

    /// Быстрая проверка конфига WireGuard до отправки на сервер (полная — в скрипте).
    static func checkWgConf(_ conf: String) -> String? {
        let t = conf.replacingOccurrences(of: "\r", with: "")
        func has(_ re: String) -> Bool { t.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil }
        if !has(#"(?m)^\s*\[Interface\]"#) { return "нет раздела [Interface]" }
        if !has(#"(?m)^\s*\[Peer\]"#) { return "нет раздела [Peer]" }
        for k in ["PrivateKey", "Address", "PublicKey", "Endpoint"] where !has(#"(?m)^\s*"# + k + #"\s*=\s*\S"#) { return "нет \(k)" }
        return nil
    }
}

/// Операции qcascade на сервере поверх exec-канала SSH-сессии (терминал не трогается).
/// Каждая команда: stderr в stdout, код возврата — маркером @@QCRC в конце вывода (так exec не падает на ненулевом коде).
@MainActor
final class CascadeRemote {
    static let bin = "/usr/local/sbin/qcascade"
    private static let script = "vpn-cascade.sh"           // в домашней папке пользователя SSH
    private static let instLog = ".qcascade-install.log"
    private static let instRc = ".qcascade-install.rc"
    private static let srcFile = ".qcascade-src.json"      // источники для первой установки (600, скрипт удаляет)
    private static let pipeFile = ".qcascade-pipe.tmp"
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

    static func short(_ s: String) -> String { s.count > 400 ? String(s.prefix(400)) + "…" : s }

    /// Вывод qcascade без цветовых кодов и [ERR].
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\x1B\[[0-9;]*m"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ERR]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

    /// Текст на stdin команды root (настройки, источники) — секреты не аргументами команды.
    /// Большой текст (WG-конфиги) — через временный файл 600 в домашней папке.
    func pipe(_ text: String, _ target: String, _ timeout: Int = 120) async throws -> Result {
        let data = Data(text.utf8)
        let s = try await sudoPrefix()
        if data.count * 4 / 3 < Self.chunk {
            return try await run("printf %s \(Self.q(data.base64EncodedString())) | base64 -d | \(s)\(target)", timeout)
        }
        try await upload(Self.pipeFile, data, mode: "600")
        return try await run("\(s)\(target) < \(Self.pipeFile); rc=$?; rm -f \(Self.pipeFile); exit $rc", timeout)
    }

    /// Версия qcascade на сервере; nil — не установлен.
    /// Версия qcascade на сервере; nil — не установлен. Сбой связи или команды — ошибка, а не «не установлен»
    /// (иначе QTerm предложил бы чистую установку поверх рабочей).
    func remoteVersion() async throws -> String? {
        let r = try await run("if [ -x \(Self.bin) ]; then \(Self.bin) version; else echo @@NOQC; fi", 30)
        if r.out.contains("@@NOQC") { return nil }
        if let m = r.out.range(of: #"qcascade\s+\d+(\.\d+)+\S*"#, options: .regularExpression) {
            return r.out[m].split(separator: " ", omittingEmptySubsequences: true).last.map(String.init)
        }
        throw XuiError("не узнать версию qcascade на сервере: " + Self.why(r))
    }

    /// JSON-объект из вывода команды. stderr идёт туда же (run): предупреждения до объекта и строки после него
    /// не мешают — объект скрипта всегда начинается с новой строки.
    private static func obj(_ s: String) -> JObj? {
        let b = Array(s.utf8)
        var i = 0
        while i < b.count {
            if b[i] == 0x7B, i == 0 || b[i - 1] == 0x0A, let end = objectEnd(b, i),
               let o = J.parse(Data(b[i...end])) as? JObj { return o }
            i += 1
        }
        return nil
    }

    /// Конец JSON-объекта с позиции start: скобки с учётом строк и экранирования.
    private static func objectEnd(_ b: [UInt8], _ start: Int) -> Int? {
        var depth = 0, inStr = false, esc = false
        var i = start
        while i < b.count {
            let c = b[i]
            if inStr {
                if esc {
                    esc = false
                } else if c == 0x5C {          // \
                    esc = true
                } else if c == 0x22 {          // "
                    inStr = false
                }
            } else if c == 0x22 {
                inStr = true
            } else if c == 0x7B || c == 0x5B { // { [
                depth += 1
            } else if c == 0x7D || c == 0x5D { // } ]
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// Почему команда не дала ответа: хвост её вывода (там ошибка) или код возврата.
    static func why(_ r: Result) -> String {
        let lines = clean(r.out).replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.isEmpty ? "пустой ответ (код \(r.rc))" : short(lines.suffix(8).joined(separator: "\n"))
    }

    func status() async throws -> JObj {
        let r = try await qc("status --json", 90)
        guard let o = Self.obj(r.out) else { throw XuiError("qcascade status не отдал JSON: " + Self.why(r)) }
        return o
    }

    /// Что есть на сервере: 3x-ui (инбаунды, клиенты), интерфейсы AWG, MTProto (пользователи, контейнеры).
    func detect() async throws -> JObj {
        let r = try await qc("detect", 90)
        guard let o = Self.obj(r.out) else { throw XuiError("qcascade detect не отдал JSON: " + Self.why(r)) }
        return o
    }

    /// Источники целиком (со ссылками и конфигами — только для правки, в QTerm не хранятся).
    func sources() async throws -> [CascadeSource] {
        let r = try await qc("sources get", 60)
        guard r.ok, let o = Self.obj(r.out) else { throw XuiError("источники не прочитались: " + Self.short(r.out)) }
        return ((o["sources"] as? [Any]) ?? []).compactMap { $0 as? JObj }.map(CascadeSource.init)
    }

    static func sourcesJSON(_ list: [CascadeSource]) -> String {
        String(decoding: J.data(["v": 1, "sources": list.map(\.json)] as JObj), as: UTF8.self)
    }

    /// Записать источники (сервер проверяет их сам). Применение — отдельно (apply).
    func saveSources(_ list: [CascadeSource]) async throws {
        let r = try await pipe(Self.sourcesJSON(list), Self.bin + " sources set -")
        guard r.ok else { throw XuiError(Self.short(Self.clean(r.out))) }
    }

    func logs(_ n: Int = 300) async throws -> String { try await qc("logs \(n)", 60).out }

    // MARK: файлы

    /// Заливка в файл (путь от домашней папки или абсолютный): base64-чанки + сверка sha256.
    /// Файл создаётся с umask 077 — секреты не читаются другими пользователями даже во время заливки.
    func upload(_ path: String, _ data: Data, mode: String? = nil) async throws {
        let b64 = data.base64EncodedString()
        let tmp = path + ".b64"
        var r = try await run("rm -f \(Self.q(tmp)); umask 077; : > \(Self.q(tmp))", 30)
        guard r.ok else { throw XuiError("не пишется файл на сервере: " + r.out) }
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: Self.chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            r = try await run("printf %s \(Self.q(String(b64[i..<j]))) >> \(Self.q(tmp))", 60)
            guard r.ok else { throw XuiError("заливка оборвалась: " + r.out) }
            i = j
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        r = try await run("rm -f \(Self.q(path)); umask 077; base64 -d \(Self.q(tmp)) > \(Self.q(path)) && rm -f \(Self.q(tmp))" +
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

    /// Сервер на qcascade 2.x — источники, AWG, MTProto, резерв.
    static func isV2(_ ver: String?) -> Bool { ver != nil && !newer("2.0.0", ver) }

    /// qcascade 2.0.2+: WEB-прокси и telemt через каскад (QC_MTP_WEB / QC_MTP_TELEMT).
    static func hasMtpSink(_ ver: String?) -> Bool { ver != nil && !newer("2.0.2", ver) }

    func uploadScript() async throws { try await upload(Self.script, Self.scriptData, mode: "700") }

    /// Настройки qcascade строками K=V через stdin. До установки — через залитый скрипт.
    func set(_ env: [(String, String)], viaScript: Bool = false) async throws {
        let lines = env.map { "\($0.0)=\($0.1.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " "))\n" }.joined()
        let r = try await pipe(lines, (viaScript ? "bash ./\(Self.script)" : Self.bin) + " set -", 60)
        guard r.ok else { throw XuiError("настройки не сохранились: " + Self.short(Self.clean(r.out))) }
    }

    /// Установка в фоне (setsid nohup): переживает обрыв SSH; лог и код — в домашней папке.
    /// sourcesJSON — источники для первой установки (файл 600, скрипт забирает и удаляет).
    func startInstall(sourcesJSON: String? = nil) async throws {
        let s = try await sudoPrefix()
        var srcEnv = ""
        if let json = sourcesJSON {
            try await upload(Self.srcFile, Data(json.utf8), mode: "600")
            srcEnv = " QC_SOURCES_FILE=\"$PWD/\(Self.srcFile)\""
        }
        let r = try await run("rm -f \(Self.instRc); setsid nohup sh -c '\(s)env QC_NONINTERACTIVE=1\(srcEnv) bash ./\(Self.script) install; " +
                              "echo $? > \(Self.instRc); rm -f \(Self.srcFile)' > \(Self.instLog) 2>&1 < /dev/null &", 30)
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
