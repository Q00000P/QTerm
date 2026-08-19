import SwiftUI
import AppKit
import SessionVaultKit

/// Добавление/правка сессии. Ключ — из хранилища вейлта (приоритет) или
/// файлом с диска. Passphrase привязывается к ключу, не к сессии.
struct EditSessionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let existing: Session?
    let onSave: (Session) -> Void

    private enum KeySource: Hashable {
        case vault(UUID)
        case file
    }

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthMethod
    @State private var keySource: KeySource
    @State private var privateKeyPath: String
    @State private var secret: String = ""       // пароль или passphrase
    @State private var secretTouched = false
    @State private var termPath: String
    @State private var sftpPath: String
    @State private var showKeys = false

    init(session: Session?, onSave: @escaping (Session) -> Void) {
        self.existing = session
        self.onSave = onSave
        _name = State(initialValue: session?.name ?? "")
        _host = State(initialValue: session?.host ?? "")
        _port = State(initialValue: session.map { String($0.port) } ?? "22")
        _username = State(initialValue: session?.username ?? "root")
        _authMethod = State(initialValue: session?.authMethod ?? .privateKey)
        if let keyID = session?.keyID {
            _keySource = State(initialValue: .vault(keyID))
        } else {
            _keySource = State(initialValue: .file)
        }
        _privateKeyPath = State(initialValue: session?.privateKeyPath ?? "")
        _termPath = State(initialValue: session?.extra["termPath"] ?? "")
        _sftpPath = State(initialValue: session?.extra["sftpPath"] ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Новая сессия" : "Изменить сессию")
                .font(.headline)

            Form {
                TextField("Название", text: $name, prompt: Text("vps-nl"))
                TextField("Хост", text: $host, prompt: Text("1.2.3.4 или host.example"))
                TextField("Порт", text: $port)
                TextField("Пользователь", text: $username)

                Picker("Аутентификация", selection: $authMethod) {
                    Text("Ключ").tag(AuthMethod.privateKey)
                    Text("Пароль").tag(AuthMethod.password)
                }
                .pickerStyle(.segmented)

                if authMethod == .privateKey {
                    HStack {
                        Picker("Ключ", selection: $keySource) {
                            ForEach(state.sshKeys) { key in
                                Text("🔑 \(key.name)").tag(KeySource.vault(key.id))
                            }
                            Text("Файл на диске…").tag(KeySource.file)
                        }
                        Button("Ключи…") { showKeys = true }
                            .help("Хранилище ключей: отпечатки, публичные части, импорт")
                    }

                    if case .file = keySource {
                        HStack {
                            TextField("Путь к ключу", text: $privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
                            Button("…") { pickKeyPath() }
                            Button("В хранилище") { importToVault() }
                                .help("Скопировать содержимое ключа в вейлт — файл станет не нужен")
                        }
                    }

                    SecureField("Passphrase", text: $secret, prompt: Text(passphrasePrompt))
                        .onChange(of: secret) { _, _ in secretTouched = true }
                } else {
                    SecureField("Пароль", text: $secret)
                        .onChange(of: secret) { _, _ in secretTouched = true }
                }

                if let hint = existing?.extra["mobaKeyPath"] {
                    Text("Из мобы: \(hint)")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()

                TextField("Каталог терминала", text: $termPath, prompt: Text("/opt/etc"))
                TextField("Путь проводника", text: $sftpPath, prompt: Text("/opt/etc/mihomo"))
                Text("Стартовые пути на сервере (вводятся руками): терминал делает cd после входа, проводник открывается в каталоге. Пусто — домашний / /root.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty ||
                              username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 540)
        .sheet(isPresented: $showKeys) {
            KeyManagerView()
                .environmentObject(state)
        }
    }

    private var passphrasePrompt: String {
        if case .vault(let id) = keySource,
           state.secrets.passphrase(forKeyID: id) != nil {
            return "уже сохранена — можно не вводить"
        }
        return "если есть"
    }

    private func pickKeyPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.message = "Файл приватного ключа — из любой папки (Документы, Загрузки…)"
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }

    /// «В хранилище»: читаем файл по указанному пути и кладём в вейлт.
    private func importToVault() {
        let expanded = (privateKeyPath as NSString).expandingTildeInPath
        guard !privateKeyPath.isEmpty,
              let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            // Путь пуст/не читается — откроем панель выбора.
            if let key = state.importKeyFile() {
                keySource = .vault(key.id)
            }
            return
        }
        guard content.contains("BEGIN OPENSSH PRIVATE KEY") else { return }
        if let existingKey = state.sshKeys.first(where: { $0.privateKey == content }) {
            keySource = .vault(existingKey.id)
            return
        }
        let key = SSHKey(name: (expanded as NSString).lastPathComponent, privateKey: content)
        state.sshKeys.append(key)
        state.persistKeysPublic()
        keySource = .vault(key.id)
    }

    private func save() {
        let host = self.host.trimmingCharacters(in: .whitespaces)
        let name = self.name.trimmingCharacters(in: .whitespaces)
        let username = self.username.trimmingCharacters(in: .whitespaces)
        let port = self.port.trimmingCharacters(in: .whitespaces)

        var keyID: UUID? = nil
        var keyPath: String? = nil
        if authMethod == .privateKey {
            switch keySource {
            case .vault(let id): keyID = id
            case .file: keyPath = privateKeyPath.isEmpty ? nil : privateKeyPath
            }
        }

        // Стартовые пути — в extra; остальные ключи (mobaKeyPath, hostkey…) не трогаем.
        var extra = existing?.extra ?? [:]
        let term = termPath.trimmingCharacters(in: .whitespaces)
        let sftp = sftpPath.trimmingCharacters(in: .whitespaces)
        extra["termPath"] = term.isEmpty ? nil : term
        extra["sftpPath"] = sftp.isEmpty ? nil : sftp

        let session = Session(
            id: existing?.id ?? UUID(),
            name: name.isEmpty ? host : name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            keyID: keyID,
            privateKeyPath: keyPath,
            extra: extra
        )

        if secretTouched && !secret.isEmpty {
            if authMethod == .password {
                try? state.secrets.set(secret, for: session.id, kind: .password)
            } else {
                // Passphrase — к ключу, не к сессии.
                switch keySource {
                case .vault(let id):
                    try? state.secrets.setPassphrase(secret, forKeyID: id)
                case .file:
                    if let keyPath {
                        try? state.secrets.setPassphrase(secret, forPath: (keyPath as NSString).expandingTildeInPath)
                    }
                }
            }
        }

        onSave(session)
        dismiss()
    }
}
