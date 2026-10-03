import Foundation
import CryptoKit

// MARK: - Кодировки и концы строк (меню «Кодировка» / «Формат», канон Windows TextCodec)

struct TextEncodingChoice: Hashable, Identifiable {
    let name: String
    let encoding: String.Encoding
    let bom: Bool
    var id: String { name }

    static func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    static let utf8 = TextEncodingChoice(name: "UTF-8", encoding: .utf8, bom: false)
    static let utf8BOM = TextEncodingChoice(name: "UTF-8 с BOM", encoding: .utf8, bom: true)
    static let cp1251 = TextEncodingChoice(name: "Windows-1251", encoding: .windowsCP1251, bom: false)
    static let koi8r = TextEncodingChoice(name: "KOI8-R", encoding: TextEncodingChoice.cf(.KOI8_R), bom: false)
    static let cp866 = TextEncodingChoice(name: "CP866 (DOS)", encoding: TextEncodingChoice.cf(.dosRussian), bom: false)
    static let cp1252 = TextEncodingChoice(name: "Windows-1252", encoding: .windowsCP1252, bom: false)
    static let utf16LE = TextEncodingChoice(name: "UTF-16 LE", encoding: .utf16LittleEndian, bom: true)
    static let utf16BE = TextEncodingChoice(name: "UTF-16 BE", encoding: .utf16BigEndian, bom: true)

    static let all: [TextEncodingChoice] = [utf8, utf8BOM, cp1251, koi8r, cp866, cp1252, utf16LE, utf16BE]
}

enum TextCodec {
    enum CodecError: LocalizedError {
        case cannotEncode(String)
        var errorDescription: String? {
            if case .cannotEncode(let n) = self { return "Текст не представим в \(n) — выбери UTF-8" }
            return nil
        }
    }

    private static let bomUTF8: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let bomLE: [UInt8] = [0xFF, 0xFE]
    private static let bomBE: [UInt8] = [0xFE, 0xFF]

    /// BOM → строгий UTF-8 → Windows-1251 (типичный «не UTF-8» у нас).
    static func decode(_ data: Data) -> (text: String, encoding: TextEncodingChoice) {
        let b = [UInt8](data.prefix(3))
        if b.count >= 3, Array(b[0..<3]) == bomUTF8 {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8BOM)
        }
        if b.count >= 2, Array(b[0..<2]) == bomLE {
            return (String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "", .utf16LE)
        }
        if b.count >= 2, Array(b[0..<2]) == bomBE {
            return (String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "", .utf16BE)
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        return (String(data: data, encoding: .windowsCP1251) ?? String(decoding: data, as: UTF8.self), .cp1251)
    }

    /// Прочитать байты заново в выбранной кодировке (BOM срезается).
    static func decode(_ data: Data, as e: TextEncodingChoice) -> String? {
        var body = data
        let b = [UInt8](data.prefix(3))
        if e.encoding == .utf8, b.count >= 3, Array(b[0..<3]) == bomUTF8 { body = data.dropFirst(3) }
        else if (e.encoding == .utf16LittleEndian || e.encoding == .utf16BigEndian), b.count >= 2,
                Array(b[0..<2]) == bomLE || Array(b[0..<2]) == bomBE { body = data.dropFirst(2) }
        return String(data: Data(body), encoding: e.encoding)
    }

    static func encode(_ text: String, as e: TextEncodingChoice) throws -> Data {
        guard let body = text.data(using: e.encoding, allowLossyConversion: false) else {
            throw CodecError.cannotEncode(e.name)
        }
        guard e.bom else { return body }
        switch e.encoding {
        case .utf8: return Data(bomUTF8) + body
        case .utf16LittleEndian: return Data(bomLE) + body
        case .utf16BigEndian: return Data(bomBE) + body
        default: return body
        }
    }

    // MARK: Концы строк

    enum EOL: String, CaseIterable, Identifiable {
        case lf = "\n", crlf = "\r\n", cr = "\r"
        var id: String { rawValue }
        var name: String {
            switch self {
            case .lf: return "LF"
            case .crlf: return "CRLF"
            case .cr: return "CR"
            }
        }
        var title: String {
            switch self {
            case .lf: return "LF (Unix, macOS)"
            case .crlf: return "CRLF (Windows)"
            case .cr: return "CR (старый Mac)"
            }
        }
    }

    static func detectEOL(_ text: String) -> EOL {
        var crlf = 0, lf = 0, cr = 0
        var prevCR = false
        for u in text.utf16 {
            if u == 13 {
                if prevCR { cr += 1 }
                prevCR = true
            } else if u == 10 {
                if prevCR { crlf += 1; prevCR = false } else { lf += 1 }
            } else {
                if prevCR { cr += 1; prevCR = false }
            }
        }
        if prevCR { cr += 1 }
        if crlf == 0 && lf == 0 && cr == 0 { return .lf }
        if crlf >= lf && crlf >= cr { return .crlf }
        return lf >= cr ? .lf : .cr
    }

