import SwiftUI
import AppKit

// Панель мониторинга ноды (моба-стиль, канон Windows ServerMonitor):
// раз в 3 с один exec по живому SSH-соединению, всё из /proc + df -P + who —
// BusyBox-совместимо (Кинетик/Entware тоже). CPU и сеть — дельтами между
// опросами. Терминальные вкладки exec не трогает (отдельный канал).

struct DiskStat: Equatable, Hashable {
    let mount: String
    let pct: Int
}

struct NodeStats: Equatable {
    var cpu: Int
    var spark: String
    var memUsedMB: Int64
    var memTotalMB: Int64
    var rxMbps: Double
    var txMbps: Double
    var uptime: String
    var users: Int
    var usersDetail: String
    var disks: [DiskStat]
}

final class NodeMonitor: ObservableObject {
    static let enabledKey = "nodeMonitor"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static let command =
        "echo @1; head -1 /proc/stat; " +
        "echo @2; grep -E 'MemTotal|MemAvailable|MemFree' /proc/meminfo; " +
        "echo @3; cat /proc/uptime; " +
        "echo @4; cat /proc/net/dev; " +
        "echo @5; df -P 2>/dev/null; " +
        "echo @6; who 2>/dev/null; true" // код выхода 0: exec с ошибкой бросает

    @Published private(set) var stats: NodeStats?

    private var task: Task<Void, Never>?
    private var prevIdle: Int64 = -1
    private var prevTotal: Int64 = 0
    private var prevRx: Int64 = -1
    private var prevTx: Int64 = 0
    private var prevNetAt = Date()
    private var history: [Int] = []

