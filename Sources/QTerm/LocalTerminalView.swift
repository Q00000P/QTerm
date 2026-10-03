import SwiftUI
import SwiftTerm

/// Локальный терминал мака: SwiftTerm сам форкает шелл (как Terminal.app).
/// Вся обвязка QTerm — подсказки, журнал (скоуп "mac"), сниппеты — работает
/// поверх, потому что живёт над терминалом, а не внутри SSH.

/// Сабкласс перехватывает юзер-ввод для CommandTracker до отправки в PTY.
final class TrackedLocalTerminalView: LocalProcessTerminalView {
    weak var appState: AppState?

    // Мышь как в мобе: выделение → буфер, правая кнопка → вставка.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        MobaMouse.copySelection(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        if MobaMouse.rightClickPaste {
            paste(self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

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
    /// Если шелл включил bracketed paste — оборачиваем, как делает сам
    /// SwiftTerm: многострочная вставка не выполняется построчно, а ждёт Enter.
    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        if text.utf8.count <= 4096 {
            super.paste(sender)
            return
        }
        let bracketed = getTerminal().bracketedPasteMode
        // ESC во вставке мог бы «закрыть» bracketed paste изнутри — вычищаем.
        var body = Array(text.replacingOccurrences(of: "\u{1B}", with: "").utf8)
        if bracketed {
            body = Array("\u{1B}[200~".utf8) + body + Array("\u{1B}[201~".utf8)
        }
        // Портянка — не команда для журнала.
        appState?.cmdTracker.markPasted(endsWithNewline: !bracketed && text.hasSuffix("\n"))
        let chunks = stride(from: 0, to: body.count, by: 4096).map {
            Array(body[$0..<min($0 + 4096, body.count)])
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
        // Шрифт и цвета — из настроек (тема/шрифт применяются живьём ко всем).
        TerminalLook.style(tv, local: true)

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
