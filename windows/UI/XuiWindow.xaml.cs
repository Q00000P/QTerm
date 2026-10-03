using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using QTermWin.Vault;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>
/// «Ноды 3x-ui»: главная панель + её узлы (встроенный мультинод 3x-ui v3).
/// Монитор, клиенты × серверы (привязка/отвязка, вкл/выкл, ссылка/QR), подключение нод
/// и ревизия имён (склейка дублей к каноническому списку). Токены — в вейлте QTerm.
/// </summary>
public partial class XuiWindow : Window
{
    // ── строки таблиц (биндинг — только свойства) ──

    public sealed class MonRow
    {
        public string Name { get; init; } = "";
        public string Status { get; init; } = "";
        public Brush StatusBrush { get; init; } = Brushes.Gray;
        public string Ping { get; init; } = "";
        public string Cpu { get; init; } = "";
        public string Ram { get; init; } = "";
        public string Uptime { get; init; } = "";
        public string Xray { get; init; } = "";
        public string Clients { get; init; } = "";
        public string Net { get; init; } = "";
        public string Error { get; init; } = "";
    }

    public sealed class ClientRow
    {
        public XClient Src { get; init; } = null!;
        public string Email => Src.Email;
        public string SubId => Src.SubId;
        public Brush DotBrush { get; init; } = Brushes.Gray;
        public Brush NameBrush { get; init; } = Brushes.Gainsboro;
        public string Enabled { get; init; } = "";
        public string Traffic { get; init; } = "";
        public string Expiry { get; init; } = "";
        public string[] Cells { get; init; } = Array.Empty<string>();
        public Brush[] CellBrushes { get; init; } = Array.Empty<Brush>();
    }

    public sealed class NodeRow
    {
        public XNode Src { get; init; } = null!;
        public XuiPanel? Saved { get; init; }
        public string Name => Src.Name;
        public string Address => $"{Src.Scheme}://{Src.Address}:{Src.Port}{(Src.BasePath is "/" or "" ? "" : Src.BasePath)}";
        public string Status { get; init; } = "";
        public Brush StatusBrush { get; init; } = Brushes.Gray;
        public string Enabled => Src.Enable ? "да" : "нет";
        public string Inbounds => Src.InboundCount.ToString();
        public string Clients => Src.ClientCount.ToString();
        public string SavedText => Saved is null ? "—" : "есть";
        public string Version => Src.PanelVersion;
        public string Error => Src.LastError;
    }

    private static readonly Brush Green = Frozen("#3FB950");
    private static readonly Brush Red = Frozen("#E5534B");
    private static readonly Brush Amber = Frozen("#E8B44C");
    private static readonly Brush Blue = Frozen("#4FA3E3");
    private static readonly Brush Purple = Frozen("#A371F7");

    private static Brush Frozen(string hex)
    {
        var b = (SolidColorBrush)new BrushConverter().ConvertFromString(hex)!;
        b.Freeze();
        return b;
    }

    private Brush Dim => (Brush)FindResource("DimBrush");