    /// Соединение поднялось: свежие дельты, опрос каждые 3 с.
    func start(_ connection: SSHConnection) {
        stop()
        prevIdle = -1; prevTotal = 0; prevRx = -1; prevTx = 0; history = []
        task = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .milliseconds(500))
            while !Task.isCancelled {
                guard let self, let connection else { return }
                if Self.enabled, connection.status == .connected,
                   let out = try? await connection.exec(Self.command),
                   !Task.isCancelled,
                   let st = self.parse(out) {
                    self.stats = st
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Обрыв/отключение: не дёргаем мёртвый клиент, панель прячется.
    func stop() {
        task?.cancel()
        task = nil
        if stats != nil { stats = nil }
    }

    // MARK: - Разбор

    func parse(_ raw: String) -> NodeStats? {
        var sec: [String: [String]] = [:]
        var cur: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if l.hasPrefix("@") { cur = l; sec[l] = []; continue }
            if let c = cur, !l.isEmpty { sec[c, default: []].append(l) }
        }
        guard let cpuLine = sec["@1"]?.first else { return nil }

        // CPU: 100·(1 − dIdle/dTotal), idle = idle + iowait
        var cpu = 0
        let f = cpuLine.split(separator: " ")
        if f.count >= 5, f[0] == "cpu" {
            let vals = f.dropFirst().compactMap { Int64($0) }
            if vals.count >= 4 {
                let idle = vals[3] + (vals.count > 4 ? vals[4] : 0)
                let total = vals.reduce(0, +)
                if prevIdle >= 0, total > prevTotal {
                    let busy = 1.0 - Double(idle - prevIdle) / Double(total - prevTotal)
                    cpu = Int(min(100, max(0, 100 * busy)))
                }
                prevIdle = idle; prevTotal = total
            }
        }
        history.append(cpu)
        if history.count > 20 { history.removeFirst(history.count - 20) }
        let bars = Array("▁▂▃▄▅▆▇█")
        let spark = String(history.map { bars[min(7, $0 * 8 / 101)] })

        // RAM (кБ → МБ): used = total − available (фолбэк free)
        var memTotal: Int64 = 0, avail: Int64 = -1, free: Int64 = 0
        for l in sec["@2"] ?? [] {
            let parts = l.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let v = Int64(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") else { continue }
            switch parts[0] {
            case "MemTotal": memTotal = v
            case "MemAvailable": avail = v
            case "MemFree": free = v
            default: break
            }
        }
        let usedMB = (memTotal - (avail >= 0 ? avail : free)) / 1024
        let totalMB = memTotal / 1024

        // Аптайм
        var uptime = ""
        if let u = sec["@3"]?.first, let s = Double(u.split(separator: " ").first ?? "") {
            let secs = Int(s)
            let days = secs / 86_400, hours = secs % 86_400 / 3600, mins = secs % 3600 / 60
            uptime = days >= 1 ? "\(days)д \(hours)ч" : "\(hours)ч \(mins)м"
        }

        // Сеть: сумма rx/tx по интерфейсам кроме lo → Mb/s
        var rx: Int64 = 0, tx: Int64 = 0
        for l in sec["@4"] ?? [] {
            guard let colon = l.firstIndex(of: ":") else { continue }
            let name = l[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "lo", !name.contains(" ") else { continue }
            let cols = l[l.index(after: colon)...].split(separator: " ")
            if cols.count >= 9, let r = Int64(cols[0]), let t = Int64(cols[8]) {
                rx += r; tx += t
            }
        }
        var rxMbps = 0.0, txMbps = 0.0
        let now = Date()
        if prevRx >= 0 {
            let dt = now.timeIntervalSince(prevNetAt)
            if dt > 0.5 {
                rxMbps = Double(max(0, rx - prevRx)) * 8 / 1e6 / dt
                txMbps = Double(max(0, tx - prevTx)) * 8 / 1e6 / dt
            }
        }
        prevRx = rx; prevTx = tx; prevNetAt = now

        // Диски: /, /opt, /boot (df -P: Use% предпоследняя колонка, маунт последняя)
        var disks: [DiskStat] = []
        let want: Set<String> = ["/", "/opt", "/boot"]
        for l in (sec["@5"] ?? []).dropFirst() {
            let cols = l.split(separator: " ")
            guard cols.count >= 6, let mount = cols.last, want.contains(String(mount)),
                  let pct = Int(cols[cols.count - 2].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) else { continue }
            if !disks.contains(where: { $0.mount == mount }) {
                disks.append(DiskStat(mount: String(mount), pct: pct))
            }
        }
        disks.sort { $0.mount.count < $1.mount.count }

        // Пользователи: строки who → счётчик и детали в тултип
        let who = sec["@6"] ?? []
        let detail = who.map { l -> String in
            let c = l.split(separator: " ")
            guard c.count >= 2 else { return l }
            var s = "\(c[0]) — \(c[1])"
            if let p = l.firstIndex(of: "(") { s += " " + String(l[p...]) }
            return s
        }.joined(separator: "\n")

        return NodeStats(cpu: cpu, spark: spark, memUsedMB: usedMB, memTotalMB: totalMB,
                         rxMbps: rxMbps, txMbps: txMbps, uptime: uptime,
                         users: who.count, usersDetail: detail, disks: disks)
    }
}

/// Полоса чипов под терминалом активной SSH-вкладки.
struct NodeMonitorBar: View {
    @ObservedObject var monitor: NodeMonitor
    @AppStorage(NodeMonitor.enabledKey) private var enabled = true

    var body: some View {
        if enabled, let st = monitor.stats {
            FlowLayout(spacing: 6) {
                let spark = String(st.spark.suffix(12))
                chip("CPU", "\(spark) \(st.cpu)%", hot: st.cpu)
                let memPct = st.memTotalMB > 0 ? Int(100 * st.memUsedMB / st.memTotalMB) : 0
                chip("RAM", String(format: "%.1f/%.1f ГБ", Double(st.memUsedMB) / 1024, Double(st.memTotalMB) / 1024), hot: memPct)
                chip("", String(format: "↑%.2f ↓%.2f Mb/s", st.txMbps, st.rxMbps))
                if !st.uptime.isEmpty { chip("up", st.uptime) }
                if st.users > 0 { chip("польз", "\(st.users)", tip: st.usersDetail) }
                ForEach(st.disks, id: \.self) { d in
                    chip(d.mount, "\(d.pct)%", hot: d.pct)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) { Divider() }
        }
    }

    private func chip(_ label: String, _ value: String, hot: Int? = nil, tip: String? = nil) -> some View {
        let color: Color = {
            guard let hot else { return .primary }
            if hot >= 90 { return .red }
            if hot >= 80 { return .orange }
            return .primary
        }()
        return HStack(spacing: 5) {
            if !label.isEmpty {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.15)))
        .help(tip ?? "")
    }
}
