using System.Text.RegularExpressions;
using Renci.SshNet;

namespace QTermWin.Terminal;

public sealed record DiskStat(string Mount, int Pct, long UsedKb = 0, long TotalKb = 0, bool ReadOnly = false);

public sealed record MonitorStats(
    int CpuPct, string Spark,
    long MemUsedMb, long MemTotalMb,
    double RxMbps, double TxMbps,
    string Uptime, int Users, string UsersDetail,
    List<DiskStat> Disks)
{
    /// <summary>CPU % за последние опросы (для мини-графика).</summary>
    public int[] History { get; init; } = [];
    public string Host { get; init; } = "";
    public string Os { get; init; } = "";
    public string Arch { get; init; } = "";
    public int Cores { get; init; }
    /// <summary>Load average 1/5/15 мин.</summary>
    public string Load { get; init; } = "";
    public double? TempC { get; init; }
}

/// <summary>
/// Панель мониторинга (моба-стиль): раз в 3с один exec-запрос по живому
/// SSH-клиенту сессии, всё из /proc + df -P — BusyBox-совместимо.
/// CPU и сеть — дельтами между опросами.
/// </summary>
public sealed class ServerMonitor : IDisposable
{
    private const string Cmd =
        "echo @1; head -1 /proc/stat; " +
        "echo @2; grep -E 'MemTotal|MemAvailable|MemFree' /proc/meminfo; " +
        "echo @3; cat /proc/uptime; " +
        "echo @4; cat /proc/net/dev; " +
        "echo @5; df -P 2>/dev/null; " +
        "echo @6; who 2>/dev/null; " +
        "echo @7; cat /proc/sys/kernel/hostname 2>/dev/null; " +
        "echo @8; cat /proc/loadavg 2>/dev/null; " +
        "echo @9; grep -c ^processor /proc/cpuinfo 2>/dev/null; " +
        "echo @10; uname -m 2>/dev/null; " +
        "echo @11; (. /etc/os-release 2>/dev/null && echo \"$PRETTY_NAME\"); " +
        "echo @12; cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null; " +
        "echo @13; grep -E ' (/|/opt|/boot) ' /proc/mounts 2>/dev/null";

    private readonly SshClient _client;
    private readonly Timer _timer;
    private int _busy;
    private volatile bool _disposed;

    private long _prevIdle = -1, _prevTotal;
    private long _prevRx = -1, _prevTx;
    private DateTime _prevNetAt;
    private readonly Queue<int> _history = new();

    public event Action<MonitorStats>? Updated;

    public ServerMonitor(SshClient client)
    {
        _client = client;
        _timer = new Timer(_ => Tick(), null, TimeSpan.FromMilliseconds(500), TimeSpan.FromSeconds(3));
    }

    private void Tick()
    {
        if (_disposed || Interlocked.Exchange(ref _busy, 1) == 1) return;
        try
        {
            if (!_client.IsConnected) return;
            using var cmd = _client.CreateCommand(Cmd);
            var outp = cmd.Execute();
            if (_disposed) return;
            var stats = Parse(outp);
            if (stats is not null) Updated?.Invoke(stats);
        }
        catch { /* обрыв/реконнект — молчим, монитор пересоздадут */ }
        finally { Interlocked.Exchange(ref _busy, 0); }
    }

