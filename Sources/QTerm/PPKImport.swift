import Foundation
import CryptoKit
import CommonCrypto
import Argon2Swift

/// Конвертер PuTTY .ppk → OpenSSH. Нативный: без puttygen и прочих внешних
/// утилит — «открыл и работает».
///
/// Поддержано: PPK3 (Argon2id/i/d + aes256-cbc) и PPK2 (SHA-1 KDF),
/// типы ключей ssh-rsa и ssh-ed25519, шифрованные и нет.
///
/// Результат — OpenSSH-ключ БЕЗ passphrase: он ложится внутрь вейлта, который
/// зашифрован AES-256-GCM под Secure Enclave. После импорта ноды с этим ключом
/// подключаются вообще без вопросов.
public enum PPKConverter {

    public struct Result {
        public let openSSH: String
        public let keyType: String
        public let comment: String
        /// Пошаговая диагностика — показываем, если что-то пошло не так.
        public let log: [String]
    }

    public enum PPKError: LocalizedError {
        case notPPK
        case unsupportedVersion(Int)
        case unsupportedKeyType(String)
        case unsupportedEncryption(String)
        case missingField(String)
        case badBase64(String)
        case macMismatch(log: [String])
        case decryptFailed
        case argon2(String)
        case malformedBlob(String)

        public var errorDescription: String? {
            switch self {
            case .notPPK: return "Это не .ppk файл PuTTY"
            case .unsupportedVersion(let v): return "PPK версии \(v) не поддерживается"
            case .unsupportedKeyType(let t): return "Тип ключа \(t) пока не поддерживается (есть RSA и ed25519)"
            case .unsupportedEncryption(let e): return "Шифрование \(e) не поддерживается"
            case .missingField(let f): return "В файле нет поля \(f)"
            case .badBase64(let w): return "Битый base64 в секции \(w)"
            case .macMismatch(let log): return "Неверная passphrase (MAC не сошёлся)\n\n" + log.joined(separator: "\n")
            case .decryptFailed: return "Не удалось расшифровать приватную часть"
            case .argon2(let m): return "Argon2: \(m)"
            case .malformedBlob(let m): return "Структура ключа неожиданная: \(m)"
            }
        }
    }

    public static func isPPK(_ text: String) -> Bool {
        text.hasPrefix("PuTTY-User-Key-File-")
    }

