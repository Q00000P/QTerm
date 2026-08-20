import SwiftUI
import SessionVaultKit

// MARK: - Восстановление набираемой строки из юзер-ввода
// Порт CommandTracker с Android: printable — в буфер, Backspace/^U/^W правят,
// Enter — команда в журнал. Стрелки (история шелла) и Tab (серверное
// дополнение) делают строку «грязной»: содержимого мы больше не знаем —
// подсказки гаснут, в журнал не пишем. Termius слепнет там же.

@MainActor
final class CommandTracker: ObservableObject {

    @Published private(set) var prefix = ""
    var onCommand: ((String) -> Void)?
    /// Дублируем состояние наружу (AppState): (prefix, dirty).
    var onStateChange: ((String, Bool) -> Void)?

    private var raw = Data()      // байты текущей строки (UTF-8)
    private var dirty = false
    /// Парсер ESC-последовательностей: их байты НЕ текст.
    private enum EscState { case none, esc, csi }
    private var escState: EscState = .none

    func feed(_ data: ArraySlice<UInt8>) {
        for byte in data {
            switch escState {
            case .esc:
                // ESC [ … (CSI) и ESC O … (SS3, стрелки в app-режиме)
                escState = (byte == 0x5b || byte == 0x4f) ? .csi : .none
                if escState == .none { dirty = true }
                continue
            case .csi:
                // Финальный байт 0x40–0x7E завершает последовательность.
                if (0x40...0x7e).contains(byte) {
                    escState = .none
                    dirty = true   // стрелки/Home/End — позиция/строка неизвестны
                }
                continue
            case .none:
                break
            }
            switch byte {
            case 0x0d, 0x0a: // Enter
                if !dirty {
                    let cmd = line().trimmingCharacters(in: .whitespaces)
                    if cmd.count >= 2 { onCommand?(cmd) }
                }
                raw.removeAll(keepingCapacity: true)
                dirty = false
                escState = .none   // Enter гарантированно завершает любую кашу
            case 0x7f, 0x08: // Backspace — убрать последний СИМВОЛ
                var s = line()
                if !s.isEmpty { s.removeLast(); raw = Data(s.utf8) }
            case 0x15: // ^U — строка пуста ГАРАНТИРОВАННО: выводит из dirty
                raw.removeAll(keepingCapacity: true)
                dirty = false
            case 0x17: // ^W — убрать последнее слово
                var s = line()
                while let last = s.last, last == " " { s.removeLast() }
                while let last = s.last, last != " " { s.removeLast() }
                raw = Data(s.utf8)
            case 0x03: // ^C — строка сброшена
                raw.removeAll(keepingCapacity: true)
                dirty = false
            case 0x09: // Tab — дополняет сервер, мы не видим результат
                dirty = true
            case 0x01, 0x05, 0x0b: // ^A/^E/^K — курсор/строка неизвестны
                dirty = true
            case 0x1b:
                escState = .esc
            case 0x20...:
                raw.append(byte)
            default:
                break
            }
        }
        prefix = dirty ? "" : line()
        onStateChange?(prefix, dirty)
    }

    func reset() {
        raw.removeAll(keepingCapacity: true)
        dirty = false
        escState = .none
        prefix = ""
        onStateChange?("", false)
    }

    private func line() -> String {
        String(decoding: raw, as: UTF8.self)
    }
}

// MARK: - Словарь (тот же набор, что на Android: стек Q)