    static func normalizeEOL(_ text: String, to eol: EOL) -> String {
        text.replacingOccurrences(of: "\r\n|\r|\n", with: eol.rawValue, options: .regularExpression)
    }

    // MARK: Инструменты (Base64/URL/JSON/хеши)

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func toBase64(_ s: String) throws -> String { Data(s.utf8).base64EncodedString() }

    static func fromBase64(_ s: String) throws -> String {
        let cleaned = s.components(separatedBy: .whitespacesAndNewlines).joined()
        var padded = cleaned.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let d = Data(base64Encoded: padded) else { throw ToolError(message: "не Base64") }
        guard let t = String(data: d, encoding: .utf8) else { throw ToolError(message: "раскодировано, но это не UTF-8 текст") }
        return t
    }

    static func urlEncode(_ s: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let r = s.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ToolError(message: "не кодируется") }
        return r
    }

    static func urlDecode(_ s: String) throws -> String {
        guard let r = s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
            throw ToolError(message: "битая %-последовательность")
        }
        return r
    }

    static func jsonPretty(_ s: String) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: d, as: UTF8.self)
    }

    static func jsonMinify(_ s: String) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .fragmentsAllowed])
        return String(decoding: d, as: UTF8.self)
    }

    static let hashNames = ["MD5", "SHA-1", "SHA-256", "SHA-512"]

    static func hash(_ s: String, _ alg: String) -> String {
        let d = Data(s.utf8)
        let bytes: [UInt8]
        switch alg {
        case "MD5": bytes = Array(Insecure.MD5.hash(data: d))
        case "SHA-1": bytes = Array(Insecure.SHA1.hash(data: d))
        case "SHA-512": bytes = Array(SHA512.hash(data: d))
        default: bytes = Array(SHA256.hash(data: d))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Строчные операции (чистые функции над текстом)

enum LineOps {
    /// Диапазон целых строк, задетых выделением (с переводом строки в конце,
    /// если он есть). Выделение, кончающееся ровно в начале строки (протянул
    /// мышью до следующей строки), её не захватывает.
    static func lineRange(_ text: NSString, _ sel: NSRange) -> NSRange {
        let loc = min(sel.location, text.length)
        var len = min(sel.length, text.length - loc)
        if len > 0, text.character(at: loc + len - 1) == 10 { len -= 1 }
        return text.lineRange(for: NSRange(location: loc, length: len))
    }

    /// Блок строк → строки без переводов + был ли перевод в конце + EOL блока.
    static func split(_ block: String) -> (lines: [String], trailingNewline: Bool, eol: String) {
        let ns = block as NSString
        let eol: String
        if ns.range(of: "\r\n").location != NSNotFound { eol = "\r\n" }
        else if ns.range(of: "\n").location != NSNotFound { eol = "\n" }
        else if ns.range(of: "\r").location != NSNotFound { eol = "\r" }
        else { eol = "\n" }
        let eolLen = (eol as NSString).length
        let trailing = ns.length >= eolLen && ns.substring(from: ns.length - eolLen) == eol
        let body = trailing ? ns.substring(to: ns.length - eolLen) : block
        return (body.components(separatedBy: eol), trailing, eol)
    }

    static func join(_ lines: [String], trailing: Bool, eol: String) -> String {
        lines.joined(separator: eol) + (trailing ? eol : "")
    }
}

// MARK: - Сравнение (построчный diff на CollectionDifference)

struct DiffLine: Identifiable {
    enum Kind { case same, removed, added }
    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

enum LineDiff {
    static func compute(old: String, new: String) -> [DiffLine] {
        let a = TextCodec.normalizeEOL(old, to: .lf).components(separatedBy: "\n")
        let b = TextCodec.normalizeEOL(new, to: .lf).components(separatedBy: "\n")
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0, n = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                out.append(DiffLine(id: n, kind: .removed, oldNumber: i + 1, newNumber: nil, text: a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                out.append(DiffLine(id: n, kind: .added, oldNumber: nil, newNumber: j + 1, text: b[j])); j += 1
            } else if i < a.count, j < b.count {
                out.append(DiffLine(id: n, kind: .same, oldNumber: i + 1, newNumber: j + 1, text: a[i])); i += 1; j += 1
            } else if i < a.count {
                out.append(DiffLine(id: n, kind: .removed, oldNumber: i + 1, newNumber: nil, text: a[i])); i += 1
            } else {
                out.append(DiffLine(id: n, kind: .added, oldNumber: nil, newNumber: j + 1, text: b[j])); j += 1
            }
            n += 1
        }
        return out
    }
}
