using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using QTermWin.Models;
using QTermWin.Vault;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>
/// «Каскад» — отдельное окно (живёт рядом с терминалом и «Нодами 3x-ui»): сервер с 3x-ui / AWG-панелью / MTProto
/// как маршрутизатор «как на Кинетике». На сервере — qcascade (scripts/vpn-cascade.sh, встроен в QTerm):
/// mihomo с правилами роутеров, ноды из своих источников (клиент каскада на любой панели 3x-ui со своим набором
/// инбаундов, ссылки подписок, WireGuard/AWG — в т.ч. резерв), перехват клиентов сервера.
/// QTerm управляет им отдельным exec-каналом SSH-сессии, терминал не трогается.
/// </summary>
public partial class CascadeWindow : Window
{
    public sealed class ServerRow
    {
        public CascadeServer Src { get; init; } = null!;
        public string Name => Src.Name;
        public string Sub { get; init; } = "";
        public Brush Dot { get; init; } = Brushes.Gray;
    }

    public sealed class GroupRow
    {
        public string Name { get; init; } = "";
        public string Node { get; init; } = "";
        public string Delay { get; init; } = "";
        public Brush Dot { get; init; } = Brushes.Gray;
    }

    /// <summary>Что известно о сервере (по последнему опросу).</summary>
    private sealed class ServerState
    {
        public bool Checked;
        public string? Version;          // null — qcascade нет
        public JsonObject? Status;
        public JsonObject? Detect;
        public bool Pending;             // источники/настройки записаны, но конфиг не пересобран
        public string? Error;            // до сервера не достучались (SSH, нет сессии)
        public string? SrvError;         // сервер ответил, а qcascade status — нет (сломанный/старый скрипт)
        public DateTime At;
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

    private const string Etc = "/etc/qcascade";

    private readonly XuiStore _store;
    private List<CascadeServer> _servers = new();
    private readonly Dictionary<Guid, ServerState> _st = new();
    private readonly Dictionary<Guid, CascadeRemote> _remotes = new();
    private string _seg = "overview";
    private bool _busy, _refreshing, _loadingUi;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(15) };
    private string _cardAction = "";
    // редакторы групп и правил: какой сервер загружен и исходный текст (для «Вернуть» и «без изменений»)
    private Guid? _groupsFor, _rulesFor;
    private string _groupsText = "", _rulesText = "";
    private Guid? _whoFor;

    /// <summary>exec по SSH-сессии: (id сессии, команда, таймаут с) → stdout. Задаёт главное окно.</summary>
    public Func<Guid, string, int, Task<string>>? ExecInSession { get; set; }
    /// <summary>Есть ли живое соединение сессии — автообновление не должно открывать вкладки само.</summary>
    public Func<Guid, bool>? SessionConnected { get; set; }

