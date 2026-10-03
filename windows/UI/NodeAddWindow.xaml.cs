using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>Нода из итога установщика (3x-ui или AWG): выделил блок в терминале → хоткей.
/// Сразу спрашивает «новая или переустановка» (по домену подбирает, кого заменить):
/// · 3x-ui — вход по паролю, выпуск API-токена (показывается и прописывается), при переустановке узла —
///   перепривязка на главной (новый адрес + node-sync токен; главная сама зальёт инбаунды и клиентов);
/// · AWG — определение вида панели, при переустановке — пересоздание клиентов старой панели по именам.</summary>
public partial class NodeAddWindow : Window
{
    public sealed class Item
    {
        public InstallBlock B = null!;
        public string? Kind;          // xui | awg | awg1 | null (ещё не знаем)
        public bool Detected;
        public string Name = "";
        public Guid? ReplaceId;
        public bool? Replace;         // null — решим по совпадению адреса/домена
        public string? Token;         // выпущенный в этом окне токен 3x-ui
        public string? TokenFor;      // для какого адреса
        public bool Done;
        public string Caption => (Done ? "✓ " : "") + (Name.Length > 0 ? Name : B.SuggestName()) + "  ·  " + PanelProbe.Text(Kind);
        public string Sub => B.Url.Length > 0 ? B.Url : "ввести вручную";
    }

    private readonly XuiStore _store;
    private readonly List<Item> _items;
    private Item _cur;
    private bool _ready, _busy, _loading;

    /// <summary>Что сохранено: id панели и её роль (master/node/awg/awg1).</summary>
    public List<(Guid Id, string Role)> Saved { get; } = new();
    /// <summary>Новую ноду 3x-ui подключить к главной после закрытия окна.</summary>
    public Guid? ConnectId { get; private set; }
    /// <summary>Пароли из выделения — вычистить их из буфера обмена.</summary>
    public List<string> Passwords { get; } = new();

    public NodeAddWindow(XuiStore store, string? selection)
    {
        InitializeComponent();
        _store = store;
        var blocks = InstallParser.Parse(selection);
        _items = blocks.Select(b => new Item { B = b, Kind = Guess(b) }).ToList();
        if (_items.Count == 0) _items.Add(new Item { B = new InstallBlock(), Kind = PanelProbe.Xui });
        foreach (var it in _items) it.Name = it.B.SuggestName();
        if (_items.Count < 2)
        {
            ListCol.Width = new GridLength(0);
            GapCol.Width = new GridLength(0);
        }
        _cur = _items[0];
        Items.ItemsSource = _items;
        Items.SelectedIndex = 0;   // до _ready: обработчик не должен «сохранить» пустую форму в блок
        _ready = true;
        ShowItem(_cur);
        if (blocks.Count == 0)
            Log("В буфере нет итога установки. Выдели в терминале блок от «INSTALLATION COMPLETE» (или «Access URL»/«Panel») " +
                "до AdGuard — выделение сразу копируется — и нажми хоткей ещё раз. Или заполни поля руками.");
        Loaded += async (_, _) => await DetectAllAsync();
    }

    private static string? Guess(InstallBlock b) => b.Kind switch
    {
        "xui" => PanelProbe.Xui,
        "awg" => b.Login.Length > 0 ? PanelProbe.Awg : PanelProbe.AwgOld,
        _ => b.Login.Length > 0 ? PanelProbe.Xui : null,
    };

    private void Log(string line)
    {
        LogBox.AppendText((LogBox.Text.Length > 0 ? "\n" : "") + line);
        LogBox.ScrollToEnd();
    }

    private static bool IsXuiKind(string? k) => k == PanelProbe.Xui;

    // ── вид панели ──

