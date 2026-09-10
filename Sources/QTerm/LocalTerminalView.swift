import SwiftUI
import SwiftTerm

/// Локальный терминал мака: SwiftTerm сам форкает шелл (как Terminal.app).
/// Вся обвязка QTerm — подсказки, журнал (скоуп "mac"), сниппеты — работает
/// поверх, потому что живёт над терминалом, а не внутри SSH.

/// Сабкласс перехватывает юзер-ввод для CommandTracker до отправки в PTY.
final class TrackedLocalTerminalView: LocalProcessTerminalView {
    weak var appState: AppState?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let state = appState {
            if state.handleSuggestionKey(data) { return } // проглочено панелью
            state.cmdTracker.feed(data)
        }
        super.send(source: source, data: data)
    }

    /// Большая вставка (портянки со скриптами) одним куском может резаться
    /// частичной записью в PTY — незакрытый heredoc «висит» и ничего не
    /// исполняется. Шлём чанками с паузой, PTY успевает переваривать.
    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let bytes = Array(text.utf8)
        if bytes.count <= 4096 {
            super.paste(sender)
            return
        }
        appState?.cmdTracker.reset() // портянка — не команда для журнала
        let chunks = stride(from: 0, to: bytes.count, by: 4096).map {
            Array(bytes[$0..<min($0 + 4096, bytes.count)])
        }
        Task { @MainActor in
            for chunk in chunks {
                self.process.send(data: chunk[...])
                try? await Task.sleep(nanoseconds: 8_000_000) // 8мс
            }
        }
    }
}

struct LocalTerminalHostView: NSViewRepresentable {
    @EnvironmentObject var state: AppState
    let tab: Tab
    let isActive: Bool

    func makeNSView(context: Context) -> TrackedLocalTerminalView {
        if let existing = state.localTerminals[tab.id] { return existing }

        // Скроллбек 20 000 строк (дефолт SwiftTerm — 500) и постоянный ползунок.
        let tv = TrackedLocalTerminalView(
            frame: .zero, font: nil,
            options: TerminalOptions(scrollback: QTermTerminal.scrollbackLines)
        )
        tv.scrollerStyle = .legacy
        tv.appState = state
        tv.configureNativeColors()
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Логин-шелл юзера с его окружением.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        tv.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: "-" + (shell as NSString).lastPathComponent // логин-шелл
        )
        state.localTerminals[tab.id] = tv
        return tv
    }

    func updateNSView(_ tv: TrackedLocalTerminalView, context: Context) {
        tv.appState = state
        if isActive {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
            }
        }
    }
}