    private readonly VaultRepo _repo;
    private readonly XuiStore _store;
    private XuiPanel? _masterPanel;
    private XuiApi? _master;
    private List<XClient> _clients = new();
    private List<XInbound> _inbounds = new();
    private List<XNode> _nodes = new();
    private JsonObject _settings = new();
    private HashSet<string> _online = new();
    private JsonNode? _status;
    private string _seg = "monitor";
    private bool _noMaster;
    private bool _busy, _refreshing;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(10) };
    private List<(XuiApi Api, NodePlan Plan)> _revNodes = new();
    private List<MergePlan> _revMaster = new();
    private static Guid? _lastMaster;

    public XuiWindow(VaultRepo repo)
    {
        InitializeComponent();
        _repo = repo;
        _store = new XuiStore(repo);
        LoadNamesEditor();
        LoadAwgPanels();
        ShowSeg("monitor");
        LoadMasters();
        _timer.Tick += async (_, _) =>
        {
            if (IsVisible && WindowState != WindowState.Minimized && !_busy && (_seg is "monitor" or "clients" or "nodes"))
                await RefreshAsync(quiet: true);
            else if (IsVisible && WindowState != WindowState.Minimized && !_busy && _seg == "awg")
                await RefreshAwgAsync(quiet: true);
        };
        Loaded += (_, _) => _timer.Start();
        XuiReauth.Notice += OnReauthNotice;
        Closed += (_, _) => { XuiReauth.Notice -= OnReauthNotice; _timer.Stop(); _master?.Dispose(); DisposeRevision(); };
        PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Key.F5) { e.Handled = true; await RefreshAsync(); }
        };
    }

    // ── лог ──

    private void Log(string line, LogKind kind = LogKind.Info)
    {
        LogBox.AppendText((LogBox.Text.Length > 0 ? "\n" : "") + line);
        LogBox.ScrollToEnd();
    }

    private void OnReauthNotice(string line, LogKind kind) =>
        Dispatcher.BeginInvoke(() => Log(line, kind));

    private void Status(string s) => StatusText.Text = s;

    // ── главная ──

    private void LoadMasters()
    {
        var masters = _store.Panels().Where(p => p.IsMaster).ToList();
        MasterBox.ItemsSource = masters;
        var pick = masters.FirstOrDefault(p => p.Id == (_masterPanel?.Id ?? _lastMaster)) ?? masters.FirstOrDefault();
        MasterBox.SelectedItem = pick;
        _noMaster = masters.Count == 0;
        SetupView.Visibility = _noMaster && _seg is not ("awg" or "updates") ? Visibility.Visible : Visibility.Collapsed;
        if (masters.Count == 0)
        {
            Status("Нет главной панели");
            SetMaster(null);
            Dispatcher.InvokeAsync(() => SetupUrl.Focus(), DispatcherPriority.Input);
        }
    }

    /// <summary>Первая настройка прямо в окне: проверка токена → сохранение главной → загрузка.</summary>
    private async void SetupSave_Click(object sender, RoutedEventArgs e)
    {
        var p = new XuiPanel
        {
            Name = SetupName.Text.Trim().Length > 0 ? SetupName.Text.Trim() : "MSK",
            Role = "master",
            Url = SetupUrl.Text.Trim(),
            Token = SetupToken.Password.Trim(),
            VerifyTls = SetupTls.SelectedIndex == 0,
        };
        if (p.Token.Length == 0) { SetupResult.Text = "✗ нужен API-токен"; return; }
        SetupResult.Text = "проверяю…";
        try
        {
            using var api = XuiApi.For(p);
            var st = await api.StatusAsync();
            var nodes = await api.NodesAsync();
            _store.SavePanel(p);
            SetupResult.Text = "";
            SetupToken.Password = "";
            Log($"✓ главная «{p.Name}»: 3x-ui {st?["panelVersion"]?.GetValue<string>()}, узлов {nodes.Count} — сохранена в вейлт", LogKind.Ok);
            LoadMasters();
        }
        catch (XuiException ex) { SetupResult.Text = "✗ " + ex.Message; }
        catch (Exception ex) { SetupResult.Text = "✗ " + ex.Message; }
    }

    private async void Master_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (MasterBox.SelectedItem is XuiPanel p && p.Id != _masterPanel?.Id)
        {
            SetMaster(p);
            await RefreshAsync();
        }
    }

    private void SetMaster(XuiPanel? p)
    {
        _master?.Dispose();
        _master = null;
        _masterPanel = p;
        _settings = new JsonObject();
        _clients = new(); _inbounds = new(); _nodes = new(); _online = new(); _status = null;
        if (p is null) { Render(); return; }
        _lastMaster = p.Id;
        try { _master = XuiApi.For(p); }
        catch (XuiException ex) { Status(ex.Message); }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private async Task RefreshAsync(bool quiet = false)
    {
        if (_master is null || _refreshing) return;
        _refreshing = true;
        if (!quiet) Status("обновляю…");
        try
        {
            _status = await _master.StatusAsync();
            _nodes = await _master.NodesAsync();
            _inbounds = await _master.InboundsAsync();
            _clients = await _master.ClientsAsync();
            _online = await _master.OnlinesAsync();
            if (_settings.Count == 0) _settings = await _master.SettingsAsync();
            Status($"{_masterPanel?.Name}: узлов {_nodes.Count}, клиентов {_clients.Count}, онлайн {_online.Count} · {DateTime.Now:HH:mm:ss}");
            Render();
        }
        catch (XuiException ex)
        {
            Status(ex.Message);
            if (!quiet) Log("✗ " + ex.Message, LogKind.Err);
        }
        finally { _refreshing = false; }
    }

    private void Render()
    {
        RenderMonitor();
        RenderClients();
        RenderNodes();
    }

    // ── разделы ──

    private void Seg_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button b && b.Tag is string s) ShowSeg(s);
    }

    private void ShowSeg(string s)
    {
        _seg = s;
        MonList.Visibility = s == "monitor" ? Visibility.Visible : Visibility.Collapsed;
        ClientsView.Visibility = s == "clients" ? Visibility.Visible : Visibility.Collapsed;
        NodesView.Visibility = s == "nodes" ? Visibility.Visible : Visibility.Collapsed;
        NamesView.Visibility = s == "names" ? Visibility.Visible : Visibility.Collapsed;
        AwgView.Visibility = s == "awg" ? Visibility.Visible : Visibility.Collapsed;
        UpdatesView.Visibility = s == "updates" ? Visibility.Visible : Visibility.Collapsed;
        foreach (var b in new[] { SegMonitor, SegClients, SegNodes, SegNames, SegAwg, SegUpdates })
            b.SetResourceReference(BackgroundProperty, (string)b.Tag == s ? "SelBrush" : "Panel2Brush");
        // AWG и обновления живут без главной 3x-ui — карточку первой настройки там не показываем
        SetupView.Visibility = _noMaster && s is not ("awg" or "updates") ? Visibility.Visible : Visibility.Collapsed;
        if (s == "awg" && IsLoaded) _ = RefreshAwgAsync();
        if (s == "updates" && IsLoaded) _ = RefreshUpdatesAsync();
    }

    // ── форматирование ──

    private static string Bytes(double b)
    {
        string[] u = { "Б", "КБ", "МБ", "ГБ", "ТБ" };
        int i = 0;
        while (b >= 1024 && i < u.Length - 1) { b /= 1024; i++; }
        return i == 0 ? $"{b:0} {u[i]}" : $"{b:0.##} {u[i]}";
    }

    private static string Uptime(long s)
    {
        if (s <= 0) return "—";
        var t = TimeSpan.FromSeconds(s);
        return t.TotalDays >= 1 ? $"{(int)t.TotalDays} д {t.Hours} ч" : $"{t.Hours} ч {t.Minutes} мин";
    }

    private static string Expiry(long ms)
    {
        if (ms == 0) return "∞";
        if (ms < 0) return $"{-ms / 86_400_000} д. с 1-го входа";
        var d = DateTimeOffset.FromUnixTimeMilliseconds(ms).LocalDateTime;
        return d < DateTime.Now ? $"{d:dd.MM.yyyy} ⛔" : $"{d:dd.MM.yyyy}";
    }

    // ── Монитор ──

    private void RenderMonitor()
    {
        var rows = new List<MonRow>();
        if (_masterPanel is not null && _status is JsonObject st)
        {
            var mem = st["mem"] as JsonObject;
            var memPct = mem is null ? 0 : 100.0 * J.Long(mem, "current") / Math.Max(1, J.Long(mem, "total"));
            var xray = st["xray"] as JsonObject;
            var net = st["netIO"] as JsonObject;
            var localIb = _inbounds.Where(i => i.NodeId is null).Select(i => i.Id).ToHashSet();
            var localClients = _clients.Where(c => c.InboundIds.Any(localIb.Contains)).ToList();
            var running = xray is null || J.Str(xray, "state") == "running";
            rows.Add(new MonRow
            {
                Name = _masterPanel.Name + " (главная)",
                Status = running ? "online" : "xray: " + J.Str(xray!, "state"),
                StatusBrush = running ? Green : Amber,
                Ping = "—",
                Cpu = $"{J.Dbl(st, "cpu"):0}%",
                Ram = $"{memPct:0}%",
                Uptime = Uptime(J.Long(st, "uptime")),
                Xray = xray is null ? "" : J.Str(xray, "version"),
                Clients = $"{localClients.Count(c => _online.Contains(c.Email))} / {localClients.Count}",
                Net = net is null ? "" : $"{Bytes(J.Long(net, "up"))}/с ↑  {Bytes(J.Long(net, "down"))}/с ↓",
                Error = xray is null ? "" : J.Str(xray, "errorMsg"),
            });
        }
        foreach (var n in _nodes.OrderBy(n => n.Name, StringComparer.OrdinalIgnoreCase))
        {
            var on = n.Status == "online";
            rows.Add(new MonRow
            {
                Name = n.Name,
                Status = !n.Enable ? "выключен" : n.Status,
                StatusBrush = !n.Enable ? Dim : on ? (n.XrayState is "" or "running" ? Green : Amber) : Red,
                Ping = on ? $"{n.LatencyMs} мс" : "—",
                Cpu = on ? $"{n.CpuPct:0}%" : "—",
                Ram = on ? $"{n.MemPct:0}%" : "—",
                Uptime = on ? Uptime(n.UptimeSecs) : "—",
                Xray = n.XrayVersion,
                Clients = $"{n.OnlineCount} / {n.ClientCount}",
                Net = on ? $"{Bytes(n.NetUp)}/с ↑  {Bytes(n.NetDown)}/с ↓" : "",
                Error = n.LastError,
            });
        }
        MonList.ItemsSource = rows;
    }

    // ── Клиенты ──

    private List<(string Title, int? NodeId)> Servers() =>
        new List<(string, int?)> { (_masterPanel?.Name ?? "главная", null) }
            .Concat(_nodes.OrderBy(n => n.Name, StringComparer.OrdinalIgnoreCase).Select(n => (n.Name, (int?)n.Id)))
            .ToList();

    private static DataTemplate CellTemplate(string textPath, string brushPath)
    {
        var f = new FrameworkElementFactory(typeof(TextBlock));
        f.SetBinding(TextBlock.TextProperty, new Binding(textPath));
        f.SetBinding(TextBlock.ForegroundProperty, new Binding(brushPath));
        return new DataTemplate { VisualTree = f };
    }

    private int _gridSig = -1;

    private void BuildClientGrid(List<(string Title, int? NodeId)> servers)
    {
        var sig = string.Join("|", servers.Select(s => s.Title)).GetHashCode();
        if (sig == _gridSig && ClientList.View is GridView) return;
        _gridSig = sig;
        var gv = new GridView();
        gv.Columns.Add(new GridViewColumn { Header = "", Width = 30, CellTemplate = CellTemplateDot() });
        gv.Columns.Add(new GridViewColumn { Header = "Клиент", Width = 170, CellTemplate = CellTemplate("Email", "NameBrush") });
        gv.Columns.Add(new GridViewColumn { Header = "Вкл", Width = 50, DisplayMemberBinding = new Binding("Enabled") });
        for (int i = 0; i < servers.Count; i++)
            gv.Columns.Add(new GridViewColumn
            {
                Header = servers[i].Title, Width = Math.Max(70, servers[i].Title.Length * 9 + 24),
                CellTemplate = CellTemplate($"Cells[{i}]", $"CellBrushes[{i}]"),
            });
        gv.Columns.Add(new GridViewColumn { Header = "Трафик", Width = 150, DisplayMemberBinding = new Binding("Traffic") });
        gv.Columns.Add(new GridViewColumn { Header = "Срок", Width = 130, DisplayMemberBinding = new Binding("Expiry") });
        gv.Columns.Add(new GridViewColumn { Header = "ID подписки", Width = 170, DisplayMemberBinding = new Binding("SubId") });
        ClientList.View = gv;
    }

    private static DataTemplate CellTemplateDot()
    {
        var f = new FrameworkElementFactory(typeof(TextBlock));
        f.SetValue(TextBlock.TextProperty, "●");
        f.SetBinding(TextBlock.ForegroundProperty, new Binding("DotBrush"));
        return new DataTemplate { VisualTree = f };
    }

    private void RenderClients()
    {
        var servers = Servers();
        BuildClientGrid(servers);
        var ibById = _inbounds.ToDictionary(i => i.Id);
        var filter = SearchBox.Text.Trim();
        var selected = ClientList.SelectedItems.OfType<ClientRow>().Select(r => r.Email).ToHashSet(StringComparer.Ordinal);
        var rows = new List<ClientRow>();
        foreach (var c in _clients.OrderBy(c => c.Email, StringComparer.OrdinalIgnoreCase))
        {
            if (filter.Length > 0 && !c.Email.Contains(filter, StringComparison.OrdinalIgnoreCase) &&
                !c.SubId.Contains(filter, StringComparison.OrdinalIgnoreCase)) continue;
            var cells = new string[servers.Count];
            var brushes = new Brush[servers.Count];
            for (int i = 0; i < servers.Count; i++)
            {
                var ibs = c.InboundIds.Where(ibById.ContainsKey).Select(id => ibById[id])
                                      .Where(ib => ib.NodeId == servers[i].NodeId).ToList();
                var v = ibs.Any(ib => !ib.IsHys);
                var h = ibs.Any(ib => ib.IsHys);
                cells[i] = v && h ? "V · H" : v ? "V" : h ? "H" : "—";
                brushes[i] = v && h ? Green : v ? Blue : h ? Purple : Dim;
            }
            var used = c.Up + c.Down;
            var (pv, ph) = XuiOps.Protos(c.InboundIds, ibById);
            rows.Add(new ClientRow
            {
                Src = c,
                NameBrush = pv && ph ? Green : (Brush)FindResource("FgBrush"),
                DotBrush = !c.Enable ? Red : _online.Contains(c.Email) ? Green : Dim,
                Enabled = c.Enable ? "да" : "нет",
                Traffic = Bytes(used) + (c.TotalBytes > 0 ? " / " + Bytes(c.TotalBytes) : ""),
                Expiry = Expiry(c.ExpiryTime),
                Cells = cells,
                CellBrushes = brushes,
            });
        }
        ClientList.ItemsSource = rows;
        foreach (var r in rows.Where(r => selected.Contains(r.Email))) ClientList.SelectedItems.Add(r);
    }

    private void Search_Changed(object sender, TextChangedEventArgs e) => RenderClients();

    private List<XClient> SelectedClients() =>
        ClientList.SelectedItems.OfType<ClientRow>().Select(r => r.Src).ToList();

    private XClient? OneClient()
    {
        var s = SelectedClients();
        if (s.Count == 1) return s[0];
        XuiDialog.Info(this, "Выбери одного клиента");
        return null;
    }

    private NameUnifier Unifier() => new(_store.Names());

    /// <summary>Обёртка операций: один за раз, ошибки — в лог, после — обновление.</summary>
    private async Task RunOp(string title, Func<Task> op)
    {
        if (_busy) { Log("! дождись окончания текущей операции", LogKind.Warn); return; }
        if (_master is null) { XuiDialog.Info(this, "Сначала выбери главную панель"); return; }
        _busy = true;
        Cursor = Cursors.AppStarting;
        Log($"━━ {title}", LogKind.Head);
        try { await op(); }
        catch (XuiException ex) { Log("✗ " + ex.Message, LogKind.Err); }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); }
        finally
        {
            _busy = false;
            Cursor = null;
            await RefreshAsync(quiet: true);
        }
    }

    private async void ClientNew_Click(object sender, RoutedEventArgs e)
    {
        if (_master is null) { XuiDialog.Info(this, "Сначала подключи главную панель"); return; }
        var name = InputDialog.Ask(this, "Имя клиента (приведётся к списку имён):");
        if (name is null) return;
        var u = Unifier();
        var toks = XuiOps.StripTokens(_inbounds, _nodes);
        var key = u.Analyze(name, toks).Key;
        if (_clients.Any(c => u.Analyze(c.Email, toks).Key == key))
        {
            XuiDialog.Info(this, $"Клиент «{NameUnifier.BaseText(name)}» уже есть — привяжи его к нужным серверам через ПКМ или «Синхронизировать…»");
            return;
        }
        var choice = XuiDialog.Show(this,
            $"Новый клиент «{NameUnifier.BaseText(name)}». Куда добавить?\n\nИмя получит индекс по протоколам: без индекса — VLESS, -HYS — Hysteria, -SYNC — оба.",
            "Новый клиент", "Все серверы", "Только главная", "Отмена");
        if (choice is < 0 or 2) return;
        var ids = _inbounds.Where(i => i.MultiUser && i.Enable && (choice == 0 || i.NodeId is null))
                           .Select(i => i.Id).ToList();
        if (ids.Count == 0) { XuiDialog.Info(this, "Нет подходящих входящих"); return; }
        var (pv, ph) = XuiOps.Protos(ids, _inbounds.ToDictionary(i => i.Id));
        var display = u.DisplayFor(key, new[] { name }, name, pv, ph);
        await RunOp($"Новый клиент {display}", async () =>
        {
            await _master.AddClientAsync(display, ids);
            Log($"  ✓ {display}: входящих {ids.Count}", LogKind.Ok);
        });
    }

    private string? LinkOf(XClient c, bool clash = false)
    {
        if (_master is null || c.SubId.Length == 0) return null;
        return XuiApi.SubLink(_settings, _master.Url, c.SubId, clash);
    }

    private void ClientLink_Click(object sender, RoutedEventArgs e)
    {
        if (OneClient() is not { } c) return;
        var link = LinkOf(c);
        if (link is null) { XuiDialog.Info(this, "Подписка выключена в настройках панели или у клиента нет ID подписки"); return; }
        Clipboard.SetText(link);
        Log($"  ✓ ссылка подписки {c.Email} скопирована: {link}", LogKind.Ok);
    }

    private void ClientList_DoubleClick(object sender, MouseButtonEventArgs e) => ClientQr_Click(sender, e);

    private void ClientQr_Click(object sender, RoutedEventArgs e)
    {
        if (OneClient() is not { } c) return;
        var link = LinkOf(c);
        if (link is null) { XuiDialog.Info(this, "Подписка выключена в настройках панели или у клиента нет ID подписки"); return; }
        XuiQrWindow.Show(this, c.Email, link, LinkOf(c, clash: true));
    }

    private async void ClientToggle_Click(object sender, RoutedEventArgs e)
    {
        var sel = SelectedClients();
        if (sel.Count == 0 || _master is null) return;
        var target = !sel.All(c => c.Enable);
        await RunOp(target ? "Включить" : "Выключить", async () =>
        {
            foreach (var c in sel)
            {
                await _master.UpdateClientAsync(c.Email, XuiApi.ClientPayload(c, enable: target));
                Log($"  ✓ {c.Email}: {(target ? "вкл" : "выкл")}", LogKind.Ok);
            }
        });
    }

    private async void ClientDelete_Click(object sender, RoutedEventArgs e)
    {
        var sel = SelectedClients();
        if (sel.Count == 0 || _master is null) return;
        if (!XuiDialog.Confirm(this, $"Удалить со ВСЕХ серверов: {string.Join(", ", sel.Select(c => c.Email))}?",
                "Удаление", "Удалить")) return;
        await RunOp("Удаление", async () =>
        {
            foreach (var c in sel)
            {
                await _master.DeleteClientAsync(c.Email);
                Log($"  ✓ {c.Email} удалён", LogKind.Ok);
            }
        });
    }

    private void ClientList_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var menu = ClientList.ContextMenu!;
        menu.Items.Clear();
        var sel = SelectedClients();
        if (sel.Count == 0 || _master is null) { e.Handled = true; return; }
        var servers = Servers();

        var attach = new MenuItem { Header = "Привязать к" };
        var detach = new MenuItem { Header = "Отвязать от" };
        foreach (var (title, nodeId) in servers)
        {
            var ibs = _inbounds.Where(i => i.NodeId == nodeId && i.MultiUser).ToList();
            if (ibs.Count == 0) continue;
            var a = new MenuItem { Header = title };
            var aAll = new MenuItem { Header = "все входящие" };
            aAll.Click += (_, _) => _ = Bind(sel, ibs.Select(i => i.Id).ToList(), true, title);
            a.Items.Add(aAll);
            a.Items.Add(new Separator());
            foreach (var ib in ibs)
            {
                var it = new MenuItem { Header = $"{ib.Remark}  ({ib.Protocol}:{ib.Port})" };
                it.Click += (_, _) => _ = Bind(sel, new List<int> { ib.Id }, true, ib.Remark);
                a.Items.Add(it);
            }
            attach.Items.Add(a);

            var bound = ibs.Where(i => sel.Any(c => c.InboundIds.Contains(i.Id))).ToList();
            if (bound.Count == 0) continue;
            var d = new MenuItem { Header = title };
            var dAll = new MenuItem { Header = "все входящие" };
            dAll.Click += (_, _) => _ = Bind(sel, bound.Select(i => i.Id).ToList(), false, title);
            d.Items.Add(dAll);
            d.Items.Add(new Separator());
            foreach (var ib in bound)
            {
                var it = new MenuItem { Header = $"{ib.Remark}  ({ib.Protocol}:{ib.Port})" };
                it.Click += (_, _) => _ = Bind(sel, new List<int> { ib.Id }, false, ib.Remark);
                d.Items.Add(it);
            }
            detach.Items.Add(d);
        }
        var sync = new MenuItem { Header = "Синхронизировать на все серверы…" };
        sync.Click += async (_, _) => await RunSync("Синхронизация клиентов",
            $"{string.Join(", ", sel.Select(c => c.Email))} → все серверы", SyncItems(sel, null));
        menu.Items.Add(sync);
        menu.Items.Add(attach);
        if (detach.Items.Count > 0) menu.Items.Add(detach);
        menu.Items.Add(new Separator());

        var link = new MenuItem { Header = "Скопировать ссылку подписки", IsEnabled = sel.Count == 1 };
        link.Click += (s, a) => ClientLink_Click(s, a);
        menu.Items.Add(link);
        if (sel.Count == 1 && LinkOf(sel[0], clash: true) is { } clashLink)
        {
            var cl = new MenuItem { Header = "Скопировать ссылку Clash / Mihomo" };
            cl.Click += (_, _) => { Clipboard.SetText(clashLink); Log("  ✓ ссылка Mihomo скопирована: " + clashLink, LogKind.Ok); };
            menu.Items.Add(cl);
        }
        var qr = new MenuItem { Header = "QR-код", IsEnabled = sel.Count == 1 };
        qr.Click += (s, a) => ClientQr_Click(s, a);
        menu.Items.Add(qr);
        menu.Items.Add(new Separator());

        var rename = new MenuItem { Header = "Переименовать…", IsEnabled = sel.Count == 1 };
        rename.Click += async (_, _) =>
        {
            var c = sel[0];
            var nn = InputDialog.Ask(this, "Новое имя:", c.Email);
            if (nn is null || nn == c.Email) return;
            await RunOp($"Переименовать {c.Email}", async () =>
            {
                await _master!.UpdateClientAsync(c.Email, XuiApi.ClientPayload(c, nn));
                Log($"  ✓ {c.Email} → {nn}", LogKind.Ok);
            });
        };
        menu.Items.Add(rename);
        var regen = new MenuItem { Header = "Новый ID подписки…", IsEnabled = sel.Count == 1 };
        regen.Click += async (_, _) =>
        {
            var c = sel[0];
            if (!XuiDialog.Confirm(this, $"Перевыпустить ID подписки {c.Email}? Старая ссылка перестанет работать — устройство надо будет переподписать.",
                    "Новый ID подписки", "Перевыпустить")) return;
            var sid = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
            await RunOp($"Новый ID подписки {c.Email}", async () =>
            {
                await _master!.UpdateClientAsync(c.Email, XuiApi.ClientPayload(c, subId: sid));
                Log($"  ✓ {c.Email}: {sid}", LogKind.Ok);
            });
        };
        menu.Items.Add(regen);
        var toggle = new MenuItem { Header = sel.All(c => c.Enable) ? "Выключить" : "Включить" };
        toggle.Click += (s, a) => ClientToggle_Click(s, a);
        menu.Items.Add(toggle);
        var del = new MenuItem { Header = "Удалить…" };
        del.Click += (s, a) => ClientDelete_Click(s, a);
        menu.Items.Add(del);
    }

    // ── синхронизация: одинаковые клиенты на всех серверах ──

    private string ServerName(int? nodeId) =>
        nodeId is int n ? (_nodes.FirstOrDefault(x => x.Id == n)?.Name ?? "узел " + n) : (_masterPanel?.Name ?? "главная");

    /// <summary>Строки «клиент × входящий», где клиента нет. nodeFilter — только эти серверы (null = все).</summary>
    private List<PlanItem> SyncItems(IEnumerable<XClient> clients, ICollection<int?>? nodeFilter)
    {
        var targets = _inbounds.Where(i => i.MultiUser && i.Enable && (nodeFilter is null || nodeFilter.Contains(i.NodeId)))
                               .OrderBy(i => i.NodeId ?? 0).ThenBy(i => i.Remark, StringComparer.OrdinalIgnoreCase).ToList();
        var u = Unifier();
        var toks = XuiOps.StripTokens(_inbounds, _nodes);
        bool canon(string email) => u.IsCanonical(u.Analyze(email, toks).Key);
        var items = new List<PlanItem>();
        var ibAll = _inbounds.ToDictionary(i => i.Id);
        foreach (var c in clients.OrderBy(c => canon(c.Email) ? 0 : 1).ThenBy(c => c.Email, StringComparer.OrdinalIgnoreCase))
            foreach (var ib in targets.Where(ib => !c.InboundIds.Contains(ib.Id)))
                items.Add(new PlanItem
                {
                    Merged = XuiOps.Protos(c.InboundIds, ibAll) is (true, true),
                    Scope = ServerName(ib.NodeId), Kind = "attach", Key = c.Email + "|" + ib.Id,
                    Email = c.Email, Ids = new List<int> { ib.Id },
                    Result = c.Email, From = $"{ib.Remark}  ({ib.Protocol}:{ib.Port})",
                    Note = !c.Enable ? "клиент выключен" : canon(c.Email) ? "те же ключи и та же подписка" : "не из списка имён — по умолчанию не отмечено",
                    Apply = c.Enable && canon(c.Email),
                });
        return items;
    }

    private static readonly string Sep = "  (";

    private async Task RunSync(string title, string summary, List<PlanItem> items)
    {
        if (items.Count == 0)
        {
            XuiDialog.Info(this, "Синхронизировать нечего: выбранные клиенты уже есть на всех входящих выбранных серверов.");
            return;
        }
        var dlg = new XuiPlanWindow(title, summary,
            "Имена клиентов не меняются (кроме индекса -HYS/-SYNC по протоколам). Добавляется только отмеченное; удаления нет.",
            items, resultHeader: "Клиент", fromHeader: "Куда добавить (входящий)") { Owner = this };
        if (dlg.ShowDialog() != true) return;
        await RunOp(title, async () =>
        {
            foreach (var g in items.Where(i => i.Apply).GroupBy(i => i.Email))
            {
                var ids = g.SelectMany(i => i.Ids).Distinct().ToList();
                await _master!.AttachAsync(g.Key, ids);
                var where = string.Join(", ", g.Select(i => i.Scope + ":" + i.From.Split(Sep)[0]));
                Log($"  ✓ {g.Key} → {where}", LogKind.Ok);
            }
            await new XuiOps(Unifier(), Log).NormalizeIndexAsync(_master!, items.Where(i => i.Apply).Select(i => i.Email).Distinct());
        });
    }

    private async void ClientSync_Click(object sender, RoutedEventArgs e)
    {
        if (_master is null) { XuiDialog.Info(this, "Сначала подключи главную панель"); return; }
        var sel = SelectedClients();
        var who = sel.Count > 0 ? sel : _clients;
        await RunSync("Синхронизация клиентов",
            sel.Count > 0 ? $"Выделенные клиенты ({sel.Count}) → все серверы" : $"Все клиенты ({who.Count}) → все серверы",
            SyncItems(who, null));
    }

    private async void NodeSync_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } r) return;
        await RunSync("Выровнять клиентов · " + r.Name, $"Все клиенты главной → узел «{r.Name}»",
            SyncItems(_clients, new List<int?> { r.Src.Id }));
    }

    private Task Bind(List<XClient> sel, List<int> ids, bool attach, string what) =>
        RunOp($"{(attach ? "Привязать к" : "Отвязать от")} {what}", async () =>
        {
            foreach (var c in sel)
            {
                var need = attach ? ids.Where(i => !c.InboundIds.Contains(i)).ToList()
                                  : ids.Where(i => c.InboundIds.Contains(i)).ToList();
                if (need.Count == 0) continue;
                if (attach) await _master!.AttachAsync(c.Email, need);
                else await _master!.DetachAsync(c.Email, need);
                Log($"  ✓ {c.Email}: {need.Count} вх.", LogKind.Ok);
            }
            await new XuiOps(Unifier(), Log).NormalizeIndexAsync(_master!, sel.Select(c => c.Email));
        });

    // ── Узлы ──

    private XuiPanel? SavedFor(XNode n) =>
        _store.Panels().FirstOrDefault(p => p.IsXuiNode && Safe(() => PanelUrl.Parse(p.Url).SameAs(n.Address, n.Port, n.BasePath)));

    private static bool Safe(Func<bool> f)
    {
        try { return f(); } catch { return false; }
    }

    private void RenderNodes()
    {
        var selId = (NodeList.SelectedItem as NodeRow)?.Src.Id;
        var rows = _nodes.OrderBy(n => n.Name, StringComparer.OrdinalIgnoreCase).Select(n => new NodeRow
        {
            Src = n,
            Saved = SavedFor(n),
            Status = !n.Enable ? "выключен" : n.Status,
            StatusBrush = !n.Enable ? Dim : n.Status == "online" ? Green : Red,
        }).ToList();
        NodeList.ItemsSource = rows;
        NodeList.SelectedItem = rows.FirstOrDefault(r => r.Src.Id == selId);
    }

    private NodeRow? SelectedNode()
    {
        if (NodeList.SelectedItem is NodeRow r) return r;
        XuiDialog.Info(this, "Выбери узел в списке");
        return null;
    }

    private async void NodeConnect_Click(object sender, RoutedEventArgs e)
    {
        if (_master is null) { XuiDialog.Info(this, "Сначала выбери главную панель"); return; }
        var dlg = new XuiConnectDialog(_store.Panels().Where(p => p.IsXuiNode).ToList()) { Owner = this };
        if (dlg.ShowDialog() != true) return;
        await ConnectOrRevise(dlg.Url, dlg.Token, dlg.VerifyTls, dlg.NodeName, dlg.AttachOthers, dlg.SaveToken);
    }

    private async void NodeRevise_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } r) return;
        if (r.Saved is null)
        {
            XuiDialog.Info(this, "Для ревизии нужен токен ноды — «Токен ноды…»");
            return;
        }
        await ConnectOrRevise(r.Saved.Url, r.Saved.Token, r.Saved.VerifyTls, r.Name, attachOthers: false, save: false);
    }

    private void NodeList_DoubleClick(object sender, MouseButtonEventArgs e) => NodeRevise_Click(sender, e);

    private async Task ConnectOrRevise(string url, string token, bool verify, string? name, bool attachOthers, bool save)
    {
        await RunOp("Нода " + url, async () =>
        {
            using var node = new XuiApi("нода", url, token, verify);
            var ops = new XuiOps(Unifier(), Log);
            var plan = await ops.PlanNodeAsync(_master!, node, token, name, attachOthers);
            if (save) SaveNodePanel(plan.Name, url, token, verify);
            var items = ops.MergeItems(plan.MasterMerge, "главная", _inbounds, _nodes, owner: plan)
                .Concat(ops.NodeItems(plan)).ToList();
            if (items.Count == 0 && plan.Existing is not null)
            {
                Log($"  ✓ нода «{plan.Name}»: всё в порядке, менять нечего", LogKind.Ok);
                return;
            }
            var summary = plan.Existing is null
                ? $"Новая нода «{plan.Name}» ({plan.Node.Url.Host}:{plan.Node.Url.Port}) — будет добавлена на главную «{_masterPanel?.Name}»"
                : $"Нода «{plan.Name}» уже на главной — привести клиентов к единым именам";
            var dlg = new XuiPlanWindow("Нода " + plan.Name, summary,
                "Перед изменениями — бэкапы баз главной и ноды (" + XuiOps.BackupDir + ")",
                items, forceApply: plan.Existing is null) { Owner = this };
            if (dlg.ShowDialog() != true) { Log("  остановлено", LogKind.Warn); return; }
            XuiOps.ApplySelection(plan, items);
            await ops.ApplyNodeAsync(_master!, plan);
            if (plan.Existing is null)
                Log("  Введённый токен ноды главной больше не нужен (у неё свой node-sync)." +
                    (save ? " Он сохранён в QTerm для ревизии." : " Можешь удалить его в панели ноды."), LogKind.Dim);
        });
    }

    private void SaveNodePanel(string name, string url, string token, bool verify)
    {
        var pu = PanelUrl.Parse(url);
        var p = _store.Panels().FirstOrDefault(x => x.IsXuiNode && Safe(() => PanelUrl.Parse(x.Url) == pu))
                ?? new XuiPanel { Role = "node" };
        p.Name = name;
        p.Url = url;
        p.Token = token;
        p.VerifyTls = verify;
        _store.SavePanel(p);
        Log($"  ✓ токен ноды «{name}» сохранён в QTerm", LogKind.Ok);
    }

    private async void NodeToggle_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } r) return;
        await RunOp($"Узел {r.Name}: {(r.Src.Enable ? "выключить" : "включить")}", async () =>
        {
            await _master!.SetNodeEnableAsync(r.Src.Id, !r.Src.Enable);
            Log("  ✓ готово", LogKind.Ok);
        });
    }

    private async void NodeProbe_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } r) return;
        await RunOp($"Проверка {r.Name}", async () =>
        {
            await _master!.ProbeNodeAsync(r.Src.Id);
            Log("  ✓ узел отвечает", LogKind.Ok);
        });
    }

    private void NodeToken_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedNode() is not { } r) return;
        var url = r.Saved?.Url ?? r.Address;
        var dlg = new XuiConnectDialog(new List<XuiPanel>(), url, r.Name, tokenOnly: true) { Owner = this };
        if (dlg.ShowDialog() != true) return;
        _ = RunOp($"Токен {r.Name}", async () =>
        {
            using var node = new XuiApi(r.Name, dlg.Url, dlg.Token, dlg.VerifyTls);
            await node.StatusAsync();
            SaveNodePanel(r.Name, dlg.Url, dlg.Token, dlg.VerifyTls);
        });
    }

    // ── Панели ──

    private async void Panels_Click(object sender, RoutedEventArgs e)
    {
        new XuiPanelsWindow(_store) { Owner = this }.ShowDialog();
        await ReloadPanelsAsync();
    }

    /// <summary>Панели поменялись (окно панелей, «Нода из выделения», синк) — перечитать всё.</summary>
    private async Task ReloadPanelsAsync()
    {
        var cur = _masterPanel?.Id;
        var fresh = cur is Guid g ? _store.PanelById(g) : null;
        if (fresh is not null && (fresh.Url != _masterPanel!.Url || fresh.Token != _masterPanel.Token || fresh.VerifyTls != _masterPanel.VerifyTls))
            SetMaster(fresh);
        _masterPanel = fresh ?? _masterPanel;
        LoadMasters();
        RenderNodes();
        LoadAwgPanels();
        if (_seg == "awg") await RefreshAwgAsync();
        else await RefreshAsync();
    }

    // ── Ревизия имён ──

    private void LoadNamesEditor()
    {
        var cfg = _store.Names();
        NamesBox.Text = string.Join("\n", cfg.Lines);
    }

    private XuiNamesConfig NamesFromEditor() => new()
    {
        Lines = NamesBox.Text.Replace("\r", "").Split('\n').Select(l => l.TrimEnd()).Where(l => l.Length > 0).ToList(),
    };

    private void NamesSave_Click(object sender, RoutedEventArgs e)
    {
        _store.SaveNames(NamesFromEditor());
        Log("✓ список имён сохранён (уедет синком)", LogKind.Ok);
    }

    private void NamesDefault_Click(object sender, RoutedEventArgs e)
    {
        NamesBox.Text = string.Join("\n", XuiNamesConfig.DefaultNames);
    }

    private void DisposeRevision()
    {
        foreach (var (api, _) in _revNodes) api.Dispose();
        _revNodes.Clear();
        _revMaster.Clear();
    }

    /// <summary>Переезд на сдвоенных: записи одного устройства → одна (NAME-SYNC), и она — на все
    /// входящие VLESS + Hysteria всех серверов. Только клиенты из списка имён; план с галками.</summary>
    private async void Migrate_Click(object sender, RoutedEventArgs e)
    {
        if (_master is null) { XuiDialog.Info(this, "Сначала подключи главную панель"); return; }
        _store.SaveNames(NamesFromEditor());
        await RunOp("Переезд на SYNC", async () =>
        {
            var u = Unifier();
            var ops = new XuiOps(u, Log);
            var clients = await _master.ClientsAsync();
            var inbounds = await _master.InboundsAsync();
            var nodes = await _master.NodesAsync();
            var ibById = inbounds.ToDictionary(i => i.Id);
            var toks = XuiOps.StripTokens(inbounds, nodes);
            var nb = nodes.ToDictionary(n => n.Id);
            string Srv(int? id) => id is int n ? (nb.TryGetValue(n, out var x) ? x.Name : "узел " + n) : (_masterPanel?.Name ?? "главная");

            var merges = ops.PlanMerge(clients, inbounds, nodes);
            var items = ops.MergeItems(merges, _masterPanel?.Name ?? "главная", inbounds, nodes);
            var targets = inbounds.Where(i => i.MultiUser && i.Enable).OrderBy(i => i.NodeId ?? 0)
                                  .ThenBy(i => i.Remark, StringComparer.OrdinalIgnoreCase).ToList();
            var groups = clients.GroupBy(c => u.Analyze(c.Email, toks).Key).Where(g => u.IsCanonical(g.Key))
                                .OrderBy(g => g.Key, StringComparer.Ordinal);
            foreach (var g in groups)
            {
                var union = g.SelectMany(c => c.InboundIds).ToHashSet();
                var merged = XuiOps.Protos(union, ibById) is (true, true) && g.Count() == 1;
                var final = NameUnifier.WithIndex(u.Canon[g.Key], true, true);
                foreach (var ib in targets.Where(ib => !union.Contains(ib.Id)))
                    items.Add(new PlanItem
                    {
                        Scope = Srv(ib.NodeId), Kind = "attach", Key = g.Key + "|" + ib.Id, ClientKey = g.Key,
                        Ids = new List<int> { ib.Id }, Merged = merged,
                        Result = final, From = $"{ib.Remark}  ({ib.Protocol}:{ib.Port})",
                        Note = "те же ключи и та же подписка", Apply = true,
                    });
            }
            if (items.Count == 0) { Log("  ✓ все клиенты из списка уже сдвоенные и есть на всех серверах", LogKind.Ok); return; }

            var dlg = new XuiPlanWindow("Переезд на SYNC",
                $"Клиенты из списка имён → одна запись NAME-SYNC на всех входящих VLESS и Hysteria (главная «{_masterPanel?.Name}» и узлы)",
                "Порядок: бэкап главной → склейка → добавление на входящие → индекс в имени. Ключи и ID подписки сохраняются.",
                items, resultHeader: "Клиент (станет)", fromHeader: "Записи / куда добавить") { Owner = this };
            if (dlg.ShowDialog() != true) { Log("  остановлено", LogKind.Warn); return; }

            Log("  ✓ бэкап главной → " + await ops.BackupAsync(_master), LogKind.Ok);
            var approvedMerge = items.Where(i => i.Kind == "merge" && i.Apply).Select(i => i.Key).ToHashSet(StringComparer.Ordinal);
            if (approvedMerge.Count > 0)
            {
                var fresh = ops.PlanMerge(await _master.ClientsAsync(), await _master.InboundsAsync(), await _master.NodesAsync())
                    .Where(m => approvedMerge.Contains(m.Key)).ToList();
                XuiOps.ApplyOverrides(fresh, XuiOps.Overrides(items));
                await ops.ApplyMergeAsync(_master, fresh);
            }
            // после склейки клиента ищем по ключу имени — имя могло поменяться
            var now = await _master.ClientsAsync();
            var byKey = new Dictionary<string, XClient>(StringComparer.Ordinal);
            foreach (var c in now) byKey.TryAdd(u.Analyze(c.Email, toks).Key, c);
            var touched = new List<string>();
            foreach (var g in items.Where(i => i.Kind == "attach" && i.Apply).GroupBy(i => i.ClientKey))
            {
                if (!byKey.TryGetValue(g.Key, out var c)) { Log($"  ✗ не нашёл клиента для {g.Key}", LogKind.Err); continue; }
                var ids = g.SelectMany(i => i.Ids).Where(i => !c.InboundIds.Contains(i)).Distinct().ToList();
                if (ids.Count == 0) continue;
                try
                {
                    await _master.AttachAsync(c.Email, ids);
                    Log($"  ✓ {c.Email} → +{ids.Count} вх.", LogKind.Ok);
                    touched.Add(c.Email);
                }
                catch (XuiException ex) { Log($"  ✗ {c.Email}: {ex.Message}", LogKind.Err); }
            }
            await ops.NormalizeIndexAsync(_master, touched.Concat(byKey.Values.Select(c => c.Email)).Distinct());
        });
    }

    private async void Analyze_Click(object sender, RoutedEventArgs e)
    {
        if (_master is null) { XuiDialog.Info(this, "Сначала выбери главную панель"); return; }
        _store.SaveNames(NamesFromEditor());
        DisposeRevision();
        var items = new List<PlanItem>();
        var sb = new StringBuilder();
        await RunOp("Ревизия имён", async () =>
        {
            var ops = new XuiOps(Unifier(), Log);
            var inbounds = await _master.InboundsAsync();
            var nodes = await _master.NodesAsync();
            _revMaster = ops.PlanMerge(await _master.ClientsAsync(), inbounds, nodes);
            items.AddRange(ops.MergeItems(_revMaster, _masterPanel?.Name ?? "главная", inbounds, nodes));
            foreach (var n in nodes.OrderBy(n => n.Name, StringComparer.OrdinalIgnoreCase))
            {
                var saved = SavedFor(n);
                if (saved is null) { sb.AppendLine($"«{n.Name}»: токен ноды не сохранён — дубли на самой ноде не проверялись (Узлы → Токен ноды…)"); continue; }
                var api = new XuiApi(n.Name, saved.Url, saved.Token, saved.VerifyTls);
                try
                {
                    var plan = await ops.PlanNodeAsync(_master, api, saved.Token, n.Name, attachOthers: false);
                    plan.MasterMerge.Clear(); // главная — выше
                    plan.Others.Clear();      // ревизия ничего не привязывает
                    var ni = ops.NodeItems(plan);
                    if (ni.Count > 0) { _revNodes.Add((api, plan)); items.AddRange(ni); }
                    else api.Dispose();
                }
                catch (XuiException ex)
                {
                    api.Dispose();
                    sb.AppendLine($"«{n.Name}»: {ex.Message}");
                }
            }
            if (items.Count == 0) { Log("  ✓ всё уже в порядке", LogKind.Ok); return; }

            var dlg = new XuiPlanWindow("Ревизия имён", $"Главная «{_masterPanel?.Name}» и ноды с сохранённым токеном",
                (sb.Length > 0 ? sb.ToString().TrimEnd() + "\n" : "") + "Перед изменениями — бэкапы баз (" + XuiOps.BackupDir + ")",
                items) { Owner = this };
            if (dlg.ShowDialog() != true) { Log("  остановлено", LogKind.Warn); return; }

            var approved = items.Where(i => i.Owner is null && i.Apply).Select(i => i.Key).ToHashSet(StringComparer.Ordinal);
            if (approved.Count > 0)
            {
                Log("  ✓ бэкап главной → " + await ops.BackupAsync(_master), LogKind.Ok);
                // пересчёт: между анализом и применением могло поменяться; делаем только отмеченное
                var fresh = ops.PlanMerge(await _master.ClientsAsync(), await _master.InboundsAsync(), await _master.NodesAsync())
                    .Where(m => approved.Contains(m.Key)).ToList();
                XuiOps.ApplyOverrides(fresh, XuiOps.Overrides(items.Where(i => i.Owner is null)));
                await ops.ApplyMergeAsync(_master, fresh);
            }
            foreach (var (_, plan) in _revNodes)
            {
                XuiOps.ApplySelection(plan, items);
                if (plan.Replace.Count > 0 || plan.ApprovedKeep.Count > 0) await ops.ApplyNodeAsync(_master, plan);
            }
            PlanBox.Text = string.Join("\n", items.Select(i => i.AsText)) + (sb.Length > 0 ? "\n\n" + sb : "");
        });
        DisposeRevision();
    }
}