enum CommandDict {
    static let common: [String] = [
        // системное
        "systemctl status", "systemctl restart", "systemctl stop", "systemctl start",
        "systemctl enable", "systemctl disable", "systemctl daemon-reload", "systemctl list-units",
        "journalctl -u", "journalctl -f", "journalctl -e", "journalctl --since",
        "reboot", "poweroff", "uptime", "uname -a", "hostnamectl", "timedatectl",
        "df -h", "du -sh", "free -h", "top", "htop", "ps aux", "kill", "killall",
        "lsof -i", "dmesg", "watch",
        // пакеты
        "apt update", "apt upgrade", "apt install", "apt remove", "apt autoremove",
        "apt search", "apt list --installed", "dpkg -l",
        "opkg update", "opkg install", "opkg remove", "opkg list-installed", "opkg files",
        // файлы
        "ls -la", "cd", "cat", "less", "tail -f", "tail -n", "head", "grep -r",
        "find / -name", "chmod +x", "chmod 644", "chown", "ln -s", "mkdir -p",
        "rm -rf", "cp -r", "mv", "touch", "nano", "vi", "tar -xzf", "tar -czf",
        "unzip", "rsync -avz", "scp", "dd if=", "mount", "umount",
        // сеть
        "ip a", "ip r", "ip link", "ip neigh", "ss -tulpn", "ss -s",
        "ping", "ping -c 4", "traceroute", "mtr", "dig", "dig @127.0.0.1",
        "nslookup", "host", "curl -I", "curl -s", "curl -o", "wget",
        "nft list ruleset", "nft flush ruleset", "iptables -L -n -v", "iptables -t nat -L -n",
        "tcpdump -i", "arp -a", "ethtool", "networkctl",
        // wireguard / vpn / прокси
        "wg", "wg show", "wg-quick up", "wg-quick down", "wg genkey", "wg pubkey",
        "awg show", "systemctl restart xray", "systemctl status xray",
        "journalctl -u xray -f", "x-ui", "x-ui status", "x-ui restart",
        "xray version", "xray run -test -config",
        "systemctl restart AdGuardHome", "systemctl status AdGuardHome",
        "unbound-control status", "unbound-control reload", "unbound-checkconf",
        "systemctl restart unbound",
        // web
        "nginx -t", "nginx -s reload", "systemctl restart nginx", "systemctl status nginx",
        "certbot renew", "certbot certificates",
        "caddy reload", "caddy validate",
        // docker
        "docker ps", "docker ps -a", "docker logs -f", "docker restart", "docker stop",
        "docker exec -it", "docker compose up -d", "docker compose down",
        "docker compose logs -f", "docker compose pull", "docker images", "docker system prune",
        // git
        "git status", "git pull", "git push", "git add -A", "git commit -m",
        "git log --oneline", "git diff", "git clone", "git checkout", "git stash",
        // разное
        "ssh", "ssh-keygen -t ed25519", "ssh-copy-id", "crontab -e", "crontab -l",
        "echo", "export", "env", "which", "whoami", "id", "date", "history",
        "openssl s_client -connect", "base64", "md5sum", "sha256sum",
    ]
}

// MARK: - Панель подсказок у курсора (Termius-стиль):
// вертикальный список, набранное — жирным, свои ★ голубые первыми.

struct SuggestionOverlay: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geo in
            let prefix = state.cmdPrefix
            if prefix.count >= 1, !state.suggestionsSuppressed,
               let tab = state.activeTab,
               let tv = state.terminals[tab.id],
               let ch = state.channel(for: tab) {
                let items = state.commandSuggestions(for: prefix)
                if !items.isEmpty {
                    let loc = tv.getTerminal().getCursorLocation()
                    let cols = CGFloat(max(ch.cols, 1))
                    let rows = CGFloat(max(ch.rows, 1))
                    let cellW = geo.size.width / cols
                    let cellH = geo.size.height / rows
                    let shown = Array(items.prefix(6))
                    let panelH = CGFloat(shown.count) * 26 + 10
                    let below = CGFloat(loc.y + 1) * cellH + 3
                    let y = (below + panelH > geo.size.height)
                        ? max(3, CGFloat(loc.y) * cellH - panelH - 3)   // над строкой
                        : below                                          // под строкой
                    let x = min(max(4, CGFloat(loc.x) * cellW), max(4, geo.size.width - 320))

                    panel(shown, prefix: prefix)
                        .offset(x: x, y: y)
                }
            }
        }
    }

    private func panel(_ items: [AppState.CommandSuggestion], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.text) { index, item in
                Button {
                    state.sendSuggestionRemainder(item.text, typedPrefix: prefix)
                } label: {
                    HStack(spacing: 5) {
                        if item.personal {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.cyan)
                        }
                        (Text(prefix).bold()
                         + Text(item.text.dropFirst(prefix.count)))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(item.personal ? Color.cyan : Color.green)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(
                        index == state.suggestionSelection
                            ? Color.accentColor.opacity(0.25) : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if item.personal {
                        Button("Удалить из журнала", role: .destructive) {
                            state.deleteCommand(item.text)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
    }
}