    private MonitorStats? Parse(string raw)
    {
        var sec = new Dictionary<string, List<string>>();
        List<string>? cur = null;
        foreach (var line in raw.Split('\n'))
        {
            var l = line.TrimEnd('\r');
            if (l.StartsWith('@')) { cur = sec[l] = new(); continue; }
            if (cur is not null && l.Length > 0) cur.Add(l);
        }
        if (!sec.ContainsKey("@1")) return null;

        // CPU: dIdle/dTotal
        int cpuPct = 0;
        var f = sec["@1"][0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (f.Length >= 5 && f[0] == "cpu")
        {
            var vals = f.Skip(1).Select(long.Parse).ToArray();
            long idle = vals[3] + (vals.Length > 4 ? vals[4] : 0);
            long total = vals.Sum();
            if (_prevIdle >= 0 && total > _prevTotal)
                cpuPct = (int)Math.Clamp(100.0 * (1.0 - (double)(idle - _prevIdle) / (total - _prevTotal)), 0, 100);
            _prevIdle = idle; _prevTotal = total;
        }
        _history.Enqueue(cpuPct);
        while (_history.Count > 20) _history.Dequeue();
        const string bars = "▁▂▃▄▅▆▇█";
        var spark = string.Concat(_history.Select(p => bars[Math.Min(7, p * 8 / 101)]));

        // RAM (кБ → МБ), used = total - available (фолбэк free)
        long total_ = 0, avail = -1, free = 0;
        foreach (var l in sec.GetValueOrDefault("@2", new()))
        {
            var m = Regex.Match(l, @"^(\w+):\s+(\d+)");
            if (!m.Success) continue;
            var v = long.Parse(m.Groups[2].Value);
            switch (m.Groups[1].Value)
            {
                case "MemTotal": total_ = v; break;
                case "MemAvailable": avail = v; break;
                case "MemFree": free = v; break;
            }
        }
        var usedMb = (total_ - (avail >= 0 ? avail : free)) / 1024;
        var totalMb = total_ / 1024;

        // Uptime
        var up = "";
        if (sec.GetValueOrDefault("@3") is { Count: > 0 } u &&
            double.TryParse(u[0].Split(' ')[0], System.Globalization.CultureInfo.InvariantCulture, out var upSec))
        {
            var ts = TimeSpan.FromSeconds(upSec);
            up = ts.TotalDays >= 1 ? $"{(int)ts.TotalDays}д {ts.Hours}ч" : $"{ts.Hours}ч {ts.Minutes}м";
        }

        // Сеть: сумма rx/tx по не-lo, дельта → Mb/s
        long rx = 0, tx = 0;
        foreach (var l in sec.GetValueOrDefault("@4", new()))
        {
            var m = Regex.Match(l, @"^\s*([^:\s]+):\s*(.+)$");
            if (!m.Success || m.Groups[1].Value == "lo") continue;
            var cols = m.Groups[2].Value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (cols.Length >= 9) { rx += long.Parse(cols[0]); tx += long.Parse(cols[8]); }
        }
        double rxMbps = 0, txMbps = 0;
        var now = DateTime.UtcNow;
        if (_prevRx >= 0)
        {
            var dt = (now - _prevNetAt).TotalSeconds;
            if (dt > 0.5)
            {
                rxMbps = Math.Max(0, rx - _prevRx) * 8 / 1e6 / dt;
                txMbps = Math.Max(0, tx - _prevTx) * 8 / 1e6 / dt;
            }
        }
        _prevRx = rx; _prevTx = tx; _prevNetAt = now;

        // ro-маунты (squashfs корня роутера всегда 100% — это не «диск забит»)
        var ro = new Dictionary<string, bool>();
        foreach (var l in sec.GetValueOrDefault("@13", new()))
        {
            var c = l.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (c.Length >= 4) ro[c[1]] = c[3] == "ro" || c[3].StartsWith("ro,"); // последняя запись — действующая
        }

        // Диски: /, /opt, /boot (df -P: размер, занято, свободно, Use%, маунт — считаем с конца)
        var disks = new List<DiskStat>();
        var want = new[] { "/", "/opt", "/boot" };
        foreach (var l in sec.GetValueOrDefault("@5", new()).Skip(1))
        {
            var cols = l.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (cols.Length < 6) continue;
            var mount = cols[^1];
            if (!want.Contains(mount)) continue;
            if (int.TryParse(cols[^2].TrimEnd('%'), out var pct))
            {
                long.TryParse(cols[^5], out var totKb);
                long.TryParse(cols[^4], out var usedKb);
                disks.Add(new DiskStat(mount, pct, usedKb, totKb, ro.GetValueOrDefault(mount)));
            }
        }
        disks = disks.OrderBy(d => d.Mount.Length).Take(3).ToList();

        // Пользователи: строки who → счётчик + детали в тултип
        var whoLines = sec.GetValueOrDefault("@6", new());
        var users = whoLines.Count;
        var detail = string.Join("\n", whoLines.Select(l =>
        {
            var c = l.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            return c.Length >= 2 ? $"{c[0]} — {c[1]}" + (l.Contains('(') ? " " + l[l.IndexOf('(')..] : "") : l;
        }));

        string First(string k) => sec.GetValueOrDefault(k) is { Count: > 0 } x ? x[0].Trim() : "";
        var load = string.Join(" ", First("@8").Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(3));
        int.TryParse(First("@9"), out var cores);
        double? temp = null;
        if (long.TryParse(First("@12"), out var milli) && milli > 0)
            temp = milli > 1000 ? milli / 1000.0 : milli;

        return new MonitorStats(cpuPct, spark, usedMb, totalMb, rxMbps, txMbps, up, users, detail, disks)
        {
            History = _history.ToArray(),
            Host = First("@7"),
            Load = load,
            Cores = cores,
            Arch = First("@10"),
            Os = First("@11"),
            TempC = temp,
        };
    }

    public void Dispose()
    {
        _disposed = true;
        _timer.Dispose();
    }
}
