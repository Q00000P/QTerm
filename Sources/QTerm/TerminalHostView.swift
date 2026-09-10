import SwiftUI
import AppKit
import SwiftTerm

/// Обёртка SwiftTerm.TerminalView для ОДНОЙ вкладки (канала).
/// Ввод уходит строго в свой канал; двусмысленность «чей делегат сработал
/// последним» исключена — каждый экран знает свой channel, а неактивные
/// вкладки не получают клики (allowsHitTesting) и фокус.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var connection: SSHConnection
    @ObservedObject var channel: TerminalChannel
    let isActive: Bool
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

        // Скроллбек: у SwiftTerm по умолчанию всего 500 строк — длинные
        // прогоны обрезались. Постоянный ползунок (.legacy) — для быстрой
        // прокрутки мышью.
        let tv = TerminalView(frame: .zero, font: nil, options: TerminalOptions(scrollback: QTermTerminal.scrollbackLines))
        tv.scrollerStyle = .legacy
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
        // Первая вкладка ноды поднимает соединение; остальные открывают
        // дополнительный канал поверх уже живого (мультиплекс).
        connection.connect(cols: t.cols, rows: t.rows)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Делегат всегда указывает на координатор ЭТОЙ вкладки.
        nsView.terminalDelegate = context.coordinator
        context.coordinator.terminalView = nsView
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

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
                // Страховка: печать обрабатывает только активная вкладка.
                guard state.activeTabID == channel.id else { return }

                if connection.isInterrupted,
                   data.count == 1, let ch = data.first, ch == 0x72 || ch == 0x52 { // r / R
                    connection.retryNow()
                    return
                }
                if state.handleSuggestionKey(data) { return }
                state.cmdTracker.feed(data)
                switch state.broadcastMode {
                case .off:
                    channel.send(data)
                case .allNodes:
                    state.sendToAllConnected(data)
                }
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { channel.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { channel.title = title }
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


/// Общие параметры терминалов (SSH и локального).
enum QTermTerminal {
    static let scrollbackKey = "scrollbackLines"
    static let scrollbackDefault = 20_000
    static let scrollbackRange = 50...1_000_000

    /// Строк истории на вкладку (настраивается, применяется к НОВЫМ вкладкам).
    static var scrollbackLines: Int {
        let stored = UserDefaults.standard.integer(forKey: scrollbackKey)
        guard stored > 0 else { return scrollbackDefault }
        return min(max(stored, scrollbackRange.lowerBound), scrollbackRange.upperBound)
    }
}
