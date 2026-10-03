import Foundation

/// Унификатор имён клиентов: S26 / s26 / S-26 / «S26 HYS» / s26_hys / ЛАП-hys → один ключ (S26, LAP),
/// ключ → каноническое имя из списка. Служебные хвосты (HYS/HY2/…, имена нод и входящих) отрезаются
/// с краёв, кириллица понимается и как похожие латинские буквы (МАМА), и как транслит (ЛАП → LAP).
/// Индекс протокола: без индекса — VLESS, -HYS — Hysteria, -SYNC — оба. Порт NameUnifier.cs.
final class NameUnifier {
    static let hysTokens: Set<String> = ["HYS", "HY2", "HYST", "HYSTERIA", "HYSTERIA2"]
    static let suffixTokens: Set<String> = hysTokens.union(["SYNC"])

    private static let confusable: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "Ё": "E", "К": "K", "М": "M", "Н": "H", "О": "O",
        "Р": "P", "С": "C", "Т": "T", "У": "Y", "Х": "X", "І": "I",
        "а": "A", "в": "B", "е": "E", "ё": "E", "к": "K", "м": "M", "н": "H", "о": "O",
        "р": "P", "с": "C", "т": "T", "у": "Y", "х": "X", "і": "I",
    ]

    private static let translit: [Character: String] = [
        "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Е": "E", "Ё": "E", "Ж": "ZH",
        "З": "Z", "И": "I", "Й": "Y", "К": "K", "Л": "L", "М": "M", "Н": "N", "О": "O",
        "П": "P", "Р": "R", "С": "S", "Т": "T", "У": "U", "Ф": "F", "Х": "H", "Ц": "TS",
        "Ч": "CH", "Ш": "SH", "Щ": "SCH", "Ъ": "", "Ы": "Y", "Ь": "", "Э": "E", "Ю": "YU",
        "Я": "YA", "І": "I",
    ]

    private static let suffixTail = try! NSRegularExpression(
        pattern: "^(.*?)[\\s_.\\-]+(hysteria2?|hyst|hys|hy2|sync)$", options: [.caseInsensitive])

    /// Имя без индекса протокола: «PC-HYS» / «PC-SYNC» → «PC».
    static func baseText(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while true {
            let ns = t as NSString
            guard let m = suffixTail.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return t }
            let b = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
            if b.isEmpty { return t }
            t = b
        }
    }

    /// Правило имён: без индекса — VLESS, -HYS — Hysteria, -SYNC — сдвоенный.
    static func withIndex(_ base: String, vless: Bool, hys: Bool) -> String {
        base + (vless && hys ? "-SYNC" : hys ? "-HYS" : "")
    }

    /// ключ → каноническое имя для показа
    private(set) var canon: [String: String] = [:]
    /// ключ синонима → ключ канона
    private var alias: [String: String] = [:]

    func isCanonical(_ key: String) -> Bool { canon[key] != nil }

    init(_ cfg: XuiNamesConfig) {
        for raw in cfg.lines {
            let line = (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let eq = line.firstIndex(of: "="), eq != line.startIndex {
                let a = line[..<eq].trimmingCharacters(in: .whitespaces)
                let b = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if a.isEmpty || b.isEmpty { continue }
                let bk = Self.baseKey(b)
                if canon[bk] == nil { canon[bk] = Self.baseText(b) }
                alias[Self.baseKey(a)] = bk
                alias[Self.stripHys(Self.parts(Self.doTranslit(a)))] = bk
            } else {
                canon[Self.baseKey(line)] = Self.baseText(line)
            }
        }
    }

    // MARK: примитивы

    private static func doConfusable(_ s: String) -> String {
        String(s.map { confusable[$0] ?? $0 })
    }

    private static func doTranslit(_ s: String) -> String {
        s.uppercased().map { translit[$0] ?? String($0) }.joined()
    }

    /// Куски [A-Z0-9]+ из строки в верхнем регистре (всё остальное — разделители).
    private static func parts(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for u in s.uppercased().unicodeScalars {
            if (u >= "A" && u <= "Z") || (u >= "0" && u <= "9") {
                cur.unicodeScalars.append(u)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func stripHys(_ parts: [String]) -> String {
        var p = parts
        while p.count > 1, let last = p.last, suffixTokens.contains(last) { p.removeLast() }
        return p.joined()
    }

    /// Ключ канонического имени: без регистра/разделителей и без хвоста HYS/SYNC.
    static func baseKey(_ s: String) -> String { stripHys(parts(doConfusable(s))) }
    static func bareKey(_ s: String) -> String { parts(doConfusable(s)).joined() }
    static func tokensOf(_ s: String) -> [String] { parts(doConfusable(s)) }

    // MARK: разбор имени клиента

    /// email → (ключ, был ли хвост HYS). stripTokens — служебные хвосты (HYS, имена нод/входящих).
    func analyze(_ email: String, _ stripTokens: Set<String>, extraKnown: [String] = []) -> (key: String, hys: Bool) {
        var known = Set(canon.keys)
        known.formUnion(alias.keys)
        known.formUnion(extraKnown)
        let protect = Set(canon.keys)

        var results: [(String, Bool)] = []
        for variant in [Self.doConfusable(email), Self.doTranslit(email)] {
            var parts = Self.parts(variant)
            var hys = false
            var changed = true
            while changed && parts.count > 1 {
                changed = false
                for side in [-1, 0] {
                    if parts.count <= 1 { break }
                    let idx = side == -1 ? parts.count - 1 : 0
                    let tok = parts[idx]
                    // HYS/HY2 — только хвостом: «hy2@selfsni» — это имя, а не Hysteria
                    if side == 0 && Self.suffixTokens.contains(tok) { continue }
                    if stripTokens.contains(tok) && !protect.contains(tok) {
                        if Self.hysTokens.contains(tok) { hys = true }
                        parts.remove(at: idx)
                        changed = true
                    }
                }
            }
            var key = parts.joined()
            if !known.contains(key) {
                for t in Self.suffixTokens.sorted(by: { $0.count > $1.count }) {
                    if key.hasSuffix(t) && key.count > t.count && known.contains(String(key.dropLast(t.count))) {
                        key = String(key.dropLast(t.count))
                        if t != "SYNC" { hys = true }
                        break
                    }
                }
            }
            if let ak = alias[key] { key = ak }
            results.append((key, hys))
        }
        for r in results where known.contains(r.0) || canon[r.0] != nil { return (r.0, r.1) }
        return (results[0].0, results[0].1)
    }

    /// Итоговое имя: база (из списка или из текущих имён) + индекс протокола.
    func displayFor(_ key: String, _ emails: [String], _ fallback: String, vless: Bool, hys: Bool) -> String {
        var base = canon[key]
        if base == nil {
            for e in emails {
                let cand = Self.baseText(e)
                if !cand.isEmpty && Self.bareKey(cand) == key { base = cand; break }
            }
        }
        let b = base ?? Self.baseText(fallback)
        return !vless && !hys ? fallback : Self.withIndex(b, vless: vless, hys: hys)
    }
}
