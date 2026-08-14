import SwiftUI
import AppKit
import SwiftTerm

/// Обёртка SwiftTerm.TerminalView для SwiftUI, привязанная к вкладке (каналу).
/// Экраны живут в реестре AppState по id канала — переключение вкладок и нод
/// не уничтожает буфер и скроллбек.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var connection: SSHConnection
    @ObservedObject var channel: TerminalChannel
    @EnvironmentObject var state: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(connection: connection, channel: channel, state: state)
    }

    func makeNSView(context: Context) -> TerminalView {
        if let existing = state.terminals[channel.id] {
            existing.terminalDelegate = context.coordinator
            context.coordinator.terminalView = existing
            channel.onOutput = { [weak existing] bytes in
                existing?.feed(byteArray: bytes)
            }
            return existing
        }

        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        context.coordinator.terminalView = tv
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        channel.onOutput = { [weak tv] bytes in
            tv?.feed(byteArray: bytes)
        }

        state.terminals[channel.id] = tv

        let t = tv.getTerminal()
        channel.cols = t.cols
        channel.rows = t.rows

        // Соединение поднимается один раз на ноду; вкладка на живом
        // соединении открывается сразу в openChannel.
        if connection.status == .idle || connection.status == .closed {
            connection.connect(cols: t.cols, rows: t.rows)
        }
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        let connection: SSHConnection
        let channel: TerminalChannel
        let state: AppState
        weak var terminalView: TerminalView?

        init(connection: SSHConnection, channel: TerminalChannel, state: AppState) {
            self.connection = connection
            self.channel = channel
            self.state = state
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                if connection.isInterrupted,
                   data.count == 1, let ch = data.first, ch == 0x72 || ch == 0x52 { // r / R
                    connection.retryNow()
                    return
                }
                switch state.broadcastMode {
                case .off:
                    channel.send(data)
                case .allTabsOfNode:
                    connection.sendToAllChannels(data)
                case .allNodes:
                    state.sendToAllConnected(data)
                }
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { channel.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { channel.title = title.isEmpty ? nil : title }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

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
