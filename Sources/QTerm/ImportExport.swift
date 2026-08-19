import Foundation
import AppKit
import CryptoKit
import CommonCrypto
import SessionVaultKit

// MARK: - Импорт из MobaXterm (.mobaconf / MobaXterm.ini)

enum MobaImport {

    struct Imported {
        var name: String
        var host: String
        var port: Int
        var username: String
        /// Путь ключа как записан в мобе (_MyDocuments_\XXX.ppk) — подсказка.
        var mobaKeyPath: String?
    }

    /// Парсит секции [Bookmarks*]: строки вида
    ///   имя=#109#0%хост%порт%юзер%…%путь_ключа%…#MobaFont…
    /// Берём только SSH-записи (#109#). Хосты тримятся — в реальных экспортах
    /// встречаются хвостовые пробелы.
    static func parse(_ text: String) -> [Imported] {
        var result: [Imported] = []
        var inBookmarks = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("[") {
                inBookmarks = line.hasPrefix("[Bookmarks")
                continue
            }
            guard inBookmarks, !line.isEmpty else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if name == "SubRep" || name == "ImgNum" { continue }

            var value = String(line[line.index(after: eq)...])
            guard value.hasPrefix("#109#") else { continue } // только SSH

            // Отрезаем хвост оформления (#MobaFont…), берём поля после первого %
            if let fontRange = value.range(of: "#MobaFont") {
                value = String(value[..<fontRange.lowerBound])
            }
            guard let firstPercent = value.firstIndex(of: "%") else { continue }
            let fields = value[value.index(after: firstPercent)...]
                .components(separatedBy: "%")

            guard fields.count > 2 else { continue }
            let host = fields[0].trimmingCharacters(in: .whitespaces)
            let port = Int(fields[1].trimmingCharacters(in: .whitespaces)) ?? 22
            var user = fields[2].trimmingCharacters(in: .whitespaces)
            if user.isEmpty { user = "root" }

            var keyPath: String? = nil
            if fields.count > 13 {
                let kp = fields[13].trimmingCharacters(in: .whitespaces)
                if !kp.isEmpty { keyPath = kp }
            }

            guard !host.isEmpty else { continue }
            result.append(Imported(name: name, host: host, port: port, username: user, mobaKeyPath: keyPath))
        }
        return result
    }

    /// Пытаемся угадать сконвертированный ключ: _MyDocuments_\QXpriv.ppk →
    /// ~/.ssh/QXpriv_std / ~/.ssh/QXpriv (если файл существует).
    static func guessLocalKey(for mobaPath: String?) -> String? {
        guard let mobaPath else { return nil }
        let base = (mobaPath.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let fm = FileManager.default
        let sshDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        for candidate in ["\(stem)_std", stem, stem.lowercased() + "_std", stem.lowercased()] {
            let url = sshDir.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) {
                return "~/.ssh/\(candidate)"
            }
        }
        return nil
    }

    // MARK: Экспорт в формат мобы

    /// Собирает секцию [Bookmarks] в формате мобы. Пути ключей уходят как есть
    /// (OpenSSH-пути; в мобе их надо будет заменить на .ppk руками).
    static func export(sessions: [Session]) -> String {
        var out = "[Bookmarks]\r\nSubRep=\r\nImgNum=42\r\n"
        for s in sessions {
            let key = s.privateKeyPath ?? ""
            let tail = "%%-1%0%0%0%%1080%%0%0%1%%0%%%%0%-1%-1%0#MobaFont%10%0%0%-1%15%236,236,236%30,30,30%180,180,192%0%-1%0%%xterm%-1%0%_Std_Colors_0_%80%24%0%1%-1%<none>%%0%0%-1%0%#0# #-1"
            out += "\(s.name)=#109#0%\(s.host)%\(s.port)%\(s.username)%%-1%-1%%%%%0%0%0%\(key)\(tail)\r\n"
        }
        return out
    }
}

// MARK: - Шифрованный файл вейлта (экспорт/импорт всего)

enum VaultFile {

    struct Payload: Codable {
        var formatVersion: Int = 1
        var exportedAt: Date = Date()
        var sessions: [Session]
        var snippets: [Snippet]
        var secrets: [String: String]
        var sshKeys: [SSHKey]? = nil
    }

    static let magic = Data("QTV1".utf8)

    enum FileError: LocalizedError {
        case badFormat, badPassword
        var errorDescription: String? {
            switch self {
            case .badFormat: return "Это не файл экспорта QTerm"
            case .badPassword: return "Неверный пароль или файл повреждён"
            }
        }
    }

    /// PBKDF2-HMAC-SHA256, 300k итераций → AES-256-GCM.
    /// Формат: "QTV1" + salt(16) + AES.GCM.combined.
    static func encrypt(_ payload: Payload, password: String) throws -> Data {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = derive(password: password, salt: salt)
        let json = try Self.encoder.encode(payload)
        let sealed = try AES.GCM.seal(json, using: key)
        return magic + salt + sealed.combined!
    }

    static func decrypt(_ data: Data, password: String) throws -> Payload {
        guard data.count > magic.count + 16, data.prefix(magic.count) == magic else {
            throw FileError.badFormat
        }
        let salt = data.subdata(in: magic.count ..< magic.count + 16)
        let body = data.subdata(in: magic.count + 16 ..< data.count)
        let key = derive(password: password, salt: salt)
        guard let box = try? AES.GCM.SealedBox(combined: body),
              let json = try? AES.GCM.open(box, using: key) else {
            throw FileError.badPassword
        }
        return try Self.decoder.decode(Payload.self, from: json)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private static func derive(password: String, salt: Data) -> SymmetricKey {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        _ = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.map { CChar(bitPattern: $0) }, pw.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    300_000,
                    outPtr.bindMemory(to: UInt8.self).baseAddress, 32
                )
            }
        }
        return SymmetricKey(data: out)
    }
}

// MARK: - Диалоги (AppKit, модальные — проще и надёжнее шитов)

enum Dialogs {

    static func askPassword(title: String, confirm: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = confirm
            ? "Пароль шифрует файл целиком (PBKDF2 + AES-256-GCM). Забудешь — содержимое не восстановить."
            : "Введи пароль, которым был зашифрован файл."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 28 : 0, width: 260, height: 24))
        field.placeholderString = "Пароль"
        var confirmField: NSSecureTextField?
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: confirm ? 56 : 24))
        container.addSubview(field)
        if confirm {
            let f2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            f2.placeholderString = "Повтори пароль"
            container.addSubview(f2)
            confirmField = f2
        }
        alert.accessoryView = container
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let pw = field.stringValue
        if let f2 = confirmField, f2.stringValue != pw {
            error("Пароли не совпадают")
            return nil
        }
        guard !pw.isEmpty else { return nil }
        return pw
    }

    /// Выпадающий список (имена ключей) → индекс выбранного или nil.
    static func chooseKey(names: [String]) -> Int? {
        let alert = NSAlert()
        alert.messageText = "Выбери ключ"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Отмена")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: names)
        alert.accessoryView = popup
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.indexOfSelectedItem
    }

    static func info(_ text: String) {
        let a = NSAlert(); a.messageText = text; a.runModal()
    }

    static func error(_ text: String) {
        let a = NSAlert(); a.alertStyle = .warning; a.messageText = text; a.runModal()
    }
}
