import SwiftUI
import AppKit
import SwiftTerm

/// Обёртка SwiftTerm.TerminalView для SwiftUI, привязанная к SSHConnection.
/// Поток данных:
///   сервер → Citadel ttyOutput → connection.onOutput → terminal.feed
///   клавиатура → TerminalViewDelegate.send → connection.sendToShell
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var connection: SSHConnection
    @EnvironmentObject var state: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(connection: connection, state: state)
    }

    func makeNSView(context: Context) -> TerminalView {
        let sessionID = connection.session.id

        // Существующий экран — переиспользуем: буфер и скроллбек живы.
        if let existing = state.terminals[sessionID] {
            existing.terminalDelegate = context.coordinator
            context.coordinator.terminalView = existing
            connection.onOutput = { [weak existing] bytes in
                existing?.feed(byteArray: bytes)
            }
            return existing
        }

        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        connection.onOutput = { [weak tv] bytes in
            tv?.feed(byteArray: bytes)
        }

        state.terminals[sessionID] = tv

        let t = tv.getTerminal()
        connection.connect(cols: t.cols, rows: t.rows)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let connection: SSHConnection
        let state: AppState
        weak var terminalView: TerminalView?

        init(connection: SSHConnection, state: AppState) {
            self.connection = connection
            self.state = state
        }

        // Клавиатурный ввод пользователя → stdin PTY (или во все — broadcast).
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                if connection.isInterrupted,
                   data.count == 1, let ch = data.first, ch == 0x72 || ch == 0x52 { // r / R
                    connection.retryNow()
                    return
                }
                if state.broadcastInput {
                    state.sendToAllConnected(data)
                } else {
                    connection.sendToShell(data)
                }
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { connection.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Заголовок окна по OSC 0/2 — прикрутить к WindowGroup позже.
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // OSC 7 — можно синхронизировать проводник с cwd шелла. Потом.
        }

        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        func bell(source: TerminalView) { NSSound.beep() }
    }
}
