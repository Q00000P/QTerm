using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using QTermWin.Models;
using QTermWin.QDash;
using QTermWin.Vault;
using Session = QTermWin.Models.Session;

namespace QTermWin.UI;

/// <summary>
/// «QDash» — отдельное окно (рядом с терминалом, «Нодами 3x-ui» и «Каскадом»): хаб QDash на домашнем сервере,
/// видящий всю сеть. QTerm ходит к нему по API с ключом устройства (ed25519, пин серта), страниц портала
/// снаружи нет — всё, что здесь, собрано из API. Разделы: Обзор (роутеры), Серверы (VPS хаба + выгрузка нод QTerm),
/// Задачи (вывод — вкладкой терминала QTerm), Устройство (ключ, роль, адреса).
/// </summary>
public partial class QDashWindow : Window
{
    public sealed class HubRow
    {
        public QDashHub Src { get; init; } = null!;
        public string Name => Src.Display;
        public string Sub { get; init; } = "";
        public Brush Dot { get; init; } = Brushes.Gray;
    }

    public sealed class RouterRow
    {
        public Brush Dot { get; init; } = Brushes.Gray;
        public string Name { get; init; } = "";
        public string Model { get; init; } = "";
        public string Internet { get; init; } = "";
        public string Clients { get; init; } = "";
        public string Load { get; init; } = "";
        public string Mihomo { get; init; } = "";
        public string Nodes { get; init; } = "";
        public string Net { get; init; } = "";
        public string Uptime { get; init; } = "";
        public string Age { get; init; } = "";
        public string Error { get; init; } = "";
    }

    public sealed class ServerRow
    {
        public string Id { get; init; } = "";
        public Brush Dot { get; init; } = Brushes.Gray;
        public string Name { get; init; } = "";
        public string Addr { get; init; } = "";
        public string Auth { get; init; } = "";
        public string Ping { get; init; } = "";
        public string Os { get; init; } = "";
        public string Stack { get; init; } = "";
        public string InQTerm { get; init; } = "";
        public string Checked { get; init; } = "";
        public string Error { get; init; } = "";
    }

    public sealed class JobRow
    {
        public string Id { get; init; } = "";
        public Brush Dot { get; init; } = Brushes.Gray;
        public string Title { get; init; } = "";
        public string Target { get; init; } = "";
        public string Status { get; init; } = "";
        public string Started { get; init; } = "";
        public string Took { get; init; } = "";
        public string Prompt { get; init; } = "";
        public string Error { get; init; } = "";
        public bool Running { get; init; }
    }

    private static readonly Brush Green = Frozen("#3FB950");
    private static readonly Brush Red = Frozen("#E5534B");
    private static readonly Brush Amber = Frozen("#E8B44C");
    private static readonly Brush Gray = Frozen("#8B949E");

    private static Brush Frozen(string hex)
    {
        var b = (SolidColorBrush)new BrushConverter().ConvertFromString(hex)!;
        b.Freeze();
        return b;
    }