    private async Task DetectAllAsync()
    {
        Store(_cur); // что успели ввести — не терять
        var before = _items.ToDictionary(i => i, i => i.Kind);
        var tasks = _items.Where(i => i.B.Url.Length > 0 && !i.Detected).Select(async it =>
        {
            try { it.Kind = await PanelProbe.DetectAsync(it.B.Url, true) ?? it.Kind; it.Detected = true; }
            catch (XuiException ex) when (ex.Message.StartsWith("сертификат", StringComparison.Ordinal))
            {
                try { it.Kind = await PanelProbe.DetectAsync(it.B.Url, false) ?? it.Kind; it.Detected = true; } catch { }
            }
            catch { /* не ответила — оставим догадку, проверится при сохранении */ }
        });
        await Task.WhenAll(tasks);
        // вид поменялся — «кого заменить» подбираем заново (другой список кандидатов)
        foreach (var it in _items.Where(i => i.Kind != before[i])) { it.Replace = null; it.ReplaceId = null; }
        Items.Items.Refresh();
        if (!_busy) ShowItem(_cur);
    }

    private static int TypeIndex(string? k) => k switch { PanelProbe.Awg => 1, PanelProbe.AwgOld => 2, _ => 0 };
    private static string KindOf(int i) => i switch { 1 => PanelProbe.Awg, 2 => PanelProbe.AwgOld, _ => PanelProbe.Xui };

    // ── форма ──

