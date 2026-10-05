using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>Кирпичики диалогов каскада (тёмная тема, как XuiDialog).</summary>
internal static class CUi
{
    public static Window Win(Window owner, string title, double width, double height)
    {
        var w = new Window
        {
            Title = title, Owner = owner, Width = width, Height = height, MinWidth = 520, MinHeight = 360,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        w.SetResourceReference(Window.BackgroundProperty, "BgBrush");
        w.SetResourceReference(Window.ForegroundProperty, "FgBrush");
        return w;
    }

    public static TextBox Caption(string text, double bottom = 10)
    {
        var t = new TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, Margin = new Thickness(0, 0, 0, bottom), Padding = new Thickness(0),
        };
        t.SetResourceReference(Control.ForegroundProperty, "FgBrush");
        return t;
    }

    public static TextBlock Label(string text, double top = 8)
    {
        var t = new TextBlock { Text = text, Margin = new Thickness(0, top, 0, 3), TextWrapping = TextWrapping.Wrap };
        t.SetResourceReference(TextBlock.ForegroundProperty, "DimBrush");
        return t;
    }

    public static TextBlock Head(string text, double top = 8)
    {
        var t = new TextBlock { Text = text, Margin = new Thickness(0, top, 0, 2), FontWeight = FontWeights.SemiBold };
        t.SetResourceReference(TextBlock.ForegroundProperty, "FgBrush");
        return t;
    }

    public static TextBox Input(string text = "") => new() { Text = text, Padding = new Thickness(6) };

    public static CheckBox Check(string text, bool on = false)
    {
        var c = new CheckBox { Content = text, IsChecked = on, Margin = new Thickness(0, 3, 0, 3), VerticalContentAlignment = VerticalAlignment.Center };
        c.SetResourceReference(Control.ForegroundProperty, "FgBrush");
        return c;
    }

    public static RadioButton Radio(string text, string group, bool on = false)
    {
        var r = new RadioButton { Content = text, GroupName = group, IsChecked = on, Margin = new Thickness(0, 3, 14, 3), VerticalContentAlignment = VerticalAlignment.Center };
        r.SetResourceReference(Control.ForegroundProperty, "FgBrush");
        return r;
    }

    public static ComboBox Combo(double width = 0)
    {
        var c = new ComboBox { VerticalAlignment = VerticalAlignment.Center };
        if (width > 0) c.Width = width;
        return c;
    }

    public static Button Btn(string text, double minWidth = 100, double left = 8) =>
        new() { Content = text, MinWidth = minWidth, Margin = new Thickness(left, 0, 0, 0) };

    /// <summary>Строка «подпись — элемент».</summary>
    public static DockPanel Row(string label, UIElement el, double labelWidth = 130, double top = 6)
    {
        var d = new DockPanel { Margin = new Thickness(0, top, 0, 0) };
        var l = new TextBlock { Text = label, Width = labelWidth, VerticalAlignment = VerticalAlignment.Center };
        l.SetResourceReference(TextBlock.ForegroundProperty, "DimBrush");
        d.Children.Add(l);
        d.Children.Add(el);
        return d;
    }