/// <summary>QR ссылки подписки (+ Mihomo, если включена).</summary>
public static class XuiQrWindow
{
    public static void Show(Window owner, string title, string link, string? clashLink)
    {
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(QrImage(link));
        panel.Children.Add(LinkBox(link));
        if (clashLink is not null)
        {
            panel.Children.Add(new TextBlock { Text = "Clash / Mihomo (Кинетик):", Margin = new Thickness(0, 12, 0, 4) });
            panel.Children.Add(LinkBox(clashLink));
        }
        var w = new Window
        {
            Title = "Подписка · " + title, Owner = owner, Content = panel,
            SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        w.SetResourceReference(Window.BackgroundProperty, "BgBrush");
        w.SetResourceReference(Window.ForegroundProperty, "FgBrush");
        w.ShowDialog();
    }

    /// <summary>QR конфига AWG. Большой конфиг (длинный I1) может не влезть в QR — тогда скажем честно.</summary>
    public static void ShowConfig(Window owner, string title, string config)
    {
        var panel = new StackPanel { Margin = new Thickness(16) };
        try { panel.Children.Add(QrImage(config, QRCoder.QRCodeGenerator.ECCLevel.L, 420)); }
        catch (Exception)
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"Конфиг слишком большой для QR ({config.Length} символов) — используй «Сохранить .conf» или «Конфиг → буфер».",
                TextWrapping = TextWrapping.Wrap, Width = 420,
            });
        }
        var box = LinkBox(config);
        box.Width = 420;
        box.MaxHeight = 160;
        box.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        panel.Children.Add(box);
        var w = new Window
        {
            Title = "AWG · " + title, Owner = owner, Content = panel,
            SizeToContent = SizeToContent.WidthAndHeight, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        w.SetResourceReference(Window.BackgroundProperty, "BgBrush");
        w.SetResourceReference(Window.ForegroundProperty, "FgBrush");
        w.ShowDialog();
    }

    private static TextBox LinkBox(string s) => new()
    {
        Text = s, IsReadOnly = true, Width = 360, Margin = new Thickness(0, 10, 0, 0), TextWrapping = TextWrapping.Wrap,
    };

    private static Image QrImage(string text, QRCoder.QRCodeGenerator.ECCLevel level = QRCoder.QRCodeGenerator.ECCLevel.M, int size = 360)
    {
        using var gen = new QRCoder.QRCodeGenerator();
        using var data = gen.CreateQrCode(text, level);
        var png = new QRCoder.PngByteQRCode(data).GetGraphic(10);
        var bmp = new System.Windows.Media.Imaging.BitmapImage();
        using (var ms = new MemoryStream(png))
        {
            bmp.BeginInit();
            bmp.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
            bmp.StreamSource = ms;
            bmp.EndInit();
        }
        bmp.Freeze();
        return new Image { Source = bmp, Width = size, Height = size, Stretch = Stretch.Uniform };
    }
}