    private void Items_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || Items.SelectedItem is not Item it) return;
        Store(_cur);
        _cur = it;
        ShowItem(it);
    }

    private void Store(Item it)
    {
        it.B.Url = UrlBox.Text.Trim();
        it.B.Login = LoginBox.Text.Trim();
        it.B.Password = PassBox.Password;
        it.Name = NameBox.Text.Trim();
        it.Replace = ReplaceRadio.IsChecked == true;
        it.ReplaceId = (ReplaceBox.SelectedItem as XuiPanel)?.Id;
    }

    private List<XuiPanel> Candidates(string? kind) =>
        _store.Panels().Where(p => IsXuiKind(kind) ? p.IsXui : p.IsAwg).ToList();

    /// <summary>Кого, скорее всего, переустановили: тот же адрес → тот же домен.</summary>
    private static XuiPanel? Match(List<XuiPanel> cands, string url)
    {
        PanelUrl u;
        try { u = PanelUrl.Parse(url); } catch { return null; }
        bool Same(XuiPanel p) { try { return PanelUrl.Parse(p.Url) == u; } catch { return false; } }
        bool Host(XuiPanel p) { try { return string.Equals(PanelUrl.Parse(p.Url).Host, u.Host, StringComparison.OrdinalIgnoreCase); } catch { return false; } }
        return cands.FirstOrDefault(Same) ?? cands.FirstOrDefault(Host);
    }

    private void ShowItem(Item it)
    {
        _loading = true;
        var b = it.B;
        HeadText.Text = (b.Title.Length > 0 ? b.Title : "Панель из выделения") +
                        (b.Server.Length > 0 ? $"  ·  сервер {b.Server}" : "") +
                        (it.Detected ? $"\nОпределено по адресу: {PanelProbe.Text(it.Kind)}" : "");
        UrlBox.Text = b.Url;
        LoginBox.Text = b.Login;
        PassBox.Password = b.Password;
        TwoFaBox.Text = "";
        TokenBox.Text = it.Token ?? "";
        TypeBox.SelectedIndex = TypeIndex(it.Kind);
        FillReplace(it);
        NameBox.Text = it.Name;
        _loading = false;
        ApplyMode();
        SaveButton.Content = it.Done ? "Сохранить ещё раз" : ReplaceRadio.IsChecked == true ? "Заменить" : "Сохранить";
    }

    private void FillReplace(Item it)
    {
        var cands = Candidates(it.Kind);
        ReplaceBox.ItemsSource = cands;
        ReplaceBox.DisplayMemberPath = nameof(XuiPanel.Display);
        var guess = it.ReplaceId is { } rid ? cands.FirstOrDefault(p => p.Id == rid) : Match(cands, it.B.Url);
        ReplaceBox.SelectedItem = guess;
        var replace = it.Replace ?? guess is not null;
        ReplaceRadio.IsEnabled = cands.Count > 0;
        ReplaceRadio.IsChecked = replace && cands.Count > 0;
        NewRadio.IsChecked = !(replace && cands.Count > 0);
        if (replace && guess is not null && it.Replace is null) it.Name = guess.Name;
    }

    private void TypeBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || _loading) return;
        Store(_cur);
        _cur.Kind = KindOf(TypeBox.SelectedIndex);
        _cur.ReplaceId = null;
        _cur.Replace = null;
        _loading = true;
        FillReplace(_cur);
        NameBox.Text = _cur.Name;
        _loading = false;
        ApplyMode();
    }

    private void Mode_Changed(object sender, RoutedEventArgs e)
    {
        if (!_ready || _loading) return;
        if (ReplaceRadio.IsChecked == true && ReplaceBox.SelectedItem is XuiPanel p) NameBox.Text = p.Name;
        else if (NewRadio.IsChecked == true) NameBox.Text = _cur.B.SuggestName();
        ApplyMode();
    }

    private void ReplaceBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_ready || _loading) return;
        if (ReplaceBox.SelectedItem is XuiPanel p)
        {
            _loading = true;
            ReplaceRadio.IsChecked = true;
            NewRadio.IsChecked = false;
            _loading = false;
            NameBox.Text = p.Name;
        }
        ApplyMode();
    }

    private void XRoleBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_ready && !_loading) ApplyMode();
    }

    private XuiPanel? ReplaceTarget => ReplaceRadio.IsChecked == true ? ReplaceBox.SelectedItem as XuiPanel : null;
    private string Kind => KindOf(TypeBox.SelectedIndex);

    private void ApplyMode()
    {
        if (!_ready) return;
        var xui = IsXuiKind(Kind);
        var target = ReplaceTarget;
        var masters = _store.Panels().Where(p => p.IsMaster).ToList();
        var role = target?.Role ?? (xui ? (XRoleBox.SelectedIndex == 1 ? "master" : "node") : Kind);

        RolePanel.Visibility = xui && target is null ? Visibility.Visible : Visibility.Collapsed;
        LoginPanel.Visibility = Kind == PanelProbe.AwgOld ? Visibility.Collapsed : Visibility.Visible;
        LoginCap.Text = xui ? "Логин админа 3x-ui" : "Логин админа awg-panel (2FA должна быть выключена)";
        PassCap.Text = xui ? "Пароль админа 3x-ui (сохранится в вейлте — чтобы перевыпускать токен)"
                           : "Пароль панели (хранится в вейлте QTerm)";
        TwoFaPanel.Visibility = xui ? Visibility.Visible : Visibility.Collapsed;
        TokenPanel.Visibility = xui ? Visibility.Visible : Visibility.Collapsed;

        ModeNote.Text = target is null
            ? "Новая запись в QTerm" + (ReplaceRadio.IsEnabled ? ". Если это переустановка — выбери, кого заменить: имя и место в синке сохранятся." : ".")
            : $"«{target.Name}» ({target.RoleText}) получит новый адрес и доступ; имя и запись в синке те же" +
              (Match(new List<XuiPanel> { target }, UrlBox.Text) is null ? ". Домен другой — проверь, что выбрана та нода." : ".");

        // 3x-ui · переустановленный узел → перепривязать на главной
        var rebind = xui && target is { IsXuiNode: true } && masters.Count > 0;
        RebindBox.Visibility = rebind ? Visibility.Visible : Visibility.Collapsed;
        RebindText.Text = rebind
            ? $"Перепривязать узел на главной ({string.Join(", ", masters.Select(m => m.Name))}): новый адрес и токен node-sync. " +
              "Главная сама зальёт на ноду свои инбаунды и клиентов (те же UUID и ключи Reality — у клиентов ничего не меняется); " +
              "инбаунды, созданные установщиком, она заменит. Только для переустановки на том же сервере с теми же доменами: если у инбаундов узла SNI/сертификаты, которых на новом сервере нет, — не перепривяжу, а подключу новый сервер отдельным узлом."
            : "";

        // 3x-ui · новая нода → подключить к главной
        var connect = xui && target is null && role == "node" && masters.Count > 0;
        ConnectBox.Visibility = connect ? Visibility.Visible : Visibility.Collapsed;
        ConnectText.Text = connect ? "После сохранения подключить к главной — откроется план ревизии имён, как в «Подключить ноду…»" : "";

        // AWG · переустановка → пересоздать клиентов по именам
        var old = !xui && target?.Clients is { Count: > 0 } c ? c : null;
        RecreateBox.Visibility = old is not null ? Visibility.Visible : Visibility.Collapsed;
        RecreateText.Text = old is not null
            ? $"Пересоздать клиентов старой панели ({old.Count}): {string.Join(", ", old)}. " +
              "Ключи будут новые — конфиги и QR раздать заново (вкладка AWG)."
            : "";
        if (!_busy)
            SaveButton.Content = _cur.Done ? "Сохранить ещё раз" : target is null ? "Сохранить" : "Заменить";
    }

    private void CopyToken_Click(object sender, RoutedEventArgs e)
    {
        if (TokenBox.Text.Length == 0) return;
        try { Clipboard.SetText(TokenBox.Text); Log("токен скопирован"); } catch { }
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    // ── проверка / сохранение ──

    private XuiPanel? FromForm()
    {
        var url = UrlBox.Text.Trim();
        try { PanelUrl.Parse(url); }
        catch (XuiException ex) { Log("✗ " + ex.Message); return null; }
        if (PassBox.Password.Length == 0) { Log("✗ нужен пароль"); return null; }
        var xui = IsXuiKind(Kind);
        if ((xui || Kind == PanelProbe.Awg) && LoginBox.Text.Trim().Length == 0) { Log("✗ нужен логин"); return null; }
        var target = ReplaceTarget;
        if (ReplaceRadio.IsChecked == true && target is null) { Log("✗ выбери, кого заменить"); return null; }
        var name = NameBox.Text.Trim();
        if (name.Length == 0) name = target?.Name ?? new InstallBlock { Url = url }.SuggestName();
        // новая, но адрес уже есть в QTerm — обновим ту запись, а не плодим дубль
        var same = target ?? Candidates(Kind).FirstOrDefault(p => { try { return PanelUrl.Parse(p.Url) == PanelUrl.Parse(url); } catch { return false; } });
        return new XuiPanel
        {
            Id = same?.Id ?? Guid.NewGuid(),
            Name = name,
            Role = xui ? target?.Role ?? same?.Role ?? (XRoleBox.SelectedIndex == 1 ? "master" : "node") : Kind,
            Url = url,
            Login = Kind == PanelProbe.AwgOld ? "" : LoginBox.Text.Trim(),
            Token = xui ? "" : PassBox.Password,
            Pass = xui ? PassBox.Password : null,
            Clients = xui ? null : target?.Clients ?? same?.Clients,
            Ssh = target?.Ssh ?? same?.Ssh,
            VerifyTls = TlsBox.SelectedIndex == 0,
        };
    }

    private async Task<bool> RunAsync(Func<Task> op)
    {
        if (_busy) return false;
        _busy = true;
        TestButton.IsEnabled = SaveButton.IsEnabled = false;
        Cursor = System.Windows.Input.Cursors.AppStarting;
        try { await op(); return true; }
        catch (XuiException ex) { Log("✗ " + ex.Message); return false; }
        catch (Exception ex) { Log("✗ " + ex.Message); return false; }
        finally
        {
            _busy = false;
            TestButton.IsEnabled = SaveButton.IsEnabled = true;
            Cursor = null;
        }
    }

    private async Task<string?> DetectAsync(XuiPanel p)
    {
        var kind = await PanelProbe.DetectAsync(p.Url, p.VerifyTls);
        if (kind is not null && kind != _cur.Kind)
        {
            Log($"по адресу — {PanelProbe.Text(kind)}");
            Store(_cur);
            _cur.Kind = kind;
            _cur.Detected = true;
            _cur.Replace = null;
            _cur.ReplaceId = null;
            _loading = true;
            TypeBox.SelectedIndex = TypeIndex(kind);
            FillReplace(_cur);
            NameBox.Text = _cur.Name;
            _loading = false;
            ApplyMode();
        }
        return kind;
    }

    private async void Test_Click(object sender, RoutedEventArgs e)
    {
        if (FromForm() is not { } p) return;
        await RunAsync(async () =>
        {
            Log("━━ проверка " + p.Url);
            var kind = await DetectAsync(p);
            if (kind is null) Log("! вид панели не определился — проверяю как выбрано");
            if (IsXuiKind(Kind))
            {
                var r = await XuiLogin.IssueTokenAsync(p.Url, p.Login, PassBox.Password, TwoFaBox.Text.Trim(), p.VerifyTls, tokenName: null);
                // проверка — только вход, токен выпускается при сохранении (иначе в панели копились бы лишние)
                if (r.NeedTwoFactor) TwoFaBox.Focus();
                Log((r.Ok ? "" : "✗ ") + r.Message);
                return;
            }
            p.Role = Kind;
            Log(await AwgProbe.TestAsync(p));
        });
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        if (FromForm() is not { } p) return;
        var target = ReplaceTarget;
        var kindBefore = Kind;
        await RunAsync(async () =>
        {
            Log($"━━ {(target is null ? "новая" : "замена «" + target.Name + "»")}: {p.Url}");
            try { await DetectAsync(p); }
            catch (XuiException ex) { Log("! " + ex.Message); }
            if (Kind != kindBefore)
            {
                // список «кого заменить» поменялся — молча не заменяем
                Log("! по адресу другой вид панели — проверь «новая / переустановка» и нажми ещё раз");
                return;
            }
            if (IsXuiKind(Kind)) await SaveXuiAsync(p, target);
            else await SaveAwgAsync(p, target);
        });
        ApplyMode();
    }

    private async Task SaveXuiAsync(XuiPanel p, XuiPanel? target)
    {
        // токен: выпущенный в этом окне для того же адреса — не плодим второй
        if (_cur.Token is { Length: > 0 } t && _cur.TokenFor == p.Url) p.Token = t;
        else
        {
            var r = await XuiLogin.IssueTokenAsync(p.Url, p.Login, PassBox.Password, TwoFaBox.Text.Trim(), p.VerifyTls,
                $"qterm-{DateTime.Now:yyMMdd-HHmmss}");
            if (r.Token is null)
            {
                if (r.NeedTwoFactor) TwoFaBox.Focus();
                Log((r.NeedTwoFactor ? "! " : "✗ ") + r.Message);
                return;
            }
            Log(r.Message);
            p.Token = r.Token;
            _cur.Token = r.Token;
            _cur.TokenFor = p.Url;
            TokenBox.Text = r.Token;
        }
        using (var api = XuiApi.For(p))
        {
            var st = await api.StatusAsync();
            Log($"✓ токен работает · 3x-ui {st?["panelVersion"]?.GetValue<string>() ?? "?"}");
        }
        _store.SavePanel(p);
        Done(p, $"✓ «{p.Name}» ({p.RoleText}) {(target is null ? "сохранена" : "заменена")} в QTerm — уйдёт в синк");
        if (target is { IsXuiNode: true } && RebindBox.IsChecked == true && RebindBox.Visibility == Visibility.Visible)
            await RebindAsync(target, p);
        if (target is null && p.IsXuiNode && ConnectBox.IsChecked == true && ConnectBox.Visibility == Visibility.Visible)
        {
            ConnectId = p.Id;
            Log("→ после закрытия окна откроется подключение к главной");
        }
        if (target is { IsMaster: true })
            Log("! переустановлена главная: узлы и клиенты в её базе новые. Бэкапы прежней базы — " + XuiOps.BackupDir);
    }

    /// <summary>Узел на главной указывает на старую панель → новый адрес/порт/путь и node-sync токен с новой.
    /// Главная помечает узел «грязным» и при сверке заливает на ноду свои инбаунды с клиентами.</summary>
    private async Task RebindAsync(XuiPanel old, XuiPanel neu)
    {
        PanelUrl? oldUrl = null;
        try { oldUrl = PanelUrl.Parse(old.Url); } catch { }
        var nu = PanelUrl.Parse(neu.Url);
        foreach (var m in _store.Panels().Where(x => x.IsMaster))
        {
            using var master = XuiApi.For(m);
            List<XNode> nodes;
            try { nodes = await master.NodesAsync(); }
            catch (XuiException ex) { Log($"! главная «{m.Name}»: {ex.Message}"); continue; }
            var hit = nodes.FirstOrDefault(n => oldUrl is not null && oldUrl.SameAs(n.Address, n.Port, n.BasePath))
                      ?? nodes.FirstOrDefault(n => string.Equals(n.Name, old.Name, StringComparison.OrdinalIgnoreCase));
            if (hit is null) continue;

            // Перепривязка = главная зальёт на новый сервер инбаунды узла как есть (SNI, пути сертификатов,
            // Reality на локальный сайт) и снесёт инбаунды установщика. Годится только для переустановки
            // на том же сервере с теми же доменами. Другой сервер — отдельным узлом.
            var need = (await master.InboundsAsync()).Where(i => i.NodeId == hit.Id).SelectMany(i => i.HostBound).ToHashSet();
            var have = new HashSet<string>();
            using (var probe = XuiApi.For(neu))
            {
                try { have = (await probe.InboundsAsync()).SelectMany(i => i.HostBound).ToHashSet(); } catch (XuiException) { }
            }
            var missing = need.Where(x => !have.Contains(x)).OrderBy(x => x).ToList();
            if (missing.Count > 0)
            {
                Log($"✗ узел «{hit.Name}» на главной «{m.Name}» НЕ перепривязан: его инбаунды завязаны на домены и сертификаты прежнего сервера ({hit.Address}), а на новом их нет:");
                foreach (var x in missing) Log("    " + x);
                Log("  Перепривязка залила бы их на новый сервер и снесла его собственные — отсюда чужой SNI и слетевшие серты.");
                Log($"  Новый сервер подключаю к главной отдельным узлом, со своими инбаундами. Старый узел «{hit.Name}» удали во «Узлах», когда проверишь новый (имена в подписке совпадут — до удаления будут дубли).");
                ConnectId = neu.Id;
                return;
            }

            string? sync = null;
            var tname = $"qterm-master-{DateTime.Now:yyyyMMddHHmmss}";
            using (var node = XuiApi.For(neu))
            {
                try { sync = await node.CreateTokenAsync(tname, "node-sync"); }
                catch (XuiException ex) { Log($"! node-sync токен не выпустился ({ex.Message}) — отдам главной админский"); }
            }
            var view = await master.GetAsync($"/nodes/get/{hit.Id}") as JsonObject ?? new JsonObject();
            var mode = J.Str(view, "tlsVerifyMode", "verify");
            if (mode is not ("verify" or "skip" or "mtls")) mode = neu.VerifyTls ? "verify" : "skip"; // pin: отпечаток у новой другой
            var body = new JsonObject
            {
                ["name"] = J.Str(view, "name", hit.Name),
                ["remark"] = J.Str(view, "remark"),
                ["scheme"] = nu.Scheme,
                ["address"] = nu.Host,
                ["port"] = nu.Port,
                ["basePath"] = nu.BasePathOrSlash,
                ["apiToken"] = sync ?? neu.Token,
                ["enable"] = true,
                ["allowPrivateAddress"] = J.Bool(view, "allowPrivateAddress"),
                ["tlsVerifyMode"] = mode,
                ["pinnedCertSha256"] = "",
                ["inboundSyncMode"] = J.Str(view, "inboundSyncMode", "all"),
                ["inboundTags"] = view["inboundTags"] is JsonArray tags ? tags.DeepClone() : new JsonArray(),
                ["outboundTag"] = J.Str(view, "outboundTag"),
            };
            await master.PostAsync($"/nodes/update/{hit.Id}", body);
            Log($"✓ главная «{m.Name}»: узел «{hit.Name}» → {nu.Host}:{nu.Port}{nu.BasePath}" +
                (sync is not null ? $" (на ноде выпущен {tname})" : ""));
            try { await master.ProbeNodeAsync(hit.Id); Log("✓ узел на связи — главная заливает инбаунды и клиентов (минута-две)"); }
            catch (XuiException ex) { Log("! проверка узла: " + ex.Message); }
            Log("  Если у Hysteria на новой ноде другие пути сертификатов — поправь их в инбаунде на главной.");
            return;
        }
        Log("! ни на одной главной нет узла со старым адресом или именем «" + old.Name + "» — подключи его как новый (Узлы → Подключить ноду…)");
    }

    private async Task SaveAwgAsync(XuiPanel p, XuiPanel? target)
    {
        string msg;
        try { msg = await AwgProbe.TestAsync(p); }
        catch (XuiException ex)
        {
            Log("✗ " + ex.Message);
            if (!XuiDialog.Confirm(this, ex.Message + "\n\nСохранить всё равно? Проверить можно позже во вкладке AWG.",
                    "AWG-нода", "Сохранить")) return;
            msg = "сохранено без проверки";
        }
        Log(msg);
        _store.SavePanel(p);
        Done(p, $"✓ «{p.Name}» ({p.RoleText}) {(target is null ? "сохранена" : "заменена")} в QTerm — уйдёт в синк");
        if (target?.Clients is { Count: > 0 } old && RecreateBox.IsChecked == true && RecreateBox.Visibility == Visibility.Visible)
            await RecreateAsync(p, old);
    }

    private async Task RecreateAsync(XuiPanel p, List<string> names)
    {
        using var api = AwgApi.For(p);
        var have = (await api.ClientsAsync(p)).Select(c => c.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var ifs = await api.InterfacesAsync();
        int made = 0, skipped = 0;
        foreach (var n in names)
        {
            if (have.Contains(n)) { skipped++; continue; }
            // -31 / -20 — клиенты конкретной версии AWG (так их называет «＋ Клиент» → «Оба»)
            string? iface = null;
            if (n.EndsWith("-31", StringComparison.Ordinal)) iface = ifs.FirstOrDefault(i => i.IsAwg31 && i.Enabled)?.Name;
            else if (n.EndsWith("-20", StringComparison.Ordinal)) iface = ifs.FirstOrDefault(i => !i.IsAwg31 && i.Enabled)?.Name;
            try { await api.CreateAsync(n, iface); made++; }
            catch (XuiException ex) { Log($"✗ {n}: {ex.Message}"); }
        }
        Log($"✓ клиентов создано: {made}" + (skipped > 0 ? $", уже были: {skipped}" : "") + " — конфиги и QR во вкладке AWG");
    }

    private void Done(XuiPanel p, string line)
    {
        Log(line);
        Saved.RemoveAll(s => s.Id == p.Id);
        Saved.Add((p.Id, p.Role));
        if (PassBox.Password.Length > 0) Passwords.Add(PassBox.Password);
        _cur.Done = true;
        _cur.Kind = IsXuiKind(Kind) ? PanelProbe.Xui : p.Role;
        _cur.Name = p.Name;
        _cur.ReplaceId = ReplaceTarget?.Id;
        Items.Items.Refresh();
        if (_items.FirstOrDefault(i => !i.Done) is { } next)
            Log($"→ дальше в выделении: {next.Sub} (выбери слева)");
    }
}