    public static StackPanel H(params UIElement[] items)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var i in items) p.Children.Add(i);
        return p;
    }

    public static TextBlock Status()
    {
        var t = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
        t.SetResourceReference(TextBlock.ForegroundProperty, "DimBrush");
        return t;
    }

    public static ScrollViewer Scroll(UIElement content)
    {
        var sv = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = content, Padding = new Thickness(6) };
        sv.SetResourceReference(Control.BackgroundProperty, "PanelBrush");
        return sv;
    }

    /// <summary>Имя для источника/клиента из имени сервера: латиница, цифры, - _ .</summary>
    public static string Slug(string s, string fallback)
    {
        var t = new string(s.Where(ch => ch is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-' or '_' or '.').ToArray());
        return t.Length > 0 ? (t.Length > 24 ? t[..24] : t) : fallback;
    }

    public static string FreeName(string want, ISet<string> taken)
    {
        if (!taken.Contains(want)) return want;
        for (var i = 2; i < 100; i++)
            if (!taken.Contains($"{want}-{i}")) return $"{want}-{i}";
        return want + "-" + Guid.NewGuid().ToString("N")[..4];
    }

    public static string? CheckName(string name, ISet<string> taken, string? self)
    {
        if (!CascadeSource.NameRx.IsMatch(name)) return "имя источника — латиница, цифры, . _ - (до 32 знаков)";
        if (name != self && taken.Contains(name)) return $"источник «{name}» уже есть";
        return null;
    }

    /// <summary>Большой текст: правка (null — отмена или без изменений) или просмотр (readOnly).</summary>
    public static string? EditText(Window owner, string title, string caption, string text, bool readOnly = false)
    {
        string? result = null;
        var w = Win(owner, title, 980, 680);
        var root = new DockPanel { Margin = new Thickness(14) };
        var cap = Caption(caption, 8);
        DockPanel.SetDock(cap, Dock.Top);
        root.Children.Add(cap);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(row, Dock.Bottom);
        var box = new TextBox
        {
            Text = text, AcceptsReturn = true, AcceptsTab = true, IsReadOnly = readOnly,
            TextWrapping = TextWrapping.NoWrap, Padding = new Thickness(6),
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        box.SetResourceReference(Control.BackgroundProperty, "PanelBrush");
        box.SetResourceReference(Control.ForegroundProperty, "FgBrush");
        if (!readOnly)
        {
            var save = Btn("Готово", 120, 0);
            save.Click += (_, _) => { if (box.Text != text) result = box.Text; w.Close(); };
            row.Children.Add(save);
        }
        var close = Btn(readOnly ? "Закрыть" : "Отмена");
        close.IsCancel = true;
        close.Click += (_, _) => w.Close();
        row.Children.Add(close);
        root.Children.Add(row);
        root.Children.Add(box);
        w.Content = root;
        w.Loaded += (_, _) => box.Focus();
        w.ShowDialog();
        return result;
    }
}

/// <summary>Источник «ссылка подписки» — любая Clash/Mihomo-ссылка (подписка отдельной ноды и т.п.).</summary>
internal static class CascadeLinkDialog
{
    public static CascadeSource? Show(Window owner, CascadeSource? edit, ISet<string> taken, string defName)
    {
        while (true)
        {
            var f = XuiDialog.Form(owner,
                "Clash/Mihomo-ссылка подписки — например, подписка отдельной ноды. Уйдёт только на сервер " +
                "(/etc/qcascade, 600), в QTerm не хранится. Одинаковые имена нод из разных источников разводит префикс.",
                edit is null ? "Источник: ссылка подписки" : $"Источник «{edit.Name}»",
                new[]
                {
                    new XuiDialog.Field("Имя источника (латиница, цифры, . _ -)", edit?.Name ?? defName),
                    new XuiDialog.Field("Ссылка Clash / Mihomo", edit?.Url ?? "", Secure: true),
                    new XuiDialog.Field("Префикс имён нод (необязательно)", edit?.Prefix ?? ""),
                }, edit is null ? "Добавить" : "Сохранить");
            if (f is null) return null;
            var name = f[0].Trim();
            var url = f[1].Trim();
            var prefix = f[2].Trim();
            string? err = CUi.CheckName(name, taken, edit?.Name);
            if (err is null && !url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                err = "нужна http(s)-ссылка подписки";
            if (err is null && !CascadeSource.PrefixRx.IsMatch(prefix)) err = "префикс — латиница, цифры, . _ - (до 16)";
            if (err is not null) { XuiDialog.Info(owner, err, "Источник"); continue; }
            var s = edit?.Clone() ?? new CascadeSource();
            s.Name = name;
            s.Type = "sub";
            s.Url = url;
            s.Prefix = prefix;
            if (edit is null || edit.Kind != "link") s.Meta = new JsonObject { ["kind"] = "link" };
            return s;
        }
    }
}

/// <summary>
/// Источник «свой клиент каскада на панели 3x-ui»: клиент на любой сохранённой панели (главной — с инбаундами
/// всех её узлов, или отдельной ноде) с выбранным набором инбаундов. Его Clash-подписка и есть источник:
/// в каскад попадают ровно эти серверы, единая подписка клиентов не трогается.
/// </summary>
internal sealed class CascadeXuiSourceDialog
{
    public CascadeSource? Result { get; private set; }

    private readonly Window _w;
    private readonly CascadeSource? _edit;
    private readonly ISet<string> _taken;
    private readonly Action<string> _log;
    private readonly List<XuiPanel> _panels;
    private XuiApi? _api;
    private List<XInbound> _inbounds = new();
    private List<XNode> _nodes = new();
    private List<XClient> _clients = new();
    private readonly Dictionary<int, CheckBox> _boxes = new();
    private bool _busy;

    private readonly ComboBox _panelBox = CUi.Combo();
    private readonly RadioButton _newRb = CUi.Radio("новый:", "xuicl", true);
    private readonly RadioButton _oldRb = CUi.Radio("существующий:", "xuicl");
    private readonly TextBox _newName;
    private readonly ComboBox _oldBox = CUi.Combo(220);
    private readonly TextBox _name;
    private readonly TextBox _prefix;
    private readonly StackPanel _checks = new();
    private readonly TextBlock _status = CUi.Status();
    private readonly Button _ok;

    public CascadeXuiSourceDialog(Window owner, XuiStore store, string server, CascadeSource? edit, ISet<string> taken, Action<string> log)
    {
        _edit = edit;
        _taken = taken;
        _log = log;
        _panels = store.Panels().Where(p => p.IsXui && p.Token.Length > 0).ToList();
        _w = CUi.Win(owner, edit is null ? "Источник: клиент каскада на панели 3x-ui" : $"Источник «{edit.Name}»", 760, 720);

        var slug = CUi.Slug(server, "CASCADE").ToUpperInvariant();
        _newName = CUi.Input(edit?.MetaStr("client") ?? $"CASC-{slug}");
        _newName.Width = 220;
        _name = CUi.Input(edit?.Name ?? "");
        _name.Width = 200;
        _prefix = CUi.Input(edit?.Prefix ?? "");
        _prefix.Width = 120;

        var top = new StackPanel();
        top.Children.Add(CUi.Caption(
            "Свой клиент каскада на панели 3x-ui: его Clash-подписка с отмеченными инбаундами станет источником нод — " +
            "в каскад попадут ровно эти серверы. Единая подписка клиентов не меняется. Панель — главная (инбаунды всех " +
            "её узлов) или отдельная нода; клиентов каскада может быть сколько угодно, на разных панелях."));
        _panelBox.DisplayMemberPath = "Display";
        _panelBox.ItemsSource = _panels;
        top.Children.Add(CUi.Row("Панель", _panelBox));
        var clientRow = CUi.H(_newRb, _newName, new TextBlock { Width = 18 }, _oldRb, _oldBox);
        top.Children.Add(CUi.Row("Клиент", clientRow));
        var pfxLabel = CUi.Label("   префикс нод:", 0);
        pfxLabel.VerticalAlignment = VerticalAlignment.Center;
        top.Children.Add(CUi.Row("Имя источника", CUi.H(_name, pfxLabel, _prefix)));
        var all = CUi.Btn("Все", 70, 0);
        var none = CUi.Btn("Ни одного", 90, 6);
        all.Click += (_, _) => { foreach (var b in _boxes.Values) b.IsChecked = true; };
        none.Click += (_, _) => { foreach (var b in _boxes.Values) b.IsChecked = false; };
        var ibHead = new DockPanel { Margin = new Thickness(0, 12, 0, 6) };
        var ibBtns = CUi.H(all, none);
        DockPanel.SetDock(ibBtns, Dock.Right);
        ibHead.Children.Add(ibBtns);
        ibHead.Children.Add(CUi.Label("Инбаунды — какие серверы попадут в подписку каскада:", 0));
        top.Children.Add(ibHead);

        var bottom = new StackPanel();
        bottom.Children.Add(_status);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        _ok = CUi.Btn(edit is null ? "Создать и добавить" : "Сохранить", 150, 0);
        _ok.IsDefault = true;
        var cancel = CUi.Btn("Отмена");
        cancel.IsCancel = true;
        row.Children.Add(_ok);
        row.Children.Add(cancel);
        bottom.Children.Add(row);

        var root = new DockPanel { Margin = new Thickness(16) };
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(top);
        root.Children.Add(bottom);
        root.Children.Add(CUi.Scroll(_checks));
        _w.Content = root;

        if (edit is not null)
        {
            _panelBox.SelectedItem = _panels.FirstOrDefault(p => p.Id == edit.PanelId);
            _panelBox.IsEnabled = false;
            _newRb.IsEnabled = false;
            _newName.IsEnabled = false;
            _oldRb.IsChecked = true;
            _oldBox.IsEnabled = false;
        }
        else
        {
            _panelBox.SelectedItem = _panels.FirstOrDefault(p => p.IsMaster) ?? _panels.FirstOrDefault();
        }

        _ok.Click += async (_, _) => await OkAsync();
        cancel.Click += (_, _) => _w.Close();
        _panelBox.SelectionChanged += async (_, _) => { if (!_busy) await LoadPanelAsync(); };
        _oldBox.SelectionChanged += (_, _) =>
        {
            if (_busy || _oldBox.SelectedItem is not string em) return;
            _oldRb.IsChecked = true;
            if (_clients.FirstOrDefault(c => c.Email == em) is { } cl) BuildChecks(cl.InboundIds.ToHashSet());
        };
        _w.Closed += (_, _) => _api?.Dispose();
        _w.Loaded += async (_, _) =>
        {
            if (_panels.Count == 0)
            {
                _status.Text = "✗ в QTerm нет панелей 3x-ui с токеном — «Ноды 3x-ui» → «Панели и токены…»";
                _ok.IsEnabled = false;
                return;
            }
            if (edit is not null && _panelBox.SelectedItem is null)
            {
                _status.Text = $"✗ панели «{edit.MetaStr("panelName")}» больше нет в QTerm — источник можно поменять только на ссылку";
                _ok.IsEnabled = false;
                return;
            }
            await LoadPanelAsync();
        };
    }

    public CascadeSource? ShowDialog()
    {
        _w.ShowDialog();
        return Result;
    }

    private void SetBusy(bool on)
    {
        _busy = on;
        _ok.IsEnabled = !on;
        _w.Cursor = on ? System.Windows.Input.Cursors.AppStarting : null;
    }

    private XuiPanel? Panel => _panelBox.SelectedItem as XuiPanel;

    private async Task LoadPanelAsync()
    {
        if (Panel is not { } p) return;
        _api?.Dispose();
        _api = XuiApi.For(p);
        SetBusy(true);
        _status.Text = $"загружаю «{p.Name}»…";
        _checks.Children.Clear();
        _boxes.Clear();
        try
        {
            _inbounds = await _api.InboundsAsync();
            try { _nodes = p.IsMaster ? await _api.NodesAsync() : new List<XNode>(); }
            catch (XuiException) { _nodes = new List<XNode>(); }
            _clients = await _api.ClientsAsync();
            _oldBox.ItemsSource = _clients.Select(c => c.Email).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
            HashSet<int> sel = new();
            if (_edit is not null)
            {
                var em = _edit.MetaStr("client");
                _oldBox.SelectedItem = em;
                if (_clients.FirstOrDefault(c => c.Email == em) is { } cl) sel = cl.InboundIds.ToHashSet();
                else _status.Text = $"! клиента {em} на панели нет — сохранение создаст его заново";
            }
            if (_name.Text.Trim().Length == 0) _name.Text = CUi.FreeName(CUi.Slug(p.Name, "SRC").ToUpperInvariant(), _taken);
            BuildChecks(sel);
            if (!_status.Text.StartsWith("!")) _status.Text = "";
        }
        catch (Exception ex) { _status.Text = "✗ " + ex.Message; }
        finally { SetBusy(false); }
    }

    private void BuildChecks(HashSet<int> selected)
    {
        _checks.Children.Clear();
        _boxes.Clear();
        var p = Panel;
        var groups = _inbounds.Where(i => i.MultiUser)
            .GroupBy(i => i.NodeId)
            .OrderBy(g => g.Key is null ? "" : _nodes.FirstOrDefault(n => n.Id == g.Key)?.Name ?? "~", StringComparer.OrdinalIgnoreCase);
        foreach (var g in groups)
        {
            var server = g.Key is int nid ? (_nodes.FirstOrDefault(n => n.Id == nid)?.Name ?? $"узел {nid}") : (p?.Name ?? "панель");
            _checks.Children.Add(CUi.Head(server, _checks.Children.Count == 0 ? 0 : 10));
            foreach (var ib in g.OrderBy(i => i.Remark, StringComparer.OrdinalIgnoreCase))
            {
                var cb = CUi.Check($"{ib.Remark}   ·   {ib.Protocol}:{ib.Port}{(ib.Enable ? "" : "   · выключен")}", selected.Contains(ib.Id));
                cb.Margin = new Thickness(14, 2, 0, 2);
                _boxes[ib.Id] = cb;
                _checks.Children.Add(cb);
            }
        }
        if (_boxes.Count == 0) _checks.Children.Add(CUi.Label("на панели нет многопользовательских инбаундов (VLESS, Hysteria…)", 0));
    }

    private async Task OkAsync()
    {
        if (_busy || _api is null || Panel is not { } p) return;
        var name = _name.Text.Trim();
        var prefix = _prefix.Text.Trim();
        var err = CUi.CheckName(name, _taken, _edit?.Name);
        if (err is null && !CascadeSource.PrefixRx.IsMatch(prefix)) err = "префикс — латиница, цифры, . _ - (до 16)";
        var ids = _boxes.Where(kv => kv.Value.IsChecked == true).Select(kv => kv.Key).ToList();
        if (err is null && ids.Count == 0) err = "отметь хотя бы один инбаунд";
        var email = (_newRb.IsChecked == true ? _newName.Text : _oldBox.SelectedItem as string ?? "").Trim();
        if (err is null && email.Length == 0) err = _newRb.IsChecked == true ? "введи имя нового клиента" : "выбери клиента";
        if (err is not null) { _status.Text = "✗ " + err; return; }

        var cl = _clients.FirstOrDefault(c => c.Email == email);
        var own = _edit is not null && _edit.MetaStr("client") == email;
        if (cl is not null && _newRb.IsChecked == true &&
            !XuiDialog.Confirm(_w, $"Клиент «{email}» уже есть на «{p.Name}» — взять его? Его инбаунды приведутся к отмеченным.", "Источник", "Взять"))
            return;
        if (cl is not null && !own)
        {
            var del = cl.InboundIds.Except(ids).ToList();
            if (del.Count > 0 && !XuiDialog.Confirm(_w,
                    $"«{email}» отвяжется от {del.Count} инбаунд(ов) — его другие устройства их потеряют. Продолжить?", "Источник", "Продолжить"))
                return;
        }

        SetBusy(true);
        _status.Text = "работаю с панелью…";
        try
        {
            if (cl is null)
            {
                await _api.AddClientAsync(email, ids);
                _log($"  ✓ клиент каскада {email} создан на «{p.Name}»: инбаундов {ids.Count}");
            }
            else
            {
                var add = ids.Except(cl.InboundIds).ToList();
                var del = cl.InboundIds.Except(ids).ToList();
                if (add.Count > 0) await _api.AttachAsync(email, add);
                if (del.Count > 0) await _api.DetachAsync(email, del);
                if (add.Count + del.Count > 0) _log($"  ✓ {email} на «{p.Name}»: +{add.Count} / −{del.Count} инбаундов");
            }
            _clients = await _api.ClientsAsync();
            cl = _clients.FirstOrDefault(c => c.Email == email)
                 ?? throw new XuiException($"клиент {email} не нашёлся на панели после создания — обнови и выбери его как существующего");
            if (cl.SubId.Length == 0)
            {
                var sid = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();
                await _api.UpdateClientAsync(email, XuiApi.ClientPayload(cl, subId: sid));
                _clients = await _api.ClientsAsync();
                cl = _clients.First(c => c.Email == email);
            }
            var st = await _api.SettingsAsync();
            var link = XuiApi.SubLink(st, _api.Url, cl.SubId, clash: true)
                       ?? throw new XuiException($"в панели «{p.Name}» выключена Clash/Mihomo-подписка: Настройки панели → Подписка → Clash — включить");
            var src = _edit?.Clone() ?? new CascadeSource();
            src.Name = name;
            src.Type = "sub";
            src.Url = link;
            src.Prefix = prefix;
            src.Conf = "";
            src.Meta = new JsonObject
            {
                ["kind"] = "xui",
                ["panel"] = p.Id.ToString(),
                ["panelName"] = p.Name,
                ["client"] = email,
                ["inbounds"] = new JsonArray(ids.Select(i => (JsonNode?)JsonValue.Create(i)).ToArray()),
            };
            Result = src;
            _w.DialogResult = true;
        }
        catch (Exception ex)
        {
            _status.Text = "✗ " + ex.Message;
            SetBusy(false);
        }
    }
}

/// <summary>
/// Источник WireGuard / AmneziaWG: клиент AWG-панели другой ноды (QTerm создаёт его сам и берёт конфиг)
/// или готовый .conf. Удобен резервом: все ноды группы недоступны — трафик группы уходит в этот туннель.
/// </summary>
internal sealed class CascadeWgSourceDialog
{
    public CascadeSource? Result { get; private set; }
    public bool Reserve => _reserve.IsChecked == true;

    private readonly Window _w;
    private readonly CascadeSource? _edit;
    private readonly ISet<string> _taken;
    private readonly Action<string> _log;
    private readonly List<XuiPanel> _panels;
    private List<AwgInterface> _ifs = new();
    private List<AwgClient> _clients = new();
    private bool _busy;

    private readonly TextBox _name;
    private readonly RadioButton _fromPanel = CUi.Radio("клиент AWG-панели", "wgsrc", true);
    private readonly RadioButton _fromConf = CUi.Radio("готовый конфиг .conf", "wgsrc");
    private readonly ComboBox _panelBox = CUi.Combo(220);
    private readonly ComboBox _ifBox = CUi.Combo(200);
    private readonly RadioButton _newRb = CUi.Radio("новый:", "wgcl", true);
    private readonly RadioButton _oldRb = CUi.Radio("существующий:", "wgcl");
    private readonly TextBox _newName;
    private readonly ComboBox _oldBox = CUi.Combo(200);
    private readonly TextBox _conf;
    private readonly CheckBox _reserve;
    private readonly StackPanel _panelPart = new();
    private readonly StackPanel _confPart = new();
    private readonly TextBlock _status = CUi.Status();
    private readonly Button _ok;

    public CascadeWgSourceDialog(Window owner, XuiStore store, string server, CascadeSource? edit, bool isReserve, ISet<string> taken, Action<string> log)
    {
        _edit = edit;
        _taken = taken;
        _log = log;
        _panels = store.Panels().Where(p => p.IsAwg).ToList();
        _w = CUi.Win(owner, edit is null ? "Источник: WireGuard / AWG" : $"Источник «{edit.Name}»", 720, 640);
        var slug = CUi.Slug(server, "cascade").ToLowerInvariant();
        _name = CUi.Input(edit?.Name ?? CUi.FreeName("WG", taken));
        _name.Width = 200;
        _newName = CUi.Input(edit?.MetaStr("client") is { Length: > 0 } cn ? cn : $"casc-{slug}");
        _newName.Width = 200;
        _conf = new TextBox
        {
            Text = edit?.Kind == "conf" ? edit.Conf : "", AcceptsReturn = true, Height = 170, Padding = new Thickness(6),
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12.5, TextWrapping = TextWrapping.NoWrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        _reserve = CUi.Check("резерв: все ноды группы недоступны — всё, что не DIRECT, идёт через этот туннель", isReserve);

        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(CUi.Caption(
            "Выход WireGuard / AmneziaWG (2.0 и 3.x) из каскада — клиент AWG-панели другой ноды (QTerm создаст его и заберёт " +
            "конфиг сам) или готовый .conf. Конфиг уйдёт только на сервер (/etc/qcascade, 600)."));
        root.Children.Add(CUi.Row("Имя источника", _name));
        var modeRow = CUi.H(_fromPanel, _fromConf);
        modeRow.Margin = new Thickness(0, 10, 0, 0);
        root.Children.Add(modeRow);

        _panelBox.DisplayMemberPath = "Name";
        _panelBox.ItemsSource = _panels;
        var ifLabel = CUi.Label("   интерфейс:", 0);
        ifLabel.VerticalAlignment = VerticalAlignment.Center;
        _panelPart.Children.Add(CUi.Row("AWG-панель", CUi.H(_panelBox, ifLabel, _ifBox)));
        _panelPart.Children.Add(CUi.Row("Клиент", CUi.H(_newRb, _newName, new TextBlock { Width = 14 }, _oldRb, _oldBox)));
        _panelPart.Margin = new Thickness(18, 4, 0, 0);
        root.Children.Add(_panelPart);

        var open = CUi.Btn("Открыть файл…", 130, 0);
        var pasteLabel = CUi.Label("   или вставь текст конфига:", 0);
        pasteLabel.VerticalAlignment = VerticalAlignment.Center;
        _confPart.Children.Add(CUi.H(open, pasteLabel));
        _conf.Margin = new Thickness(0, 6, 0, 0);
        _confPart.Children.Add(_conf);
        _confPart.Margin = new Thickness(18, 6, 0, 0);
        root.Children.Add(_confPart);

        root.Children.Add(_reserve);
        _reserve.Margin = new Thickness(0, 12, 0, 0);
        root.Children.Add(_status);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        _ok = CUi.Btn(edit is null ? "Добавить" : "Сохранить", 130, 0);
        _ok.IsDefault = true;
        var cancel = CUi.Btn("Отмена");
        cancel.IsCancel = true;
        row.Children.Add(_ok);
        row.Children.Add(cancel);
        root.Children.Add(row);
        _w.Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

        if (edit is not null && edit.Kind == "awg" && _panels.FirstOrDefault(p => p.Id == edit.PanelId) is { } ep)
        {
            _panelBox.SelectedItem = ep;
            _oldRb.IsChecked = true;
        }
        else if (edit is not null || _panels.Count == 0)
        {
            _fromConf.IsChecked = true;
            _panelBox.SelectedItem = _panels.FirstOrDefault();
        }
        else _panelBox.SelectedItem = _panels.FirstOrDefault();
        Mode();

        open.Click += (_, _) => OpenFile();
        _ok.Click += async (_, _) => await OkAsync();
        cancel.Click += (_, _) => _w.Close();
        _fromPanel.Checked += (_, _) => Mode();
        _fromConf.Checked += (_, _) => Mode();
        _panelBox.SelectionChanged += async (_, _) => { if (!_busy) await LoadPanelAsync(); };
        _oldBox.SelectionChanged += (_, _) => { if (!_busy && _oldBox.SelectedItem is not null) _oldRb.IsChecked = true; };
        _w.Loaded += async (_, _) => { if (_fromPanel.IsChecked == true) await LoadPanelAsync(); };
    }

    public CascadeSource? ShowDialog()
    {
        _w.ShowDialog();
        return Result;
    }

    private void Mode()
    {
        var panel = _fromPanel.IsChecked == true;
        _panelPart.Visibility = panel ? Visibility.Visible : Visibility.Collapsed;
        _confPart.Visibility = panel ? Visibility.Collapsed : Visibility.Visible;
        if (panel && _panels.Count == 0) _status.Text = "✗ в QTerm нет AWG-панелей — «Ноды 3x-ui» → «Панели и токены…» (роль «AWG-панель»), или готовый .conf";
        else if (!panel) _status.Text = "";
        if (panel && _clients.Count == 0 && _w.IsLoaded && !_busy) _ = LoadPanelAsync();
    }

    private void SetBusy(bool on)
    {
        _busy = on;
        _ok.IsEnabled = !on;
        _w.Cursor = on ? System.Windows.Input.Cursors.AppStarting : null;
    }

    private void OpenFile()
    {
        var dlg = new OpenFileDialog { Filter = "WireGuard (*.conf)|*.conf|Все файлы (*.*)|*.*", Title = "Конфиг WireGuard / AWG" };
        if (dlg.ShowDialog(_w) != true) return;
        try
        {
            _conf.Text = File.ReadAllText(dlg.FileName);
            if (_name.Text.Trim().Length == 0 || _name.Text.StartsWith("WG"))
                _name.Text = CUi.FreeName(CUi.Slug(Path.GetFileNameWithoutExtension(dlg.FileName), "WG"), _taken);
        }
        catch (Exception ex) { _status.Text = "✗ " + ex.Message; }
    }

    private async Task LoadPanelAsync()
    {
        if (_panelBox.SelectedItem is not XuiPanel p || _fromPanel.IsChecked != true) return;
        SetBusy(true);
        _status.Text = $"загружаю «{p.Name}»…";
        try
        {
            using var api = AwgApi.For(p);
            _ifs = await api.InterfacesAsync();
            _clients = await api.ClientsAsync(p);
            _ifBox.ItemsSource = _ifs.Where(i => i.Enabled).Select(i => i.Label).ToList();
            _ifBox.SelectedIndex = _ifs.Count(i => i.Enabled) > 0 ? 0 : -1;
            _oldBox.ItemsSource = _clients.Select(c => c.Name).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
            if (_edit?.Kind == "awg")
            {
                var cid = _edit.MetaStr("clientId");
                _oldBox.SelectedItem = _clients.FirstOrDefault(c => c.Id == cid)?.Name ?? _edit.MetaStr("client");
            }
            _status.Text = "";
        }
        catch (Exception ex) { _status.Text = "✗ " + ex.Message; }
        finally { SetBusy(false); }
    }

    private async Task OkAsync()
    {
        if (_busy) return;
        var name = _name.Text.Trim();
        var err = CUi.CheckName(name, _taken, _edit?.Name);
        if (err is not null) { _status.Text = "✗ " + err; return; }
        var src = _edit?.Clone() ?? new CascadeSource();
        src.Name = name;
        src.Type = "wg";
        src.Url = "";
        src.Prefix = "";
        if (_fromConf.IsChecked == true)
        {
            var conf = _conf.Text.Replace("\r\n", "\n").Trim() + "\n";
            if (CascadeSource.CheckWgConf(conf) is { } ce) { _status.Text = "✗ конфиг: " + ce; return; }
            src.Conf = conf;
            src.Meta = new JsonObject { ["kind"] = "conf" };
            Result = src;
            _w.DialogResult = true;
            return;
        }
        if (_panelBox.SelectedItem is not XuiPanel p) { _status.Text = "✗ выбери AWG-панель"; return; }
        var ifIdx = _ifBox.SelectedIndex;
        var enabledIfs = _ifs.Where(i => i.Enabled).ToList();
        var iface = ifIdx >= 0 && ifIdx < enabledIfs.Count ? enabledIfs[ifIdx] : null;
        var newClient = _newRb.IsChecked == true;
        var cname = newClient ? _newName.Text.Trim() : _oldBox.SelectedItem as string ?? "";
        if (cname.Length == 0) { _status.Text = newClient ? "✗ введи имя клиента" : "✗ выбери клиента"; return; }
        if (newClient && _clients.Any(c => c.Name == cname) &&
            !XuiDialog.Confirm(_w, $"Клиент «{cname}» уже есть на «{p.Name}» — взять его конфиг?", "Источник", "Взять"))
            return;

        SetBusy(true);
        _status.Text = "работаю с AWG-панелью…";
        try
        {
            using var api = AwgApi.For(p);
            var cl = _clients.FirstOrDefault(c => c.Name == cname);
            if (cl is null)
            {
                await api.CreateAsync(cname, p.IsAwgLegacy ? null : iface?.Name);
                _clients = await api.ClientsAsync(p);
                cl = _clients.LastOrDefault(c => c.Name == cname)
                     ?? throw new XuiException($"клиент {cname} не нашёлся на панели после создания");
                _log($"  ✓ клиент AWG {cname} создан на «{p.Name}»{(iface is null ? "" : " · " + iface.Label)}");
            }
            var conf = (await api.ConfigAsync(cl.Id)).Replace("\r\n", "\n");
            if (CascadeSource.CheckWgConf(conf) is { } ce) throw new XuiException("панель отдала странный конфиг: " + ce);
            src.Conf = conf.TrimEnd() + "\n";
            src.Meta = new JsonObject
            {
                ["kind"] = "awg",
                ["panel"] = p.Id.ToString(),
                ["panelName"] = p.Name,
                ["client"] = cl.Name,
                ["clientId"] = cl.Id,
                ["iface"] = cl.InterfaceId,
            };
            Result = src;
            _w.DialogResult = true;
        }
        catch (Exception ex)
        {
            _status.Text = "✗ " + ex.Message;
            SetBusy(false);
        }
    }
}

/// <summary>Список с галками. null — отмена; иначе отмеченные ключи.</summary>
internal static class CheckPickDialog
{
    public static List<string>? Show(Window owner, string text, string title, IList<(string Key, string Text)> items, ISet<string>? selected)
    {
        List<string>? result = null;
        var w = CUi.Win(owner, title, 560, 560);
        var root = new DockPanel { Margin = new Thickness(16) };
        var cap = CUi.Caption(text, 8);
        DockPanel.SetDock(cap, Dock.Top);
        root.Children.Add(cap);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(row, Dock.Bottom);
        var boxes = new List<(string Key, CheckBox Box)>();
        var panel = new StackPanel();
        foreach (var (key, t) in items)
        {
            var cb = CUi.Check(t, selected?.Contains(key) == true);
            boxes.Add((key, cb));
            panel.Children.Add(cb);
        }
        var ok = CUi.Btn("OK", 100, 0);
        ok.IsDefault = true;
        var cancel = CUi.Btn("Отмена");
        cancel.IsCancel = true;
        ok.Click += (_, _) => { result = boxes.Where(b => b.Box.IsChecked == true).Select(b => b.Key).ToList(); w.Close(); };
        cancel.Click += (_, _) => w.Close();
        row.Children.Add(ok);
        row.Children.Add(cancel);
        root.Children.Add(row);
        root.Children.Add(CUi.Scroll(panel));
        w.Content = root;
        w.ShowDialog();
        return result;
    }
}
