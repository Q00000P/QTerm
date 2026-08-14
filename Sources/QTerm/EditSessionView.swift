import SwiftUI
import SessionVaultKit

/// Добавление/правка сессии. Секрет (пароль/passphrase) вводится здесь,
/// но НЕ попадает в Session/вейлт — уходит напрямую в SecretStore (Keychain).
struct EditSessionView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let existing: Session?
    let onSave: (Session) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthMethod
    @State private var privateKeyPath: String
    @State private var secret: String = ""       // пароль или passphrase
    @State private var secretTouched = false     // менять Keychain только если правили

    init(session: Session?, onSave: @escaping (Session) -> Void) {
        self.existing = session
        self.onSave = onSave
        _name = State(initialValue: session?.name ?? "")
        _host = State(initialValue: session?.host ?? "")
        _port = State(initialValue: session.map { String($0.port) } ?? "22")
        _username = State(initialValue: session?.username ?? "root")
        _authMethod = State(initialValue: session?.authMethod ?? .privateKey)
        _privateKeyPath = State(initialValue: session?.privateKeyPath ?? "~/.ssh/id_ed25519")
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
                        TextField("Путь к ключу", text: $privateKeyPath)
                        Button("…") { pickKey() }
                    }
                    SecureField("Passphrase (если есть)", text: $secret)
                        .onChange(of: secret) { _, _ in secretTouched = true }
                } else {
                    SecureField("Пароль", text: $secret)
                        .onChange(of: secret) { _, _ in secretTouched = true }
                }
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || username.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }

    private func save() {
        let session = Session(
            id: existing?.id ?? UUID(),
            name: name.isEmpty ? host : name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            privateKeyPath: authMethod == .privateKey ? privateKeyPath : nil,
            extra: existing?.extra ?? [:]
        )

        if secretTouched && !secret.isEmpty {
            let kind: SecretKind = authMethod == .password ? .password : .privateKeyPassphrase
            try? state.secrets.set(secret, for: session.id, kind: kind)
        }

        onSave(session)
        dismiss()
    }
}
