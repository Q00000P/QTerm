using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Windows;
using QTermWin.Models;
using QTermWin.QDash;
using Session = QTermWin.Models.Session;

namespace QTermWin.UI;

/// <summary>Отдать ноды QTerm хабу: ключ хаба → authorized_keys ноды (по SSH-сессии QTerm), запись в хаб с пином host key.</summary>
public partial class QDashPushDialog : Window
{
    public sealed class Row : INotifyPropertyChanged
    {
        public Session S { get; init; } = null!;
        public string Name => S.Name;
        public string Addr => $"{(S.Username.Length > 0 ? S.Username + "@" : "")}{S.Host}:{S.Port}";
        public string Pin => S.Extra.TryGetValue("hostkey", out var k) && k.Length > 0 ? "есть" : "—";
        public string InHub { get; init; } = "";
        public bool IsNew { get; init; }
        private bool _on;
        public bool On { get => _on; set { _on = value; N(); } }
        private bool _router;
        public bool Router { get => _router; set { _router = value; N(); } }
        public event PropertyChangedEventHandler? PropertyChanged;
        private void N([CallerMemberName] string? p = null) => PropertyChanged?.Invoke(this, new(p));
    }

    private readonly QDashClient _client;
    private readonly Func<Guid, string, int, Task<string>> _exec;
    private readonly List<Row> _rows;
    public List<string> Log { get; } = new();
    public int Pushed { get; private set; }

    /// <param name="hubIds">id серверов, которые в хабе уже есть (id ноды QTerm → запись хаба).</param>
    public QDashPushDialog(QDashClient client, IEnumerable<Session> sessions, ISet<string> hubIds,
        Func<Guid, string, int, Task<string>> exec)
    {
        InitializeComponent();
        _client = client;
        _exec = exec;
        _rows = sessions.Where(s => s.Deleted != true)
            .OrderBy(s => s.Name, StringComparer.OrdinalIgnoreCase)
            .Select(s =>
            {
                var inHub = hubIds.Contains(s.Id.ToString("D").ToUpperInvariant());
                return new Row
                {
                    S = s, InHub = inHub ? "есть" : "нет", IsNew = !inHub, On = !inHub,
                    // Keenetic: ssh на 222 и адрес в своей сети — скорее всего роутер
                    Router = s.Port == 222 || s.Host.StartsWith("10.") || s.Host.StartsWith("192.168."),
                };
            }).ToList();
        NodeList.ItemsSource = _rows;
        Status.Text = $"Нод: {_rows.Count}, в хабе уже: {_rows.Count(r => !r.IsNew)}";
    }

    private void All_Click(object sender, RoutedEventArgs e) { foreach (var r in _rows) r.On = true; }
    private void None_Click(object sender, RoutedEventArgs e) { foreach (var r in _rows) r.On = false; }
    private void New_Click(object sender, RoutedEventArgs e) { foreach (var r in _rows) r.On = r.IsNew; }
    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;

    /// <summary>Пин host key в формате хаба/OpenSSH: SHA256:&lt;base64 без =&gt; от wire-блоба ключа.</summary>
    public static string HostkeyPin(Session s)
    {
        if (!s.Extra.TryGetValue("hostkey", out var b64) || b64.Length == 0) return "";
        try
        {
            return "SHA256:" + Convert.ToBase64String(SHA256.HashData(Convert.FromBase64String(b64))).TrimEnd('=');
        }
        catch { return ""; }
    }

    private async void Ok_Click(object sender, RoutedEventArgs e)
    {
        var sel = _rows.Where(r => r.On).ToList();
        if (sel.Count == 0) { Status.Text = "Ничего не выбрано"; return; }
        OkBtn.IsEnabled = false;
        string pub;
        try
        {
            Status.Text = "Ключ хаба…";
            var j = await _client.GetAsync("/api/vps/hubkey");
            pub = (j["pub"]?.ToString() ?? "").Trim();
            if (!pub.StartsWith("ssh-", StringComparison.Ordinal)) throw new Exception("хаб не отдал свой публичный ключ");
        }
        catch (Exception ex)
        {
            Status.Text = "✗ " + ex.Message;
            Log.Add("✗ ключ хаба: " + ex.Message);
            OkBtn.IsEnabled = true;
            return;
        }
        // одинарные кавычки в ключе невозможны (base64 + комментарий без них), но экранируем честно
        var pubSh = "'" + pub.Replace("'", "'\\''") + "'";
        // $HOME: на VPS /root, на Keenetic с Entware — /opt/root (там же dropbear ищет authorized_keys)
        var cmd = "{ d=\"$HOME/.ssh\"; mkdir -p \"$d\" && chmod 700 \"$d\" && f=\"$d/authorized_keys\"; " +
                  $"if grep -qF {pubSh} \"$f\" 2>/dev/null; then echo QD_HAVE; else printf '%s\\n' {pubSh} >> \"$f\" && chmod 600 \"$f\" && echo QD_ADDED; fi; }} 2>&1";
        var n = 0;
        foreach (var r in sel)
        {
            n++;
            Status.Text = $"{n}/{sel.Count}: {r.Name} — ключ хаба на ноду…";
            string outp;
            try { outp = await _exec(r.S.Id, cmd, 60); }
            catch (Exception ex)
            {
                Log.Add($"✗ {r.Name}: authorized_keys — {ex.Message}");
                continue;
            }
            if (!outp.Contains("QD_HAVE") && !outp.Contains("QD_ADDED"))
            {
                Log.Add($"✗ {r.Name}: authorized_keys не дописан: {Short(outp)}");
                continue;
            }
            Log.Add($"✓ {r.Name}: ключ хаба {(outp.Contains("QD_ADDED") ? "дописан" : "уже был")} в authorized_keys");
            Status.Text = $"{n}/{sel.Count}: {r.Name} — в хаб…";
            try
            {
                var body = new
                {
                    id = r.S.Id.ToString("D").ToUpperInvariant(),
                    name = r.Name, host = r.S.Host, port = r.S.Port,
                    user = r.S.Username.Length > 0 ? r.S.Username : "root",
                    auth = "hubkey", hostkey = HostkeyPin(r.S),
                    kind = r.Router ? "router" : "",
                    note = "из QTerm",
                };
                var res = await _client.PostAsync("/api/vps/save", body);
                var ok = res["ok"]?.GetValue<bool>() == true;
                var reach = res["reachable"]?.GetValue<bool>() == true;
                var err = res["error"]?.ToString() ?? "";
                if (!ok) Log.Add($"✗ {r.Name}: хаб не принял — {err}");
                else if (reach) { Log.Add($"✓ {r.Name}: в хабе, хаб подключился сам"); Pushed++; }
                else { Log.Add($"! {r.Name}: в хабе, но хаб не подключился: {err}"); Pushed++; }
            }
            catch (Exception ex)
            {
                Log.Add($"✗ {r.Name}: /api/vps/save — {ex.Message}");
            }
        }
        Status.Text = $"Готово: в хаб — {Pushed} из {sel.Count}";
        await Task.Delay(500);
        DialogResult = true;
    }

    private static string Short(string s)
    {
        s = s.Trim();
        return s.Length > 200 ? s[..200] + "…" : s;
    }
}