    private readonly VaultRepo _repo;
    private readonly QDashStore _store;
    private List<QDashHub> _hubs = new();
    private readonly Dictionary<Guid, (string Sub, Brush Dot)> _hubState = new();
    private QDashClient? _client;
    private JsonObject? _whoami;
    private string _seg = "overview";
    private bool _busy, _loadingUi;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(15) };

    /// <summary>Открыть вывод задачи вкладкой терминала (ставит главное окно).</summary>
    public Action<QDashClient, string, string>? OpenJob { get; set; }
    /// <summary>exec по SSH-сессии QTerm (id, команда, таймаут) — для ключа хаба в authorized_keys.</summary>
    public Func<Guid, string, int, Task<string>>? ExecInSession { get; set; }

    public QDashWindow(VaultRepo repo)
    {
        InitializeComponent();
        _repo = repo;
        _store = new QDashStore(repo);
        QDashCenter.Store ??= _store;
        ShowSeg("overview");
        LoadHubs();
        _timer.Tick += async (_, _) => { if (!_busy && _client is not null && IsVisible) await RefreshAsync(quiet: true); };
        Loaded += async (_, _) => { _timer.Start(); await RefreshAsync(); };
        Closed += (_, _) => _timer.Stop();
        PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Key.F5) { e.Handled = true; await RefreshAsync(); }
        };
    }

    // ── лог ──

    private void Log(string line)
    {
        LogBox.AppendText((LogBox.Text.Length > 0 ? "\n" : "") + line);
        LogBox.ScrollToEnd();
    }

    // ── хабы ──

    private QDashHub? Sel => (HubList.SelectedItem as HubRow)?.Src;

    private void LoadHubs(Guid? pick = null)
    {
        var keep = pick ?? Sel?.Id;
        _hubs = _store.Hubs();
        _loadingUi = true;
        var rows = _hubs.Select(h =>
        {
            var st = _hubState.GetValueOrDefault(h.Id);
            var key = _store.Key(h.Id);
            return new HubRow
            {
                Src = h,
                Sub = st.Sub ?? (key is null ? "ключа на этом устройстве нет" : $"роль: {key.RoleName}"),
                Dot = st.Dot ?? (key is null ? Amber : Gray),
            };
        }).ToList();
        HubList.ItemsSource = rows;
        _loadingUi = false;
        var want = rows.FirstOrDefault(r => r.Src.Id == keep) ?? rows.FirstOrDefault();
        HubList.SelectedItem = want;
        if (want is null) BindHub(null);
    }

    private void HubList_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingUi) return;
        BindHub(Sel);
        // адресов локалки ещё нет (только что завели / приехал синком) — заодно перечитать /api/dev
        _ = RefreshAsync(addr: Sel?.Lan is null);
    }

    private void BindHub(QDashHub? h)
    {
        _whoami = null;
        if (h is null)
        {
            _client = null;
            HeadName.Text = "QDash";
            HeadStatus.Text = "";
            NoHubView.Visibility = Visibility.Visible;
            EnrollHereBtn.Visibility = Visibility.Collapsed;
            Body.Visibility = Visibility.Collapsed;
            return;
        }
        var key = _store.Key(h.Id);
        HeadName.Text = h.Display;
        if (key is null)
        {
            _client = null;
            HeadStatus.Text = "хаб приехал синком — ключ устройства здесь не заведён";
            NoHubView.Visibility = Visibility.Visible;
            NoHubText.Text = $"Хаб «{h.Display}» есть в вейлте (синк с другого устройства), но пара ключей у каждого QTerm своя — заведи этот по коду из портала (Настройки → Устройства → «Добавить»).";
            EnrollHereBtn.Visibility = Visibility.Visible;
            Body.Visibility = Visibility.Collapsed;
            return;
        }
        _client = QDashCenter.Client(h, key);
        NoHubView.Visibility = Visibility.Collapsed;
        Body.Visibility = Visibility.Visible;
        HeadStatus.Text = $"роль: {key.RoleName}";
        RenderDevice();
        ApplyRole();
    }

    private void HubAdd_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new QDashAddDialog(_store) { Owner = this };
        if (dlg.ShowDialog() != true || dlg.Hub is null) return;
        Log($"✓ хаб «{dlg.Hub.Display}» заведён");
        LoadHubs(dlg.Hub.Id); // выбор хаба → привязка клиента и опрос (с адресами локалки)
    }

    private void EnrollHere_Click(object sender, RoutedEventArgs e)
    {
        if (Sel is not { } h) return;
        var dlg = new QDashAddDialog(_store, h) { Owner = this };
        if (dlg.ShowDialog() != true) return;
        Log($"✓ ключ к «{h.Display}» заведён на этом устройстве");
        LoadHubs(h.Id);
    }

    private void HubRemove_Click(object sender, RoutedEventArgs e)
    {
        if (Sel is not { } h) return;
        if (MessageBox.Show(this, $"Убрать хаб «{h.Display}» из QTerm?\n\nКлюч устройства стирается; в портале хаба это устройство лучше отозвать (Настройки → Устройства). Запись уедет синком на остальные устройства.",
                "QDash", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        _store.DeleteHub(h.Id);
        QDashCenter.Drop(h.Id);
        _hubState.Remove(h.Id);
        Log($"✓ хаб «{h.Display}» убран");
        LoadHubs();
    }

    private void ForgetKey_Click(object sender, RoutedEventArgs e)
    {
        if (Sel is not { } h) return;
        if (MessageBox.Show(this, "Забыть ключ этого устройства к хабу? Хаб останется в списке, заводить придётся заново по коду.",
                "QDash", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        _store.ForgetKey(h.Id);
        QDashCenter.Drop(h.Id);
        _hubState.Remove(h.Id);
        LoadHubs(h.Id);
        BindHub(h);
    }

    private void RenameHub_Click(object sender, RoutedEventArgs e)
    {
        if (Sel is not { } h) return;
        var name = InputDialog.Ask(this, "Имя хаба в QTerm", h.Display);
        if (name is null) return;
        h.Name = name;
        _store.SaveHub(h);
        LoadHubs(h.Id);
        HeadName.Text = h.Display;
    }

    // ── разделы ──

    private void Seg_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button b && b.Tag is string s) ShowSeg(s);
    }

    private void ShowSeg(string s)
    {
        _seg = s;
        OverviewView.Visibility = s == "overview" ? Visibility.Visible : Visibility.Collapsed;
        ServersView.Visibility = s == "servers" ? Visibility.Visible : Visibility.Collapsed;
        JobsView.Visibility = s == "jobs" ? Visibility.Visible : Visibility.Collapsed;
        DeviceView.Visibility = s == "device" ? Visibility.Visible : Visibility.Collapsed;
        foreach (var b in new[] { SegOverview, SegServers, SegJobs, SegDevice })
            b.SetResourceReference(BackgroundProperty, (string)b.Tag == s ? "SelBrush" : "Panel2Brush");
        if (IsLoaded && _client is not null) _ = RefreshAsync(quiet: true);
    }

    /// <summary>Кнопки выше потолка роли — серые с подсказкой, а не 403 после нажатия.</summary>
    private void ApplyRole()
    {
        var c = _client;
        void Gate(Button b, int tier, string what)
        {
            var ok = c is not null && c.Can(tier);
            b.IsEnabled = ok;
            if (!ok && c is not null)
                b.ToolTip = $"{what} — это {(tier == 2 ? "опасное" : "обратимое")}, роли «{c.Key?.RoleName}» не хватает (роль меняется в портале)";
        }
        Gate(PushBtn, 2, "Запись сервера в хаб");
        Gate(RemoveSrvBtn, 2, "Удаление сервера из хаба");
        Gate(JobKillBtn, 1, "Остановка задачи");
        Gate(InspectBtn, 0, "");
        Gate(ProbeBtn, 0, "");
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync(addr: true);

    /// <summary>Опрос хаба под текущий раздел. addr — заодно перечитать адреса (/api/dev).</summary>
    private async Task RefreshAsync(bool quiet = false, bool addr = false)
    {
        if (_client is null || Sel is not { } h) return;
        if (_busy) return;
        _busy = true;
        var c = _client;
        try
        {
            if (_whoami is null || !quiet)
            {
                _whoami = await Task.Run(() => c.WhoAmIAsync());
                var host = _whoami["host"]?.ToString() ?? "";
                var ver = _whoami["version"]?.ToString() ?? "";
                var roleName = _whoami["roleName"]?.ToString() ?? c.Key?.RoleName ?? "";
                if (host.Length > 0 && h.Host != host) { h.Host = host; _store.SaveHub(h); }
                if (c.Key is { } k)
                {
                    var saved = _store.Key(h.Id);
                    if (saved is not null && (saved.Role != k.Role || saved.RoleName != k.RoleName || saved.Name != k.Name))
                    { saved.Role = k.Role; saved.RoleName = k.RoleName; saved.Name = k.Name; _store.SaveKey(h.Id, saved); }
                }
                var via = c.Active is { } a ? (h.Lan?.Contains(a.Url) == true ? "локалка" : "снаружи") : "";
                HeadStatus.Text = $"{host} · qdash {ver} · роль: {roleName}{(via.Length > 0 ? " · путь: " + via : "")}";
                _hubState[h.Id] = ($"{host} · qdash {ver} · {roleName}", Green);
                ApplyRole();
                RenderDevice();
            }
            if (addr) await RefreshAddrAsync(c, h);
            switch (_seg)
            {
                case "overview": await RefreshOverviewAsync(c); break;
                case "servers": await RefreshServersAsync(c); break;
                case "jobs": await RefreshJobsAsync(c); break;
                case "device": RenderDevice(); break;
            }
        }
        catch (QDashError ex)
        {
            _hubState[h.Id] = (ex.Status == 0 ? "не отвечает" : $"HTTP {ex.Status}: {ex.Message}", ex.Status == 0 ? Red : Amber);
            HeadStatus.Text = ex.Status == 0 ? "хаб не отвечает: " + ex.Message : $"хаб: {ex.Message}";
            if (ex.Login) HeadStatus.Text += " — ключ отозван или часы разошлись; «Устройство → Перезавести ключ…»";
            if (!quiet) Log("✗ " + HeadStatus.Text);
        }
        catch (Exception ex)
        {
            HeadStatus.Text = "✗ " + ex.Message;
            if (!quiet) Log("✗ " + ex.Message);
        }
        finally
        {
            _busy = false;
            var keep = h.Id;
            _loadingUi = true;
            var rows = (HubList.ItemsSource as List<HubRow>) ?? new();
            var idx = rows.FindIndex(r => r.Src.Id == keep);
            if (idx >= 0 && _hubState.TryGetValue(keep, out var st))
            {
                rows[idx] = new HubRow { Src = rows[idx].Src, Sub = st.Sub, Dot = st.Dot };
                HubList.ItemsSource = null;
                HubList.ItemsSource = rows;
                HubList.SelectedItem = rows[idx];
            }
            _loadingUi = false;
        }
    }

    /// <summary>/api/dev → lan (адреса портала в локалке, его отпечаток) и api.url/fp (снаружи).</summary>
    private async Task RefreshAddrAsync(QDashClient c, QDashHub h)
    {
        var j = await Task.Run(() => c.GetAsync("/api/dev"));
        var changed = false;
        if (j["lan"] is JsonObject lan)
        {
            var port = lan["port"]?.ToString() ?? "";
            var tls = lan["tls"]?.GetValue<bool>() == true;
            var fp = QDashClient.Norm(lan["fp"]?.ToString() ?? "");
            var urls = new List<string>();
            var hosts = new List<string>();
            if (lan["ips"] is JsonArray ips) hosts.AddRange(ips.Select(x => x?.ToString() ?? "").Where(x => x.Length > 0));
            if (lan["host"]?.ToString() is { Length: > 0 } hn && !hosts.Contains(hn)) hosts.Add(hn);
            if (port.Length > 0)
                foreach (var hst in hosts) urls.Add($"{(tls ? "https" : "http")}://{hst}:{port}");
            if (!urls.SequenceEqual(h.Lan ?? new()) || (h.LanFp ?? "") != fp)
            {
                h.Lan = urls.Count > 0 ? urls : null;
                h.LanFp = fp.Length > 0 ? fp : null;
                changed = true;
            }
        }
        if (j["api"] is JsonObject api)
        {
            var url = (api["url"]?.ToString() ?? "").TrimEnd('/');
            var fp = QDashClient.Norm(api["fp"]?.ToString() ?? "");
            // внешний адрес из хаба — только если он там задан; свой (из ссылки заведения) не затираем пустым
            if (url.Length > 0 && (h.Url != url || h.Fp != fp)) { h.Url = url; h.Fp = fp; changed = true; }
        }
        if (changed)
        {
            _store.SaveHub(h);
            _client = QDashCenter.Client(h, _store.Key(h.Id));
            Log($"✓ адреса хаба обновлены: снаружи {h.Url}{(h.Lan is { Count: > 0 } ? ", в локалке " + string.Join(", ", h.Lan) : "")}");
        }
        RenderDevice();
    }

    // ── Обзор ──

    private static string S(JsonNode? n, string key) => n?[key]?.ToString() ?? "";
    private static double D(JsonNode? n, string key)
    {
        try { return n?[key]?.GetValue<double>() ?? 0; } catch { return 0; }
    }
    private static bool B(JsonNode? n, string key) => n?[key]?.GetValue<bool>() == true;

    private async Task RefreshOverviewAsync(QDashClient c)
    {
        var j = await Task.Run(() => c.GetAsync("/api/hub"));
        var agents = j["agents"] as JsonArray ?? new JsonArray();
        var rows = new List<RouterRow>();
        int ok = 0, clients = 0;
        foreach (var a in agents)
        {
            var sm = a?["summary"];
            var isOk = B(a, "ok");
            if (isOk) ok++;
            var cl = (int)D(sm, "clients");
            clients += cl;
            var age = (int)D(a, "age");
            var nodesOk = (int)D(sm, "nodesOk");
            var nodes = (int)D(sm, "nodes");
            var wanDesc = S(sm, "wanDesc");
            var wan = S(sm, "wan");
            var inet = S(sm, "internet");
            rows.Add(new RouterRow
            {
                Dot = isOk ? Green : (age < 0 ? Gray : Red),
                Name = S(a, "name").Length > 0 ? S(a, "name") : S(sm, "host"),
                Model = string.Join(" · ", new[] { S(sm, "model"), S(sm, "firmware") }.Where(x => x.Length > 0)),
                Internet = inet.Length > 0 ? inet + (wanDesc.Length > 0 ? " · " + wanDesc : wan.Length > 0 ? " · " + wan : "") : wanDesc,
                Clients = sm is null ? "" : cl.ToString(),
                Load = sm is null ? "" : $"{D(sm, "cpu"):0}% / {D(sm, "mem"):0}%",
                Mihomo = sm is null ? "" : B(sm, "mihomoOk") ? "работает " + S(sm, "mihomoVer") : "нет",
                Nodes = sm is null ? "" : $"{nodesOk} / {nodes}",
                Net = sm is null ? "" : $"{Rate(D(sm, "downRate"))} / {Rate(D(sm, "upRate"))}",
                Uptime = S(sm, "uptime"),
                Age = age < 0 ? "не было" : age < 60 ? $"{age} с" : $"{age / 60} мин",
                Error = S(a, "error"),
            });
        }
        RouterList.ItemsSource = rows;
        OverviewCards.Children.Clear();
        Card("Хаб", $"{S(j, "host")} · qdash {S(j, "version")}");
        Card("Роутеров", $"{ok} из {agents.Count} на связи");
        Card("Клиентов онлайн", clients.ToString());
        Card("Опрос", D(j, "interval") > 0 ? $"каждые {D(j, "interval"):0} с" : "");
        if (D(j, "hist") > 0) Card("История", $"каждые {D(j, "hist"):0} с");
    }

    private void Card(string cap, string val)
    {
        var sp = new StackPanel { Margin = new Thickness(0, 0, 28, 4) };
        sp.Children.Add(new TextBlock { Text = cap, Foreground = (Brush)FindResource("DimBrush"), FontSize = 11.5 });
        sp.Children.Add(new TextBox
        {
            Text = val, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            Padding = new Thickness(0), FontSize = 15, FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)FindResource("FgBrush"),
        });
        OverviewCards.Children.Add(sp);
    }

    private static string Rate(double v)
    {
        // хаб отдаёт байты/с
        var mbps = v * 8 / 1_000_000;
        return mbps >= 100 ? $"{mbps:0}" : mbps >= 10 ? $"{mbps:0.0}" : $"{mbps:0.00}";
    }

    // ── Серверы ──

    private List<JsonObject> _servers = new();

    private async Task RefreshServersAsync(QDashClient c)
    {
        var arr = await Task.Run(() => c.GetArrayAsync("/api/vps"));
        _servers = arr.OfType<JsonObject>().ToList();
        var sessions = _repo.Data.Sessions.Where(s => s.Deleted != true).ToList();
        var rows = new List<ServerRow>();
        foreach (var v in _servers)
        {
            var info = v["info"] as JsonObject;
            var id = S(v, "id");
            var host = S(v, "host");
            var inQ = sessions.FirstOrDefault(s => string.Equals(s.Id.ToString("D"), id, StringComparison.OrdinalIgnoreCase))
                      ?? sessions.FirstOrDefault(s => string.Equals(s.Host.Trim(), host, StringComparison.OrdinalIgnoreCase));
            var checkedAt = (long)D(v, "checked");
            var stack = new List<string>();
            if (info is not null)
            {
                foreach (var (k, label) in new[] { ("xui", "3x-ui"), ("awgpanel", "AWG"), ("qcascade", "каскад"), ("mtg", "mtg"), ("telemt", "telemt"), ("docker", "docker"), ("nginx", "nginx"), ("ufw", "ufw") })
                {
                    var val = S(info, k);
                    if (val.Length > 0 && val != "0" && val != "no" && val != "false") stack.Add(label + (val is "1" or "yes" or "true" ? "" : " " + val));
                }
            }
            rows.Add(new ServerRow
            {
                Id = id,
                Dot = B(v, "ok") ? Green : checkedAt == 0 ? Gray : Red,
                Name = S(v, "name") + (S(v, "kind") == "router" ? " (роутер)" : ""),
                Addr = $"{S(v, "user")}@{host}:{D(v, "port"):0}",
                Auth = S(v, "auth") switch { "hubkey" => "ключ хаба", "key" => "ключ", _ => "пароль" },
                Ping = D(v, "latency") > 0 ? $"{D(v, "latency"):0}" : "",
                Os = info is null ? "" : S(info, "os"),
                Stack = string.Join(", ", stack),
                InQTerm = inQ is null ? "нет" : inQ.Name,
                Checked = checkedAt > 0 ? DateTimeOffset.FromUnixTimeSeconds(checkedAt).ToLocalTime().ToString("dd.MM HH:mm") : "",
                Error = S(v, "error"),
            });
        }
        ServerList.ItemsSource = rows;
        ServersStatus.Text = $"серверов: {rows.Count}, на связи: {rows.Count(r => ReferenceEquals(r.Dot, Green))}";
    }

    private ServerRow? SelServer => ServerList.SelectedItem as ServerRow;

    private void ServerList_DoubleClick(object sender, MouseButtonEventArgs e) => Inspect_Click(sender, e);

    private async void Push_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || ExecInSession is null) return;
        var have = _servers.Select(v => S(v, "id").ToUpperInvariant()).ToHashSet();
        var dlg = new QDashPushDialog(_client, _repo.Data.Sessions, have, ExecInSession) { Owner = this };
        dlg.ShowDialog();
        foreach (var l in dlg.Log) Log(l);
        if (dlg.Pushed > 0) await RefreshAsync();
    }

    private async void Probe_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || SelServer is not { } s) return;
        await Op($"Проба {s.Name}", async c =>
        {
            var j = await c.PostAsync("/api/vps/probe", new { id = s.Id });
            if (B(j, "ok")) Log($"✓ {s.Name}: SSH ок, {D(j, "latency"):0} мс" + (j["info"] is JsonObject i ? $" · {S(i, "hostname")} · {S(i, "os")} · up {S(i, "uptime")}" : ""));
            else Log($"✗ {s.Name}: {S(j, "error")}");
            await RefreshServersAsync(c);
        });
    }

    private async void Inspect_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || SelServer is not { } s) return;
        await Op($"Осмотр {s.Name}", async c =>
        {
            var j = await c.GetAsync($"/api/vps/inspect?id={Uri.EscapeDataString(s.Id)}&refresh=1");
            if (!B(j, "ok")) { Log($"✗ {s.Name}: {S(j, "error")}"); return; }
            if (j["data"] is JsonObject d)
            {
                foreach (var (k, v) in d)
                {
                    var text = v is JsonObject or JsonArray ? v!.ToJsonString() : v?.ToString() ?? "";
                    if (text.Length > 300) text = text[..300] + "…";
                    Log($"  {k}: {text}");
                }
            }
            else Log("  " + j.ToJsonString());
        });
    }

    private async void RemoveSrv_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || SelServer is not { } s) return;
        if (MessageBox.Show(this, $"Убрать «{s.Name}» из хаба? Нода в QTerm остаётся, ключ хаба на сервере — тоже.",
                "QDash", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        await Op($"Убрать {s.Name}", async c =>
        {
            var j = await c.PostAsync("/api/vps/remove", new { id = s.Id });
            Log(B(j, "ok") ? $"✓ {s.Name} убран из хаба" : $"✗ {S(j, "error")}");
            await RefreshServersAsync(c);
        });
    }

    // ── Задачи ──

    private async Task RefreshJobsAsync(QDashClient c)
    {
        var arr = await Task.Run(() => c.GetArrayAsync("/api/jobs"));
        var rows = new List<JobRow>();
        foreach (var j in arr.OfType<JsonObject>())
        {
            var st = S(j, "status");
            var started = (long)D(j, "started");
            var ended = (long)D(j, "ended");
            var took = ended > 0 && started > 0 ? TimeSpan.FromSeconds(ended - started) : started > 0 ? DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeSeconds(started) : TimeSpan.Zero;
            rows.Add(new JobRow
            {
                Id = S(j, "id"),
                Dot = st switch { "running" => B(j, "waiting") ? Amber : Green, "done" => Gray, _ => Red },
                Title = S(j, "title").Length > 0 ? S(j, "title") : S(j, "recipe"),
                Target = S(j, "targetName").Length > 0 ? S(j, "targetName") : S(j, "target"),
                Status = st switch { "running" => B(j, "waiting") ? "ждёт ввода" : "идёт", "done" => "готово" + (D(j, "exit") != 0 ? $" (код {D(j, "exit"):0})" : ""), "failed" => "ошибка", "killed" => "остановлена", _ => st },
                Started = started > 0 ? DateTimeOffset.FromUnixTimeSeconds(started).ToLocalTime().ToString("dd.MM HH:mm:ss") : "",
                Took = took.TotalSeconds < 1 ? "" : took.TotalMinutes < 1 ? $"{took.TotalSeconds:0} с" : $"{took.TotalMinutes:0} мин",
                Prompt = S(j, "prompt"),
                Error = S(j, "error"),
                Running = st == "running",
            });
        }
        JobList.ItemsSource = rows;
        JobsStatus.Text = $"задач: {rows.Count}, идут: {rows.Count(r => r.Running)}";
    }

    private JobRow? SelJob => JobList.SelectedItem as JobRow;

    private void JobList_DoubleClick(object sender, MouseButtonEventArgs e) => JobOpen_Click(sender, e);

    private void JobOpen_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || SelJob is not { } j) return;
        if (OpenJob is null) { Log("! вкладки задач недоступны"); return; }
        OpenJob(_client, j.Id, j.Title);
    }

    private async void JobKill_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || SelJob is not { } j) return;
        if (!j.Running) { Log("! задача уже не идёт"); return; }
        if (MessageBox.Show(this, $"Остановить задачу «{j.Title}»?", "QDash", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        await Op($"Остановить {j.Title}", async c =>
        {
            var r = await c.PostAsync("/api/jobs/kill", new { id = j.Id });
            Log(B(r, "ok") ? "✓ остановлена" : "✗ " + S(r, "error"));
            await RefreshJobsAsync(c);
        });
    }

    // ── Устройство ──

    private void RenderDevice()
    {
        if (Sel is not { } h) return;
        var key = _store.Key(h.Id);
        DevName.Text = key is null ? "ключа нет" : $"{key.Name} · {key.Dev}";
        DevRole.Text = key is null ? "" : $"{key.RoleName} ({key.Role})" +
            (_whoami is { } w ? $" · тир {S(w, "tier")}: {S(w, "tierName")}" : "");
        DevPub.Text = key?.Pub ?? "";
        DevExt.Text = h.Url.Length > 0 ? $"{h.Url}\nsha256:{h.Fp}" : "—";
        DevLan.Text = h.Lan is { Count: > 0 } ? string.Join("\n", h.Lan) + $"\nsha256:{h.LanFp}" : "— (нажми «Перечитать адреса из хаба»)";
        DevActive.Text = _client?.Active is { } a ? a.Url : "ещё не ходили";
    }

    private async void RefreshAddr_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null || Sel is not { } h) return;
        await Op("Адреса хаба", async c => await RefreshAddrAsync(c, h));
    }

    private async void Unlock_Click(object sender, RoutedEventArgs e)
    {
        if (_client is null) return;
        var code = InputDialog.Ask(this, "Код 2FA хаба (TOTP или код восстановления) — откроет окно опасных действий для этого устройства");
        if (code is null) return;
        await Op("Окно кодом", async c =>
        {
            var until = await c.UnlockAsync(code, 2);
            Log(until > 0 ? $"✓ окно открыто до {DateTimeOffset.FromUnixTimeSeconds(until).ToLocalTime():HH:mm dd.MM}" : "✓ принято (2FA в хабе не заведена)");
        });
    }

    // ── общее ──

    private async Task Op(string title, Func<QDashClient, Task> body)
    {
        if (_client is not { } c) return;
        if (_busy) { Log("! дождись окончания текущей операции"); return; }
        _busy = true;
        Log($"━━ {title}");
        try { await body(c); }
        catch (QDashError ex) { Log($"✗ {ex.Message}" + (ex.Status > 0 ? $" (HTTP {ex.Status})" : "")); }
        catch (Exception ex) { Log("✗ " + ex.Message); }
        finally { _busy = false; }
    }
}