    public CascadeWindow(VaultRepo repo)
    {
        InitializeComponent();
        _store = new XuiStore(repo);
        ShowSeg("overview");
        LoadServers();
        _timer.Tick += async (_, _) => await TickAsync();
        Loaded += async (_, _) =>
        {
            _timer.Start();
            await RefreshAsync();
        };
        Closed += (_, _) => _timer.Stop();
        PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Key.F5) { e.Handled = true; await RefreshAsync(detect: true); }
        };
    }

    // ── лог ──

    private void Log(string line, LogKind kind = LogKind.Info)
    {
        LogBox.AppendText((LogBox.Text.Length > 0 ? "\n" : "") + line);
        LogBox.ScrollToEnd();
    }

    /// <summary>Вывод qcascade — в лог построчно.</summary>
    private void LogQc(string text)
    {
        foreach (var raw in CascadeRemote.Clean(text).Replace("\r", "").Split('\n'))
        {
            var l = raw.TrimEnd();
            if (l.Length > 0) Log("  " + l);
        }
    }

    // ── серверы ──

    private CascadeServer? Sel => (ServerList.SelectedItem as ServerRow)?.Src;

    private ServerState St(CascadeServer c)
    {
        if (!_st.TryGetValue(c.Id, out var s)) _st[c.Id] = s = new ServerState();
        return s;
    }

    private void LoadServers(Guid? pick = null)
    {
        var keep = pick ?? Sel?.Id;
        _servers = _store.Cascades();
        DropDuplicates();
        RenderServers(keep);
    }

    /// <summary>Один сервер дважды (добавлен на двух устройствах, сессию пересоздали и добавили заново):
    /// оставляем запись с меньшим id — одинаково на всех устройствах, синк не съест обе.</summary>
    private void DropDuplicates()
    {
        var seen = new HashSet<Guid>();
        foreach (var c in _servers.OrderBy(x => x.Id.ToString(), StringComparer.Ordinal).ToList())
        {
            if (SessionOf(c) is not { } s || seen.Add(s.Id)) continue;
            _store.DeleteCascade(c.Id);
            _servers.Remove(c);
            _st.Remove(c.Id);
            _remotes.Remove(c.Id);
            Log($"✓ «{c.Name}» был в списке дважды (та же SSH-сессия) — лишняя запись убрана", LogKind.Dim);
        }
    }

    private void RenderServers(Guid? keep = null)
    {
        keep ??= Sel?.Id;
        _loadingUi = true;
        var rows = _servers.Select(c => new ServerRow { Src = c, Sub = SubOf(c), Dot = DotOf(c) }).ToList();
        ServerList.ItemsSource = rows;
        ServerList.SelectedItem = rows.FirstOrDefault(r => r.Src.Id == keep) ?? rows.FirstOrDefault();
        _loadingUi = false;
        RenderAll();
    }

    private string SubOf(CascadeServer c)
    {
        var st = St(c);
        if (SessionOf(c) is null) return "нет SSH-сессии — «Выбрать сессию…»";
        if (!st.Checked) return st.Error is { } e ? "✗ " + e : "не опрошен";
        if (st.Error is { } err) return "✗ " + err;
        if (st.Version is null) return "каскад не установлен";
        if (!CascadeRemote.IsV2(st.Version)) return $"qcascade {st.Version} — нужно обновить";
        if (st.SrvError is not null)
            return CascadeRemote.Newer(CascadeRemote.ScriptVersion, st.Version)
                ? $"qcascade {st.Version} не отдаёт статус — обновить до {CascadeRemote.ScriptVersion}"
                : $"qcascade {st.Version} не отдаёт статус";
        var mh = st.Status?["mihomo"];
        if (!B(mh, "active")) return "mihomo не работает";
        var nodes = L(st.Status?["state"], "nodes").Count;
        return $"работает · нод {nodes}" + (st.Pending ? " · не применено" : "");
    }

    private Brush DotOf(CascadeServer c)
    {
        var st = St(c);
        if (SessionOf(c) is null) return Amber;
        if (st.Error is not null || st.SrvError is not null) return Red;
        if (!st.Checked || st.Version is null) return Gray;
        if (!CascadeRemote.IsV2(st.Version)) return Amber;
        if (!B(st.Status?["mihomo"], "active")) return Red;
        return st.Pending ? Amber : Green;
    }

    private async void ServerList_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingUi) return;
        RenderAll();
        await RefreshAsync();
    }

    /// <summary>SSH-сессия каскад-сервера: по id → по хосту → по имени (хост — и из имени вида «1.2.3.4 NAME»).
    /// Сессию пересоздали, или на другом устройстве у неё другой id — сервер не теряется.
    /// Неоднозначно (две сессии на один хост с разными именами) — null: пусть выберут руками.</summary>
    private Session? SessionOf(CascadeServer c)
    {
        var all = _store.Sessions();
        if (Guid.TryParse(c.Ssh, out var id) && all.FirstOrDefault(s => s.Id == id) is { } byId) return byId;
        var byName = all.Where(s => SameName(s.Name, c.Name)).ToList();
        var host = c.Host is { Length: > 0 } h ? h : HostFromName(c.Name);
        if (host is not null)
        {
            var byHost = all.Where(s => string.Equals(s.Host.Trim(), host, StringComparison.OrdinalIgnoreCase)).ToList();
            if (byHost.Count == 1) return byHost[0];
            if (byHost.Count > 1) return byHost.Where(byName.Contains).ToList() is { Count: 1 } both ? both[0] : null;
        }
        return byName.Count == 1 ? byName[0] : null;
    }

    private static bool SameName(string a, string b) =>
        string.Equals(System.Text.RegularExpressions.Regex.Replace(a.Trim(), @"\s+", " "),
                      System.Text.RegularExpressions.Regex.Replace(b.Trim(), @"\s+", " "), StringComparison.OrdinalIgnoreCase);

    /// <summary>«176.109.100.158 LAP» → 176.109.100.158 (так ноды QTerm называются по умолчанию).</summary>
    private static string? HostFromName(string name)
    {
        var m = System.Text.RegularExpressions.Regex.Match(name.Trim(), @"^(\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f:]*:[0-9A-Fa-f:]+)(?:\s|$)");
        return m.Success ? m.Groups[1].Value : null;
    }

    private Guid? SidOf(CascadeServer c) => SessionOf(c)?.Id;

    private CascadeRemote Remote(CascadeServer c)
    {
        var exec = ExecInSession ?? throw new XuiException("SSH QTerm недоступен из этого окна");
        var sid = SidOf(c) ?? throw new XuiException($"у «{c.Name}» нет SSH-сессии в QTerm — «Выбрать сессию…»");
        if (!_remotes.TryGetValue(c.Id, out var r))
            _remotes[c.Id] = r = new CascadeRemote((cmd, t) => exec(sid, cmd, t));
        return r;
    }

    /// <summary>Одна операция за раз; ошибки — в лог; после — опрос сервера. true — прошла без ошибок.</summary>
    private async Task<bool> Op(string title, Func<CascadeServer, CascadeRemote, Task> op, bool refresh = true)
    {
        if (_busy) { Log("! дождись окончания текущей операции", LogKind.Warn); return false; }
        if (Sel is not { } c) { XuiDialog.Info(this, "Сначала добавь каскад-сервер: «＋ Сервер…»", "Каскад"); return false; }
        _busy = true;
        Cursor = Cursors.AppStarting;
        Log($"━━ {title} · {c.Name}", LogKind.Head);
        var ok = false;
        try
        {
            await op(c, Remote(c));
            ok = true;
        }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); }
        finally { _busy = false; Cursor = null; }
        if (refresh) await RefreshAsync(quiet: true, detect: _seg == "who");
        return ok;
    }

    private async Task TickAsync()
    {
        if (!IsVisible || WindowState == WindowState.Minimized || _busy || _refreshing) return;
        if (Sel is not { } c || SidOf(c) is not { } sid) return;
        if (SessionConnected?.Invoke(sid) != true) return;     // авто — только по живому соединению
        await RefreshAsync(quiet: true);
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        _whoFor = null;     // явное обновление — выбор в «Кто идёт» тоже с сервера
        await RefreshAsync(detect: true);
    }

    /// <summary>Опрос сервера. Нет связи (SSH) — прежняя картинка остаётся (обрыв — не повод гасить экран).
    /// Связь есть, а qcascade status не ответил — статус сбрасывается, карточка показывает ошибку и путь
    /// (обычно «Обновить до …»): показывать старый статус — значит врать (так v1-статус выдавался за v2).</summary>
    private async Task RefreshAsync(bool quiet = false, bool detect = false)
    {
        if (Sel is not { } c) { RenderAll(); return; }
        if (ExecInSession is null || _refreshing) return;
        var st = St(c);
        if (SessionOf(c) is null) { st.Error = null; RenderServers(); return; }   // карточка «Выбрать сессию…»
        _refreshing = true;
        if (!quiet) HeadStatus.Text = $"опрашиваю «{c.Name}»…";
        try
        {
            var r = Remote(c);
            var ver = await r.RemoteVersionAsync();
            st.Error = null;
            if (st.Version != ver) { st.Status = null; st.Detect = null; }   // другая версия — прежнее не годится
            st.Version = ver;
            st.Checked = true;
            st.At = DateTime.Now;
            if (ver is null) { st.Pending = false; st.SrvError = null; }
            else
            {
                try
                {
                    st.Status = await r.StatusAsync();
                    st.SrvError = null;
                    if (st.Status["pending"] is JsonValue pv && pv.TryGetValue<bool>(out var p) && p) st.Pending = true;
                }
                catch (Exception ex)
                {
                    if (!quiet || st.SrvError != ex.Message) Log("✗ " + ex.Message, LogKind.Err);
                    st.SrvError = ex.Message;
                    st.Status = null;
                }
                if (st.Status is not null && CascadeRemote.IsV2(ver) && (detect || st.Detect is null || _seg == "who"))
                {
                    try { st.Detect = await r.DetectAsync(); }
                    catch (Exception ex) { if (!quiet) Log("✗ " + ex.Message, LogKind.Err); }
                }
            }
        }
        catch (Exception ex)
        {
            if (!quiet || st.Error != ex.Message) Log("✗ " + ex.Message, LogKind.Err);
            st.Error = ex.Message;
        }
        finally { _refreshing = false; }
        RenderServers();
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
        SourcesView.Visibility = s == "sources" ? Visibility.Visible : Visibility.Collapsed;
        WhoView.Visibility = s == "who" ? Visibility.Visible : Visibility.Collapsed;
        GroupsView.Visibility = s == "groups" ? Visibility.Visible : Visibility.Collapsed;
        RulesView.Visibility = s == "rules" ? Visibility.Visible : Visibility.Collapsed;
        JournalView.Visibility = s == "journal" ? Visibility.Visible : Visibility.Collapsed;
        foreach (var b in new[] { SegOverview, SegSources, SegWho, SegGroups, SegRules, SegJournal })
            b.SetResourceReference(BackgroundProperty, (string)b.Tag == s ? "SelBrush" : "Panel2Brush");
        RenderCard();
        if (!IsLoaded) return;
        switch (s)
        {
            case "who": _ = RefreshAsync(quiet: true, detect: true); break;
            case "groups": _ = LoadGroupsAsync(); break;
            case "rules": _ = LoadRulesAsync(); break;
            case "journal": _ = LoadJournalAsync(); break;
        }
    }

    // ── отрисовка ──

    private static string S(JsonNode? n, string k)
    {
        var v = n?[k];
        if (v is JsonValue jv) return jv.TryGetValue<string>(out var s) ? s : jv.ToJsonString().Trim('"');
        return "";
    }

    private static bool B(JsonNode? n, string k) =>
        n?[k] is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    private static List<string> L(JsonNode? n, string k) =>
        n?[k] is JsonArray a ? a.Select(x => x is JsonValue v && v.TryGetValue<string>(out var s) ? s : x?.ToJsonString() ?? "")
                                .Where(x => x.Length > 0).ToList() : new();

    private static int? I(JsonNode? n, string k) =>
        n?[k] is JsonValue v && v.TryGetValue<int>(out var i) ? i : null;

    private bool Ready(out CascadeServer c, out ServerState st)
    {
        c = Sel!;
        st = c is null ? new ServerState() : St(c);
        return c is not null && st.Status is not null && CascadeRemote.IsV2(st.Version);
    }

    private void RenderAll()
    {
        RenderHeader();
        RenderCard();
        RenderOverview();
        RenderSources();
        RenderWho(full: _whoFor != Sel?.Id);
        RenderDirect();
    }

    private void RenderHeader()
    {
        var c = Sel;
        HeadName.Text = c?.Name ?? "Каскад";
        InstallBtn.Visibility = c is null ? Visibility.Collapsed : Visibility.Visible;
        ApplyBtn.Visibility = c is null ? Visibility.Collapsed : Visibility.Visible;
        if (c is null) { HeadStatus.Text = ""; return; }
        var st = St(c);
        var mine = CascadeRemote.ScriptVersion;
        InstallBtn.Content = st.Version is null ? "Установить…"
            : CascadeRemote.Newer(mine, st.Version) ? $"Обновить до {mine}…" : "Переустановить…";
        ApplyBtn.Content = st.Pending ? "Применить ●" : "Применить";
        ApplyBtn.SetResourceReference(BackgroundProperty, st.Pending ? "SelBrush" : "Panel2Brush");
        ApplyBtn.IsEnabled = st.Status is not null && CascadeRemote.IsV2(st.Version);
        if (SessionOf(c) is null) { HeadStatus.Text = "нет SSH-сессии в QTerm"; return; }
        if (!st.Checked) { HeadStatus.Text = st.Error is { } e0 ? "✗ " + e0 : ""; return; }
        if (st.Error is { } e) { HeadStatus.Text = "✗ " + e; return; }
        if (st.Version is null) { HeadStatus.Text = "каскад не установлен"; return; }
        if (st.SrvError is not null) { HeadStatus.Text = $"qcascade {st.Version} · статус не отдаётся"; return; }
        var mh = st.Status?["mihomo"];
        HeadStatus.Text = $"qcascade {st.Version} · mihomo {S(mh, "version")} " +
                          (B(mh, "active") ? "работает" : "НЕ РАБОТАЕТ") +
                          (st.Pending ? " · есть неприменённые изменения" : "") + $" · {st.At:HH:mm:ss}";
    }

    /// <summary>Карточка поверх разделов: нет серверов / нет связи / не установлен / старая версия.</summary>
    private void RenderCard()
    {
        var c = Sel;
        string? title = null, text = null, btn = null;
        if (c is null)
        {
            title = "Каскад-серверов пока нет";
            text = "Каскад — сервер (с 3x-ui, AWG-панелью, MTProto-прокси), который ведёт трафик своих клиентов " +
                   "через mihomo с правилами как на Кинетиках:\n\n" +
                   "• ноды — из своих источников: отдельный клиент каскада на любой панели 3x-ui со своим набором инбаундов, " +
                   "ссылки подписок отдельных нод, WireGuard/AWG (можно резервом);\n" +
                   "• через каскад идут клиенты 3x-ui (VLESS, Hysteria), AWG-панели и Telegram-трафик MTProto-прокси;\n" +
                   "• всё, что не DIRECT, при недоступности нод уходит в резерв.\n\n" +
                   "«＋ Сервер…» → SSH-сессия сервера → «Установить…».";
            btn = "＋ Сервер…";
            _cardAction = "add";
        }
        else
        {
            var st = St(c);
            var mine = CascadeRemote.ScriptVersion;
            if (SessionOf(c) is null)
            {
                title = $"У «{c.Name}» нет SSH-сессии в QTerm";
                text = "Сессию, к которой был привязан сервер, удалили или пересоздали (или она с другого устройства и ещё " +
                       "не доехала синком), а по хосту и имени однозначно не нашлась.\n\n«Выбрать сессию…» — привязать сервер " +
                       "к SSH-сессии заново: на сервере ничего не меняется.";
                btn = "Выбрать сессию…";
                _cardAction = "relink";
            }
            else if (!st.Checked && st.Error is { } e)
            {
                title = $"Нет связи с «{c.Name}»";
                text = e + "\n\nSSH-сессия сервера откроется вкладкой в QTerm (вход, ключи — как обычно).";
                btn = "Повторить";
                _cardAction = "refresh";
            }
            else if (st.Checked && st.Version is null && st.Error is null)
            {
                title = $"Каскад на «{c.Name}» не установлен";
                text = "«Установить…»: выбрать источники нод и кого пускать через каскад — QTerm сам зальёт скрипт, " +
                       "установка пойдёт на сервере в фоне (переживёт обрыв SSH), ход — в логе внизу.\n\n" +
                       "• mihomo отдельным сервисом, слушает только 127.0.0.1\n" +
                       "• правила и группы как на Кинетиках (свои .mrs роутеров встроены)\n" +
                       "• перехват клиентов 3x-ui — правкой шаблона Xray (с бэкапом базы и откатом), AWG-панели и MTProto — nftables\n" +
                       "• таймер раз в час сверяет источники\n\nНужен root (или sudo без пароля).";
                btn = "Установить…";
                _cardAction = "install";
            }
            else if (st.Version is not null && !CascadeRemote.IsV2(st.Version) && _seg != "journal")
            {
                title = $"На «{c.Name}» qcascade {st.Version} — QTerm работает с {mine}";
                text = "Нужно обновить скрипт на сервере. Подписка станет источником «SUB», правила, группы и перехват 3x-ui " +
                       "сохранятся. После обновления — свои источники нод, WireGuard и резерв, перехват AWG-панели и MTProto.";
                btn = $"Обновить до {mine}…";
                _cardAction = "install";
            }
            else if (st.Version is not null && st.SrvError is { } se && _seg != "journal")
            {
                var older = CascadeRemote.Newer(mine, st.Version);
                title = $"qcascade {st.Version} на «{c.Name}» не отдаёт статус";
                text = se + "\n\n" + (older
                    ? $"В QTerm скрипт новее ({mine}) — в нём это исправлено. «Обновить до {mine}…»: скрипт зальётся заново, " +
                      "источники нод, правила, группы, резерв и режимы перехвата на сервере сохраняются."
                    : "Подробности — в «Журнале». «Переустановить…» (вверху) зальёт скрипт заново, настройки сохранятся.");
                btn = older ? $"Обновить до {mine}…" : "Повторить";
                _cardAction = older ? "install" : "refresh";
            }
        }
        if (title is null) { CardView.Visibility = Visibility.Collapsed; return; }
        CardTitle.Text = title;
        CardText.Text = text ?? "";
        CardBtn.Content = btn;
        CardBtn.Visibility = btn is null ? Visibility.Collapsed : Visibility.Visible;
        CardView.Visibility = Visibility.Visible;
    }

    private async void CardBtn_Click(object sender, RoutedEventArgs e)
    {
        switch (_cardAction)
        {
            case "add": ServerAdd_Click(sender, e); break;
            case "refresh": await RefreshAsync(detect: true); break;
            case "relink": await RelinkAsync(); break;
            default: Install_Click(sender, e); break;
        }
    }

    private static string XrayText(string x) => x switch
    {
        "off" => "никто — клиенты 3x-ui идут напрямую",
        "all" => "все клиенты",
        "нет 3x-ui" => "на сервере нет 3x-ui",
        _ when x.StartsWith("users: ") => "клиенты: " + x[7..],
        _ when x.StartsWith("inbounds: ") => "инбаунды: " + x[10..],
        _ => x,
    };

    /// <summary>WEB-прокси и telemt (qcascade 2.0.2+): идут ли они через каскад; чего на сервере нет (по detect) — не пишем.</summary>
    private static string MtpSubsText(JsonNode? env, JsonNode? mtp)
    {
        if (S(env, "mtpWeb").Length == 0) return "";
        var t = "";
        if (mtp?["web"] is not JsonObject w || B(w, "present"))
            t += " · WEB-прокси: " + (S(env, "mtpWeb") == "middle" ? "напрямую (middle proxy)" : "через каскад");
        if (mtp?["telemt"] is not JsonObject tm || B(tm, "present"))
            t += " · telemt: " + (S(env, "mtpTelemt") == "middle" ? "напрямую (middle proxy)" : "через каскад");
        return t;
    }

    private void RenderOverview()
    {
        var rows = new List<GroupRow>();
        if (!Ready(out var c, out var st))
        {
            GroupList.ItemsSource = rows;
            InfoBox.Text = "";
            return;
        }
        var s = st.Status!;
        var env = s["env"];
        var state = s["state"];
        var reserve = S(env, "reserve");
        if (s["groups"] is JsonArray ga)
            foreach (var g in ga.OfType<JsonObject>())
            {
                var name = S(g, "name");
                if (B(g, "missing")) { rows.Add(new GroupRow { Name = name, Node = "—", Delay = "нет группы", Dot = Red }); continue; }
                var node = S(g, "node");
                var d = I(g, "delay");
                var direct = g["delay"] is null;
                var res = B(g, "reserve");
                rows.Add(new GroupRow
                {
                    Name = name,
                    Node = node + (res ? "  (резерв)" : ""),
                    Delay = direct ? "напрямую" : d > 0 ? $"{d} мс" : d < 0 ? "ещё не проверялась" : "нет ответа",
                    Dot = direct ? Amber : d > 0 ? (res ? Amber : Green) : d < 0 ? Gray : Red,
                });
            }
        GroupList.ItemsSource = rows;

        var sb = new StringBuilder();
        var mh = s["mihomo"];
        sb.AppendLine($"mihomo      {(B(mh, "active") ? "работает" : "НЕ РАБОТАЕТ — «Журнал»")} {S(mh, "version")}");
        var built = S(state, "built");
        if (DateTimeOffset.TryParse(built, out var bt)) built = bt.LocalDateTime.ToString("dd.MM HH:mm");
        sb.AppendLine($"qcascade    {st.Version} · конфиг собран {(built.Length > 0 ? built : "—")}");
        var srcState = (state?["sources"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
        var srcs = (s["sources"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(CascadeSource.From).ToList();
        if (srcs.Count == 0) sb.AppendLine("источники   НЕТ — «Источники нод»");
        else
            sb.AppendLine("источники   " + string.Join(", ", srcs.Select(x =>
            {
                var ss = srcState.FirstOrDefault(y => S(y, "name") == x.Name);
                var what = !x.Enabled ? "выкл" : x.IsWg ? "WireGuard" : ss is null ? "не применён" : $"{I(ss, "nodes") ?? 0} нод";
                return $"{x.Name} ({what})";
            })));
        var nodes = L(state, "nodes");
        if (nodes.Count > 0) sb.AppendLine($"ноды        {string.Join(", ", nodes)}");
        sb.AppendLine($"резерв      {(reserve.Length > 0 ? reserve : "нет")}");
        sb.AppendLine($"DIRECT →    {(S(env, "directTarget") is { Length: > 0 } dt ? dt : "DIRECT")}");
        sb.AppendLine();
        sb.AppendLine($"3x-ui       {XrayText(S(s, "xray"))}");
        var am = S(env, "awgMode");
        sb.AppendLine("AWG-панель  " + (am switch
        {
            "all" => "все интерфейсы wg*/awg*",
            "list" => "интерфейсы: " + S(env, "awgIfaces"),
            _ => "никто",
        }) + (am != "off" && S(env, "awgSrc").Length > 0 ? $" · только {S(env, "awgSrc")}" : ""));
        sb.AppendLine($"MTProto     {(S(env, "mtp") == "on" ? "Telegram — через каскад" + MtpSubsText(env, st.Detect?["mtp"]) : "выключено")}");
        if (am != "off" || S(env, "mtp") == "on")
            sb.AppendLine($"nftables    {(B(s, "nf") ? "правила перехвата стоят" : "НЕ СТОЯТ — «Применить» или «Журнал»")}");

        var warn = new List<string>();
        foreach (var x in srcState.Where(x => S(x, "error").Length > 0)) warn.Add($"{S(x, "name")}: {S(x, "error")}");
        if (L(state, "duplicates") is { Count: > 0 } dup) warn.Add($"одинаковые имена нод в разных источниках: {string.Join(", ", dup)} — задай источнику префикс");
        if (L(state, "reserveMissing") is { Count: > 0 } rm) warn.Add($"резерв «{string.Join(", ", rm)}» не найден среди нод — резерв выключен");
        if (L(state, "missingRulesets") is { Count: > 0 } mr) warn.Add($"нет rule-set на сервере (правила пропущены): {string.Join(", ", mr)}");
        var fallback = reserve.Length > 0 ? "резерв" : "DIRECT";
        if (L(state, "placeholders") is { Count: > 0 } ph) warn.Add($"правила ссылаются на то, чего нет в источниках (→ {fallback}): {string.Join(", ", ph)}");
        if (L(state, "emptyGroups") is { Count: > 0 } eg) warn.Add($"группы без нод из источников (→ {fallback}): {string.Join(", ", eg)}");
        if (st.Pending) warn.Add("есть неприменённые изменения — «Применить»");
        if (warn.Count > 0)
        {
            sb.AppendLine();
            foreach (var w in warn) sb.AppendLine("[!] " + w);
        }
        InfoBox.Text = sb.ToString().TrimEnd();
    }

    // ── установка / обновление ──

    private async void Install_Click(object sender, RoutedEventArgs e)
    {
        if (Sel is not { } c) { XuiDialog.Info(this, "Сначала добавь каскад-сервер: «＋ Сервер…»", "Каскад"); return; }
        if (_busy) { Log("! дождись окончания текущей операции", LogKind.Warn); return; }
        string? ver;
        try { ver = await Remote(c).RemoteVersionAsync(); }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); return; }
        var mine = CascadeRemote.ScriptVersion;
        List<CascadeSource>? first = null;
        Dictionary<string, string>? env = null;
        if (ver is null)
        {
            var plan = await InstallDialogAsync(c);
            if (plan is null) return;
            first = plan.Value.Sources;
            env = plan.Value.Env;
        }
        else
        {
            var text = CascadeRemote.Newer(mine, ver)
                ? $"На «{c.Name}» qcascade {ver}, в QTerm — {mine}.\n\nЗалить скрипт из QTerm и прогнать установку? " +
                  "Источники (подписка v1 станет источником «SUB»), правила, группы и режимы перехвата на сервере сохраняются."
                : CascadeRemote.Newer(ver, mine)
                    ? $"На «{c.Name}» qcascade {ver} — новее, чем в QTerm ({mine}). Всё равно поставить {mine}?"
                    : $"Переустановить qcascade {mine} на «{c.Name}»? Настройки, источники, правила и группы сохраняются.";
            if (!XuiDialog.Confirm(this, text, "Каскад", CascadeRemote.Newer(mine, ver) ? "Обновить" : "Переустановить")) return;
        }

        await Op(ver is null ? "Установка каскада" : $"Установка qcascade {mine}", async (cs, r) =>
        {
            Log($"  заливаю скрипт qcascade {mine}…", LogKind.Dim);
            await r.UploadScriptAsync();
            if (env is not null) await r.SetAsync(env, viaScript: true);
            Log("  установка идёт на сервере в фоне (переживёт обрыв SSH):", LogKind.Dim);
            await r.StartInstallAsync(first is null ? null : CascadeRemote.SourcesJson(first));
            var have = 0;
            var fails = 0;
            var t0 = DateTime.UtcNow;
            int? rc = null;
            while (rc is null)
            {
                await Task.Delay(1500);
                if ((DateTime.UtcNow - t0).TotalMinutes > 20)
                    throw new XuiException("установка идёт дольше 20 минут — лог на сервере: ~/.qcascade-install.log");
                try
                {
                    var (lines, total, prc) = await r.PollInstallAsync(have);
                    LogQc(string.Join("\n", lines));
                    have = total;
                    rc = prc;
                    fails = 0;
                }
                catch (Exception ex) when (++fails < 10)
                {
                    if (fails == 1) Log($"  … связь с сервером: {ex.Message} — жду", LogKind.Warn);
                    await Task.Delay(3000);
                }
            }
            if (rc != 0) throw new XuiException($"установка закончилась с ошибкой (код {rc}) — причина выше");
            St(cs).Pending = false;
            Log($"  ✓ каскад на «{cs.Name}» работает", LogKind.Ok);
        });
    }

    // ── применить ──

    private async Task ApplyAsync(CascadeServer c, CascadeRemote r)
    {
        var res = await r.QcAsync("apply", 600);
        LogQc(res.Out);
        if (!res.Ok) throw new XuiException("конфиг не применён — работает прежний (причина выше)");
        St(c).Pending = false;
    }

    private async void Apply_Click(object sender, RoutedEventArgs e) =>
        await Op("Применить", async (c, r) => await ApplyAsync(c, r));

    // ── сервер: добавить / убрать ──

    private async void ServerAdd_Click(object sender, RoutedEventArgs e)
    {
        var sessions = _store.Sessions();
        if (sessions.Count == 0) { XuiDialog.Info(this, "В QTerm нет SSH-сессий — сначала добавь ноду сервера", "Каскад"); return; }
        var items = sessions.Select(x => $"{x.Name}   ·   {(x.Username.Length > 0 ? x.Username + "@" : "")}{x.Host}").ToList();
        var pick = XuiDialog.Pick(this,
            "SSH-сессия сервера, который станет каскадом: трафик его клиентов (3x-ui, AWG-панель, MTProto) пойдёт в mihomo " +
            "с правилами как на Кинетиках. Нужен root или sudo без пароля.",
            "Каскад-сервер", items, null, "Добавить");
        if (pick is null) return;
        var idx = items.IndexOf(pick);
        var s = idx >= 0 ? sessions[idx] : sessions.FirstOrDefault(x => string.Equals(x.Name, pick.Trim(), StringComparison.OrdinalIgnoreCase));
        if (s is null) { XuiDialog.Info(this, $"Нет SSH-сессии «{pick}»", "Каскад"); return; }
        if (_store.Cascades().FirstOrDefault(c => SessionOf(c)?.Id == s.Id) is { } dup)
        {
            LoadServers(dup.Id);
            XuiDialog.Info(this, $"«{s.Name}» уже в списке каскадов", "Каскад");
            return;
        }
        var cs = new CascadeServer { Name = s.Name, Ssh = s.Id.ToString(), Host = s.Host.Trim() };
        _store.SaveCascade(cs);
        Log($"✓ каскад-сервер «{cs.Name}» добавлен", LogKind.Ok);
        LoadServers(cs.Id);
        await RefreshAsync();
    }

    /// <summary>Привязать каскад-сервер к SSH-сессии заново (сессию пересоздали / на этом устройстве её нет).</summary>
    private async Task RelinkAsync()
    {
        if (Sel is not { } c) return;
        var sessions = _store.Sessions();
        if (sessions.Count == 0) { XuiDialog.Info(this, "В QTerm нет SSH-сессий — сначала добавь ноду сервера", "Каскад"); return; }
        var items = sessions.Select(x => $"{x.Name}   ·   {(x.Username.Length > 0 ? x.Username + "@" : "")}{x.Host}").ToList();
        var guess = sessions.FindIndex(x => SameName(x.Name, c.Name));
        var pick = XuiDialog.Pick(this, $"SSH-сессия сервера «{c.Name}» (на сервере ничего не меняется):",
            "Каскад-сервер", items, guess >= 0 ? items[guess] : null, "Привязать");
        if (pick is null) return;
        var idx = items.IndexOf(pick);
        var s = idx >= 0 ? sessions[idx] : sessions.FirstOrDefault(x => SameName(x.Name, pick));
        if (s is null) { XuiDialog.Info(this, $"Нет SSH-сессии «{pick}»", "Каскад"); return; }
        if (_store.Cascades().FirstOrDefault(x => x.Id != c.Id && SessionOf(x)?.Id == s.Id) is { } other)
        {
            XuiDialog.Info(this, $"К «{s.Name}» уже привязан каскад-сервер «{other.Name}» — этот лишний, убери его", "Каскад");
            return;
        }
        c.Ssh = s.Id.ToString();
        c.Host = s.Host.Trim();
        _store.SaveCascade(c);
        _remotes.Remove(c.Id);
        _st.Remove(c.Id);
        Log($"✓ «{c.Name}» → SSH-сессия «{s.Name}»", LogKind.Ok);
        LoadServers(c.Id);
        await RefreshAsync(detect: true);
    }

    private async void ServerRemove_Click(object sender, RoutedEventArgs e)
    {
        if (Sel is not { } c) return;
        var st = St(c);
        var opts = new List<string>();
        if (st.Version is not null)
        {
            opts.Add("Снять перехват и удалить qcascade (источники, правила и группы на сервере оставить)");
            opts.Add("Удалить с сервера полностью (--purge)");
        }
        opts.Add("Только убрать сервер из списка QTerm");
        var pick = XuiDialog.Pick(this,
            $"«{c.Name}»: что сделать? Перехват снимается первым — клиенты сервера снова пойдут напрямую. " +
            "Клиенты каскада на панелях 3x-ui и AWG остаются (удалить — в «Источниках нод» до удаления сервера).",
            "Убрать каскад", opts, opts[^1], "Выполнить");
        if (pick is null || !opts.Contains(pick)) return;
        if (pick.StartsWith("Только"))
        {
            _store.DeleteCascade(c.Id);
            _remotes.Remove(c.Id);
            _st.Remove(c.Id);
            Log($"✓ «{c.Name}» убран из QTerm (на сервере ничего не трогал)", LogKind.Ok);
            LoadServers();
            await RefreshAsync();
            return;
        }
        var purge = pick.Contains("--purge");
        if (!XuiDialog.Confirm(this, $"Точно {(purge ? "удалить каскад полностью" : "удалить qcascade")} с «{c.Name}»?", "Убрать каскад", "Удалить")) return;
        await Op("Удаление каскада", async (cs, r) =>
        {
            var res = await r.QcAsync(purge ? "uninstall --purge" : "uninstall", 300);
            LogQc(res.Out);
            if (!res.Ok) throw new XuiException("не удалилось (причина выше)");
            _store.DeleteCascade(cs.Id);
            _remotes.Remove(cs.Id);
            _st.Remove(cs.Id);
            Log($"  ✓ каскад с «{cs.Name}» снят, сервер убран из QTerm", LogKind.Ok);
        }, refresh: false);
        LoadServers();
        await RefreshAsync();
    }

    // ── DIRECT ──

    private void RenderDirect()
    {
        _loadingUi = true;
        try
        {
            if (!Ready(out _, out var st)) { DirectBox.ItemsSource = null; DirectBox.IsEnabled = false; return; }
            var items = new List<string> { "DIRECT" };
            items.AddRange((st.Status!["groups"] as JsonArray ?? new JsonArray()).Select(g => S(g, "name")).Where(x => x.Length > 0));
            var cur = S(st.Status["env"], "directTarget");
            if (cur.Length == 0) cur = "DIRECT";
            if (!items.Contains(cur)) items.Add(cur);
            DirectBox.ItemsSource = items;
            DirectBox.SelectedItem = cur;
            DirectBox.IsEnabled = true;
        }
        finally { _loadingUi = false; }
    }

    private async void Direct_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingUi || DirectBox.SelectedItem is not string target) return;
        if (!Ready(out _, out var st) || S(st.Status!["env"], "directTarget") == target) return;
        await Op($"DIRECT → {target}", async (c, r) =>
        {
            await r.SetAsync(new Dictionary<string, string> { ["QC_DIRECT_TARGET"] = target });
            St(c).Pending = true;
            Log("  ✓ сохранено — в работу по «Применить»", LogKind.Ok);
        });
    }

    // ── группы и правила ──

    private async Task LoadGroupsAsync(bool force = false)
    {
        if (!Ready(out var c, out _)) { GroupsBox.Text = ""; _groupsFor = null; return; }
        if (!force && _groupsFor == c.Id) return;
        try
        {
            var text = await Remote(c).ReadRootFileAsync($"{Etc}/groups.conf");
            if (Sel?.Id != c.Id) return;
            _groupsText = text;
            _groupsFor = c.Id;
            GroupsBox.Text = text;
        }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); }
    }

    private async Task LoadRulesAsync(bool force = false)
    {
        if (!Ready(out var c, out _)) { RulesBox.Text = ""; _rulesFor = null; return; }
        if (!force && _rulesFor == c.Id) return;
        try
        {
            var text = await Remote(c).ReadRootFileAsync($"{Etc}/rules.yaml");
            if (Sel?.Id != c.Id) return;
            _rulesText = text;
            _rulesFor = c.Id;
            RulesBox.Text = text;
        }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); }
    }

    private async void GroupsReload_Click(object sender, RoutedEventArgs e) => await LoadGroupsAsync(force: true);
    private async void RulesReload_Click(object sender, RoutedEventArgs e) => await LoadRulesAsync(force: true);

    private async void GroupsSave_Click(object sender, RoutedEventArgs e) =>
        await SaveEditor("Группы", "groups.conf", GroupsBox, () => _groupsFor, t => _groupsText = t, () => _groupsText);

    private async void RulesSave_Click(object sender, RoutedEventArgs e) =>
        await SaveEditor("Правила", "rules.yaml", RulesBox, () => _rulesFor, t => _rulesText = t, () => _rulesText);

    private async Task SaveEditor(string title, string file, TextBox box, Func<Guid?> loadedFor, Action<string> setOrig, Func<string> orig)
    {
        if (!Ready(out var c, out _)) { XuiDialog.Info(this, "Каскад на сервере не установлен", "Каскад"); return; }
        if (loadedFor() != c.Id) { XuiDialog.Info(this, "Текст ещё не загружен с сервера — «Вернуть»", "Каскад"); return; }
        var text = box.Text.Replace("\r\n", "\n");
        if (text.TrimEnd() == orig().Replace("\r\n", "\n").TrimEnd() && !St(c).Pending)
        { XuiDialog.Info(this, "Изменений нет", "Каскад"); return; }
        await Op($"{title}: сохранить и применить", async (cs, r) =>
        {
            var path = $"{Etc}/{file}";
            await r.WriteRootFileAsync(path, text);
            setOrig(text);
            Log($"  ✓ {path} записан", LogKind.Ok);
            await ApplyAsync(cs, r);
        });
    }

    // ── журнал, ядро, панель mihomo ──

    private async void JournalRefresh_Click(object sender, RoutedEventArgs e) => await LoadJournalAsync();

    private async Task LoadJournalAsync()
    {
        if (Sel is not { } c || St(c).Version is null) { JournalBox.Text = ""; return; }
        try
        {
            var text = await Remote(c).LogsAsync(300);
            if (Sel?.Id != c.Id) return;
            JournalBox.Text = text;
            JournalBox.CaretIndex = JournalBox.Text.Length;
            JournalBox.ScrollToEnd();
        }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); }
    }

    private async void Core_Click(object sender, RoutedEventArgs e)
    {
        if (!Ready(out _, out var st)) { XuiDialog.Info(this, "Каскад на сервере не установлен", "Каскад"); return; }
        var cur = S(st.Status!["env"], "mihomoUrl");
        var f = XuiDialog.Form(this,
            "Ядро mihomo. Пусто — последний стоковый MetaCubeX. Своя сборка (например ff148 с firefox-отпечатком) — прямая ссылка " +
            "на .gz или бинарь под архитектуру сервера. Новое ядро сначала проверяет текущий конфиг, при сбое — откат.",
            "Ядро mihomo", new[] { new XuiDialog.Field("Ссылка на ядро (пусто — стоковое)", cur) }, "Обновить");
        if (f is null) return;
        var url = f[0].Trim();
        await Op("Ядро mihomo", async (_, r) =>
        {
            if (url != cur) await r.SetAsync(new Dictionary<string, string> { ["QC_MIHOMO_URL"] = url });
            var res = await r.QcAsync("update-core", 600);
            LogQc(res.Out);
            if (!res.Ok) throw new XuiException("ядро не обновилось (причина выше)");
        });
    }

    /// <summary>zashboard: API mihomo слушает только 127.0.0.1 сервера — туннель SSH, адрес и secret.</summary>
    private async void Dashboard_Click(object sender, RoutedEventArgs e)
    {
        if (!Ready(out var c, out var st)) { XuiDialog.Info(this, "Каскад на сервере не установлен", "Каскад"); return; }
        var api = S(st.Status!["env"], "api");
        if (api.Length == 0) { XuiDialog.Info(this, "Сервер не сообщил адрес API mihomo", "Каскад"); return; }
        var port = api[(api.LastIndexOf(':') + 1)..];
        var sess = SessionOf(c);
        var target = sess is null ? "root@<сервер>"
            : $"{(sess.Username.Length > 0 ? sess.Username + "@" : "")}{sess.Host}" + (sess.Port is 22 or 0 ? "" : $" -p {sess.Port}");
        string secret;
        try
        {
            var envText = await Remote(c).ReadRootFileAsync($"{Etc}/env");
            const string key = "QC_SECRET=";
            var line = envText.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.StartsWith(key)) ?? "";
            secret = line.Length > key.Length ? line[key.Length..].Trim('\'', '"') : "";
        }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); return; }
        XuiDialog.Secret(this,
            $"API mihomo слушает только {api} на сервере. Туннель (в отдельном терминале):\n\n" +
            $"  ssh -N -L {port}:{api} {target}\n\nпотом в браузере: http://127.0.0.1:{port}/ui  " +
            $"(бэкенд 127.0.0.1:{port}). Secret — ниже.",
            "Панель mihomo", secret);
    }
}
