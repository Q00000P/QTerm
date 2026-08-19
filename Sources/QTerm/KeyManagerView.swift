import SwiftUI
import AppKit
import CryptoKit
import SessionVaultKit

// MARK: - Извлечение публичной части из OpenSSH-ключа

/// Формат openssh-key-v1 содержит публичный блоб ДО приватной секции —
/// публичную часть достаём парсингом контейнера, без криптографии.
enum KeyTools {

    struct PublicKey {
        let type: String   // ssh-ed25519 / ssh-rsa / …
        let blob: Data     // wire-формат для authorized_keys
        /// Приватная секция зашифрована (ciphername != none). Ключи из нашего
        /// ppk-конвертера всегда расшифрованы — passphrase им не нужна.
        let isEncrypted: Bool
    }

    static func publicKey(fromOpenSSH text: String) -> PublicKey? {
        guard let begin = text.range(of: "-----BEGIN OPENSSH PRIVATE KEY-----"),
              let end = text.range(of: "-----END OPENSSH PRIVATE KEY-----"),
              begin.upperBound <= end.lowerBound else { return nil }
        let b64 = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(b64)) else { return nil }

        var idx = 0
        func readBytes(_ n: Int) -> Data? {
            guard n >= 0, idx + n <= data.count else { return nil }
            defer { idx += n }
            return data.subdata(in: idx ..< idx + n)
        }
        func readU32() -> Int? {
            guard let d = readBytes(4) else { return nil }
            let b = [UInt8](d)
            return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
        }
        func readString() -> Data? {
            guard let n = readU32() else { return nil }
            return readBytes(n)
        }

        let magic = Data("openssh-key-v1\0".utf8)
        guard let m = readBytes(magic.count), m == magic else { return nil }
        guard let cipher = readString(),      // ciphername
              readString() != nil,            // kdfname
              readString() != nil,            // kdfoptions
              let nkeys = readU32(), nkeys >= 1,
              let blob = readString(), blob.count > 4 else { return nil }
        let isEncrypted = String(data: cipher, encoding: .utf8) != "none"

        // Тип — первая строка внутри блоба.
        let b = [UInt8](blob)
        let tlen = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
        guard tlen > 0, 4 + tlen <= blob.count,
              let type = String(data: blob.subdata(in: 4 ..< 4 + tlen), encoding: .utf8)
        else { return nil }
        return PublicKey(type: type, blob: blob, isEncrypted: isEncrypted)
    }

    static func fingerprint(_ blob: Data) -> String {
        let hash = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + hash.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Готовая строка для authorized_keys.
    static func authorizedKeysLine(_ pk: PublicKey, comment: String) -> String {
        "\(pk.type) \(pk.blob.base64EncodedString()) \(comment)"
    }
}

// MARK: - Экран ключей

struct KeyManagerView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var renameKey: SSHKey?
    @State private var renameText = ""
    @State private var deleteCandidate: SSHKey?
    @State private var flashText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ключи хранилища").font(.headline)
                Spacer()
                if let flash = flashText {
                    Text(flash).font(.caption).foregroundStyle(.secondary)
                }
                Button("Импортировать…") {
                    _ = state.importKeyFile()
                }
            }

            if state.sshKeys.isEmpty {
                ContentUnavailableView(
                    "Хранилище пусто",
                    systemImage: "key",
                    description: Text("Импортируй ключ (OpenSSH или .ppk) — файл после импорта не нужен")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(state.sshKeys) { key in
                    keyRow(key)
                }
                .listStyle(.inset)
            }

            HStack {
                Text("Публичная часть копируется строкой для authorized_keys")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
        .alert("Переименовать ключ", isPresented: Binding(
            get: { renameKey != nil },
            set: { if !$0 { renameKey = nil } }
        )) {
            TextField("Имя", text: $renameText)
            Button("Сохранить") {
                if let key = renameKey, !renameText.isEmpty {
                    state.renameKey(key, to: renameText)
                }
                renameKey = nil
            }
            Button("Отмена", role: .cancel) { renameKey = nil }
        }
        .alert("Удалить ключ?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let key = deleteCandidate {
                    state.deleteKeyAndDetach(key)
                }
                deleteCandidate = nil
            }
            Button("Отмена", role: .cancel) { deleteCandidate = nil }
        } message: {
            if let key = deleteCandidate {
                let used = state.sessionsUsing(key)
                Text(used.isEmpty
                     ? "«\(key.name)» не используется нодами. Удаление необратимо."
                     : "«\(key.name)» используется \(used.count) нодами (\(used.prefix(5).map(\.name).joined(separator: ", "))\(used.count > 5 ? "…" : "")). Они останутся без ключа — назначь другой через Изменить или «Назначить ключ нодам без ключа».")
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ key: SSHKey) -> some View {
        let pk = KeyTools.publicKey(fromOpenSSH: key.privateKey)
        let usedCount = state.sessionsUsing(key).count
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.name).fontWeight(.medium)
                    if let pk {
                        Text(pk.type)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.gray.opacity(0.2)))
                    }
                    if usedCount > 0 {
                        Text("нод: \(usedCount)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if pk?.isEncrypted == true {
                        Image(systemName: state.secrets.passphrase(forKeyID: key.id) != nil
                              ? "lock.fill" : "lock.open")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(state.secrets.passphrase(forKeyID: key.id) != nil
                                  ? "Ключ зашифрован, passphrase сохранена"
                                  : "Ключ зашифрован, passphrase НЕ сохранена — спросится при коннекте")
                    }
                }
                Text(pk.map { KeyTools.fingerprint($0.blob) } ?? "не удалось разобрать ключ")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(pk == nil ? .red : .secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                copyPublic(key)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Скопировать публичную часть (authorized_keys)")
                .disabled(pk == nil)
            if pk?.isEncrypted == true {
                Button {
                    setPassphrase(key)
                } label: { Image(systemName: "lock") }
                    .buttonStyle(.borderless)
                    .help("Сохранить passphrase — ноды перестанут спрашивать её при коннекте")
            }
            Button {
                renameText = key.name
                renameKey = key
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Переименовать")
            Button {
                deleteCandidate = key
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Удалить из хранилища")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Скопировать публичную часть") { copyPublic(key) }
            Button("Скопировать отпечаток") {
                if let pk = KeyTools.publicKey(fromOpenSSH: key.privateKey) {
                    copy(KeyTools.fingerprint(pk.blob))
                }
            }
            Button("Переименовать…") {
                renameText = key.name
                renameKey = key
            }
            if KeyTools.publicKey(fromOpenSSH: key.privateKey)?.isEncrypted == true {
                Button("Задать passphrase…") { setPassphrase(key) }
            }
            Divider()
            Button("Удалить", role: .destructive) { deleteCandidate = key }
        }
    }

    private func copyPublic(_ key: SSHKey) {
        guard let pk = KeyTools.publicKey(fromOpenSSH: key.privateKey) else { return }
        copy(KeyTools.authorizedKeysLine(pk, comment: key.name))
        flash("Публичная часть «\(key.name)» скопирована")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func setPassphrase(_ key: SSHKey) {
        guard let phrase = Dialogs.askPassword(
            title: "Passphrase ключа «\(key.name)»", confirm: false
        ) else { return }
        do {
            try state.secrets.setPassphrase(phrase, forKeyID: key.id)
            flash("Passphrase «\(key.name)» сохранена")
        } catch {
            Dialogs.error("Не удалось сохранить passphrase: \(error.localizedDescription)")
        }
    }

    private func flash(_ text: String) {
        flashText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if flashText == text { flashText = nil }
        }
    }
}
