import Foundation

/// Бэкап базы панели: файл, панель, версия панели на момент снятия, время.
struct XuiBackup: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let panel: String
    let version: String      // без «v»; пусто — старый бэкап без версии
    let time: Date
    let size: Int64
    var fileName: String { (path as NSString).lastPathComponent }
}

/// Бэкапы баз 3x-ui в ~/Library/Application Support/QTerm/xui-backup: «ИМЯ__vВЕРСИЯ__ГГГГММДД-ЧЧММСС.db»
/// (тот же формат, что на Windows). Снимаются перед любым изменением: ревизия, подключение ноды,
/// обновление, смена ядра, восстановление, откат.
enum XuiBackups {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QTerm/xui-backup", isDirectory: true)
    }

    private static let named = try! NSRegularExpression(pattern: "^(.*)__v(.+?)__(\\d{8}-\\d{6})\\.db$")
    private static let legacy = try! NSRegularExpression(pattern: "^(.*)-(\\d{8}-\\d{6})\\.db$")

    static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
    }

    static func norm(_ v: String?) -> String {
        var s = (v ?? "").trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func panelVersion(_ api: XuiAPI) async -> String {
        guard let st = try? await api.status() else { return "" }
        return norm(J.str(st, "panelVersion"))
    }

    static func save(_ api: XuiAPI, _ name: String) async throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ver = await panelVersion(api)
        if ver.isEmpty { ver = "unknown" }
        let url = dir.appendingPathComponent("\(safe(name))__v\(ver)__\(stampFmt.string(from: Date())).db")
        try await api.getDb().write(to: url)
        return url.path
    }

    private static func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }

    static func list() -> [XuiBackup] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [XuiBackup] = []
        for fn in files where fn.hasSuffix(".db") {
            let path = dir.appendingPathComponent(fn).path
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = attrs?[.modificationDate] as? Date ?? Date()
            var panel = (fn as NSString).deletingPathExtension, version = "", stamp = ""
            if let g = groups(named, fn) { panel = g[1]; version = g[2] == "unknown" ? "" : g[2]; stamp = g[3] }
            else if let g = groups(legacy, fn) { panel = g[1]; stamp = g[2] }
            out.append(XuiBackup(path: path, panel: panel, version: version,
                                 time: stampFmt.date(from: stamp) ?? mtime, size: size))
        }
        return out.sorted { $0.time > $1.time }
    }

    /// Бэкапы этой панели (по имени; старые бэкапы главной назывались «master»).
    static func forPanel(_ p: XuiPanel) -> [XuiBackup] {
        list().filter {
            $0.panel.caseInsensitiveCompare(safe(p.name)) == .orderedSame ||
                (p.isMaster && $0.panel.caseInsensitiveCompare("master") == .orderedSame)
        }
    }

    /// Сравнение версий «3.9.0» / «v3.8.5».
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] { norm(s).split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