    public static func convert(text: String, passphrase: String) throws -> Result {
        var log: [String] = []

        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        guard let first = lines.first, first.hasPrefix("PuTTY-User-Key-File-") else {
            throw PPKError.notPPK
        }

        let headParts = first.components(separatedBy: ":")
        guard headParts.count >= 2,
              let versionChar = headParts[0].split(separator: "-").last,
              let version = Int(versionChar) else {
            throw PPKError.notPPK
        }
        let algorithm = headParts[1].trimmingCharacters(in: .whitespaces)
        log.append("версия PPK: \(version), тип: \(algorithm)")
        guard version == 2 || version == 3 else { throw PPKError.unsupportedVersion(version) }

        var headers: [String: String] = [:]
        var publicB64 = "", privateB64 = "", privateMAC = ""
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }
            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if key == "Public-Lines" || key == "Private-Lines" {
                let count = Int(value) ?? 0
                var blob = ""
                var j = 1
                while j <= count, i + j < lines.count {
                    blob += lines[i + j]
                    j += 1
                }
                if key == "Public-Lines" { publicB64 = blob } else { privateB64 = blob }
                i += count + 1
                continue
            }
            if key == "Private-MAC" {
                privateMAC = value.lowercased()
            } else {
                headers[key] = value
            }
            i += 1
        }

        let encryption = headers["Encryption"] ?? "none"
        let comment = headers["Comment"] ?? ""
        log.append("шифрование: \(encryption), комментарий: \(comment)")

        guard let pubBlob = Data(base64Encoded: publicB64) else { throw PPKError.badBase64("Public-Lines") }
        guard let privRaw = Data(base64Encoded: privateB64) else { throw PPKError.badBase64("Private-Lines") }
        log.append("public \(pubBlob.count) байт, private \(privRaw.count) байт")

        let privPlain: Data
        let macKey: Data

        switch encryption {
        case "none":
            privPlain = privRaw
            macKey = version == 3 ? Data() : sha1(Data("putty-private-key-file-mac-key".utf8))
            log.append("ключ не зашифрован")

        case "aes256-cbc":
            if version == 3 {
                guard let kdf = headers["Key-Derivation"],
                      let memStr = headers["Argon2-Memory"], let mem = Int(memStr),
                      let passStr = headers["Argon2-Passes"], let passes = Int(passStr),
                      let parStr = headers["Argon2-Parallelism"], let par = Int(parStr),
                      let saltHex = headers["Argon2-Salt"], let salt = hexToData(saltHex) else {
                    throw PPKError.missingField("Argon2-* / Key-Derivation")
                }
                log.append("KDF \(kdf): память \(mem)KiB, проходов \(passes), параллелизм \(par), соль \(salt.count)Б")

                let type: Argon2Type
                switch kdf.lowercased() {
                case "argon2id": type = .id
                case "argon2i": type = .i
                case "argon2d": type = .d
                default: throw PPKError.argon2("неизвестный вариант \(kdf)")
                }

                let derived: Data
                do {
                    let result = try Argon2Swift.hashPasswordBytes(
                        password: Data(passphrase.utf8),
                        salt: Salt(bytes: salt),
                        iterations: passes,
                        memory: mem,
                        parallelism: par,
                        length: 80,
                        type: type
                    )
                    derived = result.hashData()
                } catch {
                    throw PPKError.argon2(String(describing: error))
                }
                guard derived.count == 80 else { throw PPKError.argon2("получено \(derived.count) байт вместо 80") }

                let aesKey = Data(derived.prefix(32))
                let iv = Data(derived.dropFirst(32).prefix(16))
                macKey = Data(derived.dropFirst(48))
                log.append("Argon2 ок")

                privPlain = try aesCBCDecrypt(data: privRaw, key: aesKey, iv: iv)
                let head = privPlain.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                log.append("AES: \(privPlain.count) байт, первые 8: \(head)")
                log.append("  (если ключ верный, первые 4 байта = длина mpint d, обычно 00 00 01 0x)")
                log.append("Argon2 отпечаток: key \(aesKey.prefix(4).map { String(format: "%02x", $0) }.joined()), iv \(iv.prefix(4).map { String(format: "%02x", $0) }.joined()), mac \(macKey.prefix(4).map { String(format: "%02x", $0) }.joined())")
            } else {
                var keyMaterial = Data()
                for counter in 0..<2 {
                    var input = Data([0, 0, 0, UInt8(counter)])
                    input.append(Data(passphrase.utf8))
                    keyMaterial.append(sha1(input))
                }
                let aesKey = Data(keyMaterial.prefix(32))
                let iv = Data(repeating: 0, count: 16)
                macKey = sha1(Data("putty-private-key-file-mac-key".utf8) + Data(passphrase.utf8))
                privPlain = try aesCBCDecrypt(data: privRaw, key: aesKey, iv: iv)
                log.append("PPK2 SHA-1 KDF применён")
            }

        default:
            throw PPKError.unsupportedEncryption(encryption)
        }

        // PPK3 считает MAC по ЗАШИФРОВАННОМУ приватному блобу, PPK2 — по
        // расшифрованному. Пробуем оба и логируем, какой сошёлся.
        func macHex(over privatePart: Data) -> String {
            var macData = Data()
            macData.append(sshString(Data(algorithm.utf8)))
            macData.append(sshString(Data(encryption.utf8)))
            macData.append(sshString(Data(comment.utf8)))
            macData.append(sshString(pubBlob))
            macData.append(sshString(privatePart))
            if version == 3 {
                let code = HMAC<SHA256>.authenticationCode(for: macData, using: SymmetricKey(data: macKey))
                return Data(code).map { String(format: "%02x", $0) }.joined()
            } else {
                let code = HMAC<Insecure.SHA1>.authenticationCode(for: macData, using: SymmetricKey(data: macKey))
                return Data(code).map { String(format: "%02x", $0) }.joined()
            }
        }

        let macPlain = macHex(over: privPlain)
        let macCipher = macHex(over: privRaw)
        if macPlain == privateMAC {
            log.append("MAC сошёлся (по расшифрованному блобу)")
        } else if macCipher == privateMAC {
            log.append("MAC сошёлся (по зашифрованному блобу)")
        } else {
            log.append("MAC: ждали \(privateMAC.prefix(16))…")
            log.append("  по plain:  \(macPlain.prefix(16))…")
            log.append("  по cipher: \(macCipher.prefix(16))…")
            throw PPKError.macMismatch(log: log)
        }

        let openssh: String
        switch algorithm {
        case "ssh-rsa":
            openssh = try packRSA(pubBlob: pubBlob, privPlain: privPlain, comment: comment, log: &log)
        case "ssh-ed25519":
            openssh = try packEd25519(pubBlob: pubBlob, privPlain: privPlain, comment: comment, log: &log)
        default:
            throw PPKError.unsupportedKeyType(algorithm)
        }

        return Result(openSSH: openssh, keyType: algorithm, comment: comment, log: log)
    }

    // MARK: - Перепаковка в OpenSSH

    private static func packRSA(pubBlob: Data, privPlain: Data, comment: String, log: inout [String]) throws -> String {
        var pub = Reader(pubBlob)
        guard let typeData = pub.readString(),
              String(data: typeData, encoding: .utf8) == "ssh-rsa",
              let e = pub.readString(), let n = pub.readString() else {
            throw PPKError.malformedBlob("public RSA")
        }
        var priv = Reader(privPlain)
        guard let d = priv.readString(), let p = priv.readString(),
              let q = priv.readString(), let iqmp = priv.readString() else {
            throw PPKError.malformedBlob("private RSA")
        }
        log.append("RSA: n=\(n.count)Б e=\(e.count)Б d=\(d.count)Б p=\(p.count)Б q=\(q.count)Б")

        var publicKeySection = Data()
        publicKeySection.append(sshString(Data("ssh-rsa".utf8)))
        publicKeySection.append(sshString(e))
        publicKeySection.append(sshString(n))

        var inner = Data()
        let check = UInt32.random(in: 0...UInt32.max)
        inner.append(be32(check)); inner.append(be32(check))
        inner.append(sshString(Data("ssh-rsa".utf8)))
        inner.append(sshString(n))
        inner.append(sshString(e))
        inner.append(sshString(d))
        inner.append(sshString(iqmp))
        inner.append(sshString(p))
        inner.append(sshString(q))
        inner.append(sshString(Data(comment.utf8)))
        inner = padTo8(inner)

        return armor(openSSHContainer(publicKeySection: publicKeySection, inner: inner))
    }

    private static func packEd25519(pubBlob: Data, privPlain: Data, comment: String, log: inout [String]) throws -> String {
        var pub = Reader(pubBlob)
        guard let typeData = pub.readString(),
              String(data: typeData, encoding: .utf8) == "ssh-ed25519",
              let pubKey = pub.readString() else {
            throw PPKError.malformedBlob("public ed25519")
        }
        var priv = Reader(privPlain)
        guard var privKey = priv.readString() else { throw PPKError.malformedBlob("private ed25519") }
        if privKey.count == 33, privKey.first == 0 { privKey = Data(privKey.dropFirst()) }
        while privKey.count < 32 { privKey = Data([0]) + privKey }
        log.append("ed25519: pub=\(pubKey.count)Б priv=\(privKey.count)Б")

        var publicKeySection = Data()
        publicKeySection.append(sshString(Data("ssh-ed25519".utf8)))
        publicKeySection.append(sshString(pubKey))

        var inner = Data()
        let check = UInt32.random(in: 0...UInt32.max)
        inner.append(be32(check)); inner.append(be32(check))
        inner.append(sshString(Data("ssh-ed25519".utf8)))
        inner.append(sshString(pubKey))
        inner.append(sshString(privKey + pubKey))
        inner.append(sshString(Data(comment.utf8)))
        inner = padTo8(inner)

        return armor(openSSHContainer(publicKeySection: publicKeySection, inner: inner))
    }

    private static func openSSHContainer(publicKeySection: Data, inner: Data) -> Data {
        var out = Data("openssh-key-v1".utf8)
        out.append(0)
        out.append(sshString(Data("none".utf8)))
        out.append(sshString(Data("none".utf8)))
        out.append(sshString(Data()))
        out.append(be32(1))
        out.append(sshString(publicKeySection))
        out.append(sshString(inner))
        return out
    }

    private static func armor(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        var lines: [String] = []
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[idx..<end]))
            idx = end
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n"
            + lines.joined(separator: "\n")
            + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    // MARK: - Мелочи

    private struct Reader {
        let data: Data
        var offset: Int = 0
        init(_ d: Data) { data = d }

        mutating func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let bytes = data.subdata(in: offset ..< offset + 4)
            offset += 4
            return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        mutating func readString() -> Data? {
            guard let len = readUInt32(), offset + Int(len) <= data.count else { return nil }
            let out = data.subdata(in: offset ..< offset + Int(len))
            offset += Int(len)
            return out
        }
    }

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
    }

    private static func sshString(_ d: Data) -> Data { be32(UInt32(d.count)) + d }

    private static func padTo8(_ d: Data) -> Data {
        var out = d
        var pad: UInt8 = 1
        while out.count % 8 != 0 { out.append(pad); pad += 1 }
        return out
    }

    private static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }

    private static func hexToData(_ hex: String) -> Data? {
        var out = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex, let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) {
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    private static func aesCBCDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr -> Int32 in
            data.withUnsafeBytes { dataPtr -> Int32 in
                key.withUnsafeBytes { keyPtr -> Int32 in
                    iv.withUnsafeBytes { ivPtr -> Int32 in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // без паддинга — PuTTY добивает сам
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess) else { throw PPKError.decryptFailed }
        return Data(out.prefix(moved))
    }
}
