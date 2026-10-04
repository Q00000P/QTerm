import SwiftUI
import AppKit
import SessionVaultKit

/// Ключ текстом из буфера → в вейлт (файл не нужен): имя + сам ключ.
/// PPK конвертируется в OpenSSH, одинаковый ключ второй раз не заводится. Уезжает синком.
struct KeyPasteSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let defaultName: String
    let onDone: (SSHKey?) -> Void

    @State private var name = ""
    @State private var text = ""
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ключ из буфера").font(.headline)
            TextField("Имя ключа", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Приватный ключ (OpenSSH или PuTTY .ppk) — текст целиком")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 200)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Вставить из буфера") { pasteFromClipboard() }
                Spacer()
                Button("Отмена") { onDone(nil); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить в вейлт") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 540)
        .onAppear {
            name = defaultName
            let clip = NSPasteboard.general.string(forType: .string)
            if AppState.looksLikeKey(clip) {
                text = clip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                status = "Ключ взят из буфера."
            } else {
                status = "В буфере ключа нет — вставь его в поле (⌘V)."
            }
        }
    }

    private func pasteFromClipboard() {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        text = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        status = AppState.looksLikeKey(clip) ? "Ключ взят из буфера." : "В буфере не ключ."
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { status = "Нужно имя ключа"; return }
        guard AppState.looksLikeKey(text) else {
            status = "✗ это не приватный ключ: нужен текст от «-----BEGIN … PRIVATE KEY-----» до «-----END …-----» (или .ppk)"
            return
        }
        guard let key = state.importKeyText(text, name: n) else { return }
        onDone(key)
        dismiss()
    }
}
