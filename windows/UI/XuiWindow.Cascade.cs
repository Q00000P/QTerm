using System.Text;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>
/// Раздел «Каскад»: сервер с 3x-ui (+ AWG) как маршрутизатор «как на Кинетике» — mihomo с правилами роутеров,
/// ноды из Clash-подписки главной, трафик клиентов 3x-ui (VLESS, Hysteria, встроенный AWG) перехватывается в mihomo.
/// На сервере — qcascade (scripts/vpn-cascade.sh, встроен в QTerm и заливается сам); QTerm управляет им
/// отдельным exec-каналом SSH-сессии, терминал не трогается.
/// </summary>
public partial class XuiWindow
{
    public sealed class CascRow
    {
        public string Name { get; init; } = "";
        public string Node { get; init; } = "";
        public string Delay { get; init; } = "";
        public Brush Dot { get; init; } = Brushes.Gray;
    }

    /// <summary>exec по SSH-сессии: (id сессии, команда, таймаут с) → stdout. Задаёт главное окно.</summary>
    public Func<Guid, string, int, Task<string>>? ExecInSession { get; set; }
    /// <summary>Есть ли живое соединение сессии — автообновление не должно открывать вкладки само.</summary>
    public Func<Guid, bool>? SessionConnected { get; set; }

    private const string CascConf = "/etc/qcascade";
    private List<CascadeServer> _cascades = new();
    private JsonObject? _cascStatus;
    private string? _cascVersion;
    private bool _cascBusy, _cascRefreshing, _cascLoading;
    private readonly Dictionary<Guid, CascadeRemote> _cascRemotes = new();

    private CascadeServer? CascSel => CascBox.SelectedItem as CascadeServer;

    private void ShowCascade()
    {
        LoadCascades();
        if (IsLoaded) _ = RefreshCascadeAsync();
        else Loaded += async (_, _) => { if (_seg == "cascade") await RefreshCascadeAsync(); };
    }

    private void LoadCascades(Guid? pick = null)
    {
        var keep = pick ?? CascSel?.Id;
        _cascLoading = true;
        _cascades = _store.Cascades();
        CascBox.ItemsSource = _cascades;
        CascBox.SelectedItem = _cascades.FirstOrDefault(c => c.Id == keep) ?? _cascades.FirstOrDefault();
        _cascLoading = false;
        if (_cascades.Count == 0)
        {
            _cascStatus = null;
            _cascVersion = null;
            CascStatus.Text = "Нет каскад-серверов — «＋ Сервер…»";
            RenderCascade();
        }
    }

    private async void CascBox_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_cascLoading) return;
        _cascStatus = null;
        _cascVersion = null;
        RenderCascade();
        await RefreshCascadeAsync();
    }

    private bool CascSid(CascadeServer c, out Guid sid)
    {
        if (!Guid.TryParse(c.Ssh, out var id)) { sid = Guid.Empty; return false; }
        sid = id;
        return _store.Sessions().Any(s => s.Id == id);
    }

    private CascadeRemote Remote(CascadeServer c)
    {
        if (ExecInSession is null) throw new XuiException("SSH QTerm недоступен из этого окна");
        if (!CascSid(c, out var sid))
            throw new XuiException($"у «{c.Name}» нет SSH-сессии в QTerm — убери сервер и добавь заново");
        if (!_cascRemotes.TryGetValue(c.Id, out var r))
            _cascRemotes[c.Id] = r = new CascadeRemote((cmd, t) => ExecInSession(sid, cmd, t));
        return r;
    }

    /// <summary>Одна операция за раз; ошибки — в лог; после — статус.</summary>
    private async Task CascOp(string title, Func<CascadeServer, CascadeRemote, Task> op, bool refresh = true)
    {
        if (_cascBusy || _busy || _updBusy) { Log("! дождись окончания текущей операции", LogKind.Warn); return; }
        if (CascSel is not { } c) { XuiDialog.Info(this, "Сначала добавь каскад-сервер: «＋ Сервер…»"); return; }
        _cascBusy = true;
        Cursor = Cursors.AppStarting;
        Log($"━━ {title} · {c.Name}", LogKind.Head);
        try { await op(c, Remote(c)); }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); }
        finally { _cascBusy = false; Cursor = null; }
        if (refresh) await RefreshCascadeAsync(quiet: true);
    }

    /// <summary>Вывод qcascade — в лог построчно, с цветом по [ok] / [!!] / [ERR].</summary>
    private void LogQc(string text)
    {
        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            var l = raw.TrimEnd();
            if (l.Length == 0) continue;
            var kind = l.StartsWith("[ok]") ? LogKind.Ok : l.StartsWith("[!!]") ? LogKind.Warn
                     : l.StartsWith("[ERR]") ? LogKind.Err : l.StartsWith("──") ? LogKind.Head : LogKind.Info;
            Log("  " + l, kind);
        }
    }

    private async Task CascTickAsync()
    {
        if (_cascBusy || _cascRefreshing || CascSel is not { } c || !CascSid(c, out var sid)) return;
        if (SessionConnected?.Invoke(sid) != true) return;    // авто — только по живому соединению
        await RefreshCascadeAsync(quiet: true);
    }

    private async void CascRefresh_Click(object sender, RoutedEventArgs e) => await RefreshCascadeAsync();

    private async Task RefreshCascadeAsync(bool quiet = false)
    {
        if (CascSel is not { } c) { _cascStatus = null; RenderCascade(); return; }
        if (ExecInSession is null || _cascRefreshing) return;
        _cascRefreshing = true;
        if (!quiet) CascStatus.Text = $"опрашиваю «{c.Name}»…";
        try
        {
            var r = Remote(c);
            var ver = await r.RemoteVersionAsync();
            if (CascSel?.Id != c.Id) return;
            _cascVersion = ver;
            if (ver is null)
            {
                _cascStatus = null;
                CascStatus.Text = $"«{c.Name}»: каскад не установлен — «Установить / обновить…»";
                RenderCascade();
                return;
            }
            _cascStatus = await r.StatusAsync();
            if (CascSel?.Id != c.Id) return;
            var mine = CascadeRemote.ScriptVersion;
            CascStatus.Text = $"«{c.Name}» · qcascade {ver}" +
                              (CascadeRemote.Newer(mine, ver) ? $" — в QTerm новее ({mine}): «Установить / обновить…»" : "") +
                              $" · {DateTime.Now:HH:mm:ss}";
            RenderCascade();
        }
        catch (Exception ex)
        {
            CascStatus.Text = "✗ " + ex.Message;
            if (!quiet) Log("✗ " + ex.Message, LogKind.Err);
        }
        finally { _cascRefreshing = false; }
    }

    private static string S(JsonNode? n, string k) { try { return n?[k]?.GetValue<string>() ?? ""; } catch { return n?[k]?.ToString() ?? ""; } }
    private static bool B(JsonNode? n, string k) { try { return n?[k]?.GetValue<bool>() == true; } catch { return false; } }
    private static List<string> L(JsonNode? n, string k) =>
        n?[k] is JsonArray a ? a.Select(x => x?.ToString() ?? "").Where(x => x.Length > 0).ToList() : new();

    private static string XrayText(string x) => x switch
    {
        "off" => "выключен — клиенты идут напрямую",
        "all" => "все клиенты 3x-ui",
        "нет 3x-ui" => "на сервере нет 3x-ui",
        _ when x.StartsWith("users: ") => "клиенты: " + x[7..],
        _ when x.StartsWith("inbounds: ") => "инбаунды: " + x[10..],
        _ => x,
    };

    private void RenderCascade()
    {
        var rows = new List<CascRow>();
        var st = _cascStatus;
        if (st is null)
        {
            CascGroups.ItemsSource = rows;
            CascInfo.Text = CascSel is null
                ? "Каскад: сервер с 3x-ui (и AWG) становится маршрутизатором «как на Кинетике».\n\n" +
                  "• mihomo с правилами и группами роутеров (TG, EU, FII, T, MSK…)\n" +
                  "• ноды — из Clash-подписки главной (единая подписка)\n" +
                  "• трафик клиентов 3x-ui (VLESS, Hysteria, встроенный AWG) уходит в mihomo\n\n" +
                  "«＋ Сервер…» → выбрать SSH-сессию → «Установить / обновить…»."
                : _cascVersion is null && CascStatus.Text.Contains("не установлен")
                    ? "qcascade на сервере нет.\n\n«Установить / обновить…»: QTerm сам зальёт скрипт, спросит подписку и кого каскадить, " +
                      "установка пойдёт на сервере в фоне (переживёт обрыв SSH), ход — в логе внизу.\n\nНужен root (или sudo без пароля)."
                    : "";
            return;
        }

        if (st["groups"] is JsonArray ga)
            foreach (var g in ga)
            {
                if (g is null) continue;
                var name = S(g, "name");
                if (B(g, "missing")) { rows.Add(new CascRow { Name = name, Node = "—", Delay = "нет группы", Dot = Red }); continue; }
                var node = S(g, "node");
                int? d = null;
                try { if (g["delay"] is JsonValue v) d = v.GetValue<int>(); } catch { }
                var direct = node is "DIRECT" or "REJECT" or "REJECT-DROP" || g["delay"] is null;
                rows.Add(new CascRow
                {
                    Name = name, Node = node,
                    Delay = direct ? "напрямую" : d > 0 ? $"{d} мс" : "нет ответа",
                    Dot = direct ? Amber : d > 0 ? Green : Red,
                });
            }
        CascGroups.ItemsSource = rows;

        var sb = new StringBuilder();
        var mh = st["mihomo"];
        var env = st["env"];
        var state = st["state"];
        sb.AppendLine($"mihomo:      {(B(mh, "active") ? "работает" : "НЕ РАБОТАЕТ — «Журнал mihomo»")} {S(mh, "version")}");
        var nodes = L(state, "nodes");
        var built = S(state, "built");
        if (DateTimeOffset.TryParse(built, out var bt)) built = bt.LocalDateTime.ToString("dd.MM HH:mm");
        sb.AppendLine(B(env, "subSet")
            ? $"подписка:    {nodes.Count} нод · клиент {CascSel?.Client ?? "—"} · сборка {built}"
            : "подписка:    НЕ ЗАДАНА — «Подписка…»");
        if (nodes.Count > 0) sb.AppendLine($"ноды:        {string.Join(", ", nodes)}");
        sb.AppendLine($"перехват:    {XrayText(S(st, "xray"))}");
        sb.AppendLine($"DIRECT →     {(S(env, "directTarget") is { Length: > 0 } dt ? dt : "DIRECT")}");
        if (S(env, "mihomoUrl") is { Length: > 0 } mu) sb.AppendLine($"ядро:        своя сборка — {mu}");
        var miss = L(state, "missingRulesets");
        if (miss.Count > 0) sb.AppendLine($"\n[!] нет rule-set на сервере (правила пропущены): {string.Join(", ", miss)}");
        var ph = L(state, "placeholders");
        if (ph.Count > 0) sb.AppendLine($"[!] правила ссылаются на то, чего нет в подписке (→ DIRECT): {string.Join(", ", ph)}");
        var empty = L(state, "emptyGroups");
        if (empty.Count > 0) sb.AppendLine($"[!] группы без нод из подписки (→ DIRECT): {string.Join(", ", empty)}");
        var api = S(env, "api");
        if (api.Length > 0)
        {
            var port = api[(api.LastIndexOf(':') + 1)..];
            sb.AppendLine($"\nпанель mihomo (zashboard): ssh -L {port}:{api} → http://127.0.0.1:{port}/ui");
            sb.AppendLine("secret — на сервере: grep QC_SECRET /etc/qcascade/env");
        }
        CascInfo.Text = sb.ToString().TrimEnd();
    }

    // ── сервер ──

    private async void CascAdd_Click(object sender, RoutedEventArgs e)
    {
        var sessions = _store.Sessions();
        if (sessions.Count == 0) { XuiDialog.Info(this, "В QTerm нет SSH-сессий — сначала добавь ноду сервера"); return; }
        var items = sessions.Select(x => $"{x.Name}   ·   {(x.Username.Length > 0 ? x.Username + "@" : "")}{x.Host}").ToList();
        var pick = XuiDialog.Pick(this,
            "SSH-сессия сервера, где стоят 3x-ui (и AWG). Он станет каскадом: трафик его клиентов пойдёт в mihomo с правилами как на Кинетике, ноды — из единой подписки.",
            "Каскад-сервер", items, null, "Добавить");
        if (pick is null) return;
        var idx = items.IndexOf(pick);
        var s = idx >= 0 ? sessions[idx] : sessions.FirstOrDefault(x => string.Equals(x.Name, pick.Trim(), StringComparison.OrdinalIgnoreCase));
        if (s is null) { XuiDialog.Info(this, $"Нет SSH-сессии «{pick}»"); return; }
        if (_store.Cascades().FirstOrDefault(c => c.Ssh.Equals(s.Id.ToString(), StringComparison.OrdinalIgnoreCase)) is { } dup)
        {
            LoadCascades(dup.Id);
            XuiDialog.Info(this, $"«{s.Name}» уже в списке каскадов");
            return;
        }
        var cs = new CascadeServer { Name = s.Name, Ssh = s.Id.ToString() };
        _store.SaveCascade(cs);
        Log($"✓ каскад-сервер «{cs.Name}» добавлен", LogKind.Ok);
        LoadCascades(cs.Id);
        await RefreshCascadeAsync();
    }

    // ── подписка ──

    private static string CascClientName(CascadeServer c)
    {
        var n = new string(c.Name.ToUpperInvariant().Where(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_').ToArray());
        return n.Length > 0 ? n : "CASCADE";
    }

    /// <summary>Clash-ссылка подписки для каскада: клиент главной / новый клиент на всех серверах / своя ссылка.</summary>
    private async Task<(string Url, string? Client)?> ChooseSubscription(CascadeServer c)
    {
        var hasMaster = _master is not null && _clients.Count > 0;
        var opts = new List<string>();
        if (hasMaster)
        {
            opts.Add("Клиент главной — выбрать из списка");
            opts.Add($"Новый клиент «{CascClientName(c)}» на всех серверах");
        }
        opts.Add("Своя ссылка (Clash / Mihomo)");
        var pick = XuiDialog.Pick(this,
            "Откуда каскаду брать ноды. Нужна Clash/Mihomo-подписка единой подписки главной: имена нод = имена инбаундов " +
            "(шаблон {{INBOUND}}), клиент привязан ко всем серверам. Ссылка уйдёт только на сервер (/etc/qcascade/env, 600)." +
            (hasMaster ? "" : "\n\nГлавная 3x-ui в QTerm не подключена — только своя ссылка."),
            "Подписка каскада", opts, opts[0], "Дальше");
        if (pick is null) return null;
        var choice = opts.IndexOf(pick);
        if (!hasMaster) choice += 2;

        try
        {
            if (choice is 0 or 1)
            {
                if (_settings.Count == 0) _settings = await _master!.SettingsAsync();
                XClient? cl;
                if (choice == 0)
                {
                    var emails = _clients.Select(x => x.Email).OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
                    var em = XuiDialog.Pick(this, "Клиент главной, чью подписку возьмёт каскад (лучше отдельный — у роутеров свои):",
                        "Подписка каскада", emails, c.Client is { } cc && emails.Contains(cc) ? cc : null);
                    if (em is null) return null;
                    cl = _clients.FirstOrDefault(x => x.Email == em);
                    if (cl is null) { XuiDialog.Info(this, $"Нет клиента «{em}»"); return null; }
                }
                else
                {
                    var name = InputDialog.Ask(this, "Имя клиента каскада (создастся на всех серверах):", CascClientName(c));
                    if (name is null) return null;
                    cl = await CreateCascClient(name);
                    if (cl is null) return null;
                }
                var link = LinkOf(cl, clash: true);
                if (link is null)
                {
                    XuiDialog.Info(this, "В главной выключена Clash-подписка (или у клиента нет ID подписки): " +
                                         "Настройки панели → Подписка → Clash / Mihomo — включить");
                    return null;
                }
                return (link, cl.Email);
            }
            var f = XuiDialog.Form(this, "Clash/Mihomo-ссылка подписки — уйдёт только на сервер, в QTerm не хранится.",
                "Подписка каскада", new[] { new XuiDialog.Field("Ссылка", "", Secure: true) }, "Дальше");
            var url = f?[0].Trim() ?? "";
            if (url.Length == 0) return null;
            if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            { XuiDialog.Info(this, "Нужна http(s)-ссылка подписки"); return null; }
            return (url, null);
        }
        catch (Exception ex)
        {
            Log("✗ подписка: " + ex.Message, LogKind.Err);
            return null;
        }
    }

    /// <summary>Клиент каскада на всех серверах единой подписки (имя через «Ревизию имён», как «＋ Клиент»).</summary>
    private async Task<XClient?> CreateCascClient(string name)
    {
        var u = Unifier();
        var toks = XuiOps.StripTokens(_inbounds, _nodes);
        var key = u.Analyze(name, toks).Key;
        if (_clients.FirstOrDefault(x => u.Analyze(x.Email, toks).Key == key) is { } exist)
        {
            if (!XuiDialog.Confirm(this, $"Клиент «{exist.Email}» уже есть — взять его подписку?", "Подписка каскада", "Взять")) return null;
            return exist;
        }
        var ids = _inbounds.Where(i => i.MultiUser && i.Enable).Select(i => i.Id).ToList();
        if (ids.Count == 0) { XuiDialog.Info(this, "На главной нет подходящих входящих"); return null; }
        var (pv, ph) = XuiOps.Protos(ids, _inbounds.ToDictionary(i => i.Id));
        var display = u.DisplayFor(key, new[] { name }, name, pv, ph);
        await _master!.AddClientAsync(display, ids);
        Log($"  ✓ клиент каскада {display}: входящих {ids.Count} на всех серверах", LogKind.Ok);
        _clients = await _master.ClientsAsync();
        RenderClients();
        return _clients.FirstOrDefault(x => x.Email == display)
               ?? throw new XuiException($"клиент {display} создан, но главная его не вернула — обнови и выбери из списка");
    }

    private async void CascSub_Click(object sender, RoutedEventArgs e)
    {
        if (CascSel is not { } c) { XuiDialog.Info(this, "Сначала добавь каскад-сервер"); return; }
        if (_cascVersion is null) { XuiDialog.Info(this, "Каскад на сервере не установлен — «Установить / обновить…» спросит подписку сам"); return; }
        var sub = await ChooseSubscription(c);
        if (sub is not { } s) return;
        await CascOp("Подписка", async (cs, r) =>
        {
            await r.SetAsync(new Dictionary<string, string> { ["QC_SUB_URL"] = s.Url });
            cs.Client = s.Client;
            _store.SaveCascade(cs);
            Log($"  ✓ подписка: {(s.Client is null ? "своя ссылка" : "клиент " + s.Client)}", LogKind.Ok);
            await ApplyAsync(r);
        });
    }

    // ── установка ──

    private async void CascInstall_Click(object sender, RoutedEventArgs e)
    {
        if (CascSel is not { } c) { XuiDialog.Info(this, "Сначала добавь каскад-сервер: «＋ Сервер…»"); return; }
        if (_cascBusy || _busy || _updBusy) { Log("! дождись окончания текущей операции", LogKind.Warn); return; }
        string? ver;
        try { ver = await Remote(c).RemoteVersionAsync(); }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); return; }
        var mine = CascadeRemote.ScriptVersion;
        (string Url, string? Client)? sub = null;
        string? mode = null;
        if (ver is null)
        {
            if (!XuiDialog.Confirm(this,
                    $"Поставить каскад на «{c.Name}»?\n\n" +
                    "• mihomo (ядро MetaCubeX) отдельным сервисом, слушает только 127.0.0.1\n" +
                    "• правила и группы как на Кинетиках (свои .mrs роутеров встроены), ноды — из подписки главной\n" +
                    "• в шаблон Xray 3x-ui — выход в mihomo и правило перехвата; перед правкой бэкап базы, при сбое откат\n" +
                    "• таймер раз в час сверяет подписку и добавляет группы новым нодам\n\n" +
                    "Нужен root (или sudo без пароля) и 3x-ui на сервере.",
                    "Каскад", "Дальше")) return;
            sub = await ChooseSubscription(c);
            if (sub is null) return;
            var m = XuiDialog.Pick(this, "Кого пускать через каскад сразу после установки? Поменять можно потом — «Кого каскадить…».",
                "Каскад", new[] { "Всех клиентов (VLESS, Hysteria, AWG)", "Никого — только поставить mihomo" },
                "Всех клиентов (VLESS, Hysteria, AWG)", "Установить");
            if (m is null) return;
            mode = m.StartsWith("Никого") ? "off" : "all";
        }
        else if (!XuiDialog.Confirm(this,
                     $"На «{c.Name}» qcascade {ver}, в QTerm — {mine}.\n\nЗалить скрипт из QTerm и прогнать установку заново? " +
                     "Подписка, правила, группы и режим перехвата на сервере сохраняются.",
                     "Каскад", "Обновить")) return;

        await CascOp(ver is null ? "Установка каскада" : $"Обновление каскада {ver} → {mine}", async (cs, r) =>
        {
            Log($"  заливаю скрипт qcascade {mine}…", LogKind.Dim);
            await r.UploadScriptAsync();
            if (sub is { } s)
            {
                await r.SetAsync(new Dictionary<string, string>
                {
                    ["QC_SUB_URL"] = s.Url, ["QC_XRAY_MODE"] = mode ?? "all", ["QC_XRAY_LIST"] = "",
                }, viaScript: true);
                cs.Client = s.Client;
                _store.SaveCascade(cs);
            }
            Log("  установка идёт на сервере в фоне (переживёт обрыв SSH):", LogKind.Dim);
            await r.StartInstallAsync();
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
            Log($"  ✓ каскад на «{cs.Name}» работает", LogKind.Ok);
        });
    }

    private async Task ApplyAsync(CascadeRemote r)
    {
        var res = await r.QcAsync("apply", 300);
        LogQc(res.Out);
        if (!res.Ok) throw new XuiException("конфиг не применён — работает прежний (причина выше)");
    }

    private async void CascApply_Click(object sender, RoutedEventArgs e) =>
        await CascOp("Применить", async (_, r) => await ApplyAsync(r));

    // ── кого каскадить ──

    private async void CascWho_Click(object sender, RoutedEventArgs e)
    {
        if (CascSel is not { } c || _cascVersion is null) { XuiDialog.Info(this, "Каскад на сервере не установлен"); return; }
        JsonObject lst;
        try { lst = await Remote(c).XrayListAsync(); }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); return; }
        if (!B(lst, "xui")) { XuiDialog.Info(this, "На сервере нет 3x-ui — перехватывать нечего"); return; }
        var env = _cascStatus?["env"];
        var cur = S(env, "xrayMode");
        var curList = S(env, "xrayList").Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
        var opts = new[]
        {
            "Всех клиентов (VLESS, Hysteria, AWG)",
            "Выбранные инбаунды…",
            "Выбранных клиентов…",
            "Никого — выключить перехват",
        };
        var curText = cur switch { "inbounds" => opts[1], "users" => opts[2], "off" => opts[3], _ => opts[0] };
        var pick = XuiDialog.Pick(this, "Кого пускать через каскад. Остальные идут напрямую с сервера, как без каскада.",
            "Кого каскадить", opts, curText, "Дальше");
        if (pick is null) return;
        var mode = Array.IndexOf(opts, pick) switch { 1 => "inbounds", 2 => "users", 3 => "off", _ => "all" };
        var list = "";
        if (mode == "inbounds")
        {
            var items = (lst["inbounds"] as JsonArray ?? new()).Where(x => x is not null)
                .Select(x => (Key: S(x, "tag"), Text: $"{S(x, "remark")}   ·   {S(x, "protocol")}   ·   {S(x, "tag")}")).ToList();
            var sel = CheckPick(this, "Инбаунды 3x-ui, чьи клиенты идут через каскад:", "Кого каскадить", items,
                cur == "inbounds" ? curList : null);
            if (sel is null) return;
            if (sel.Count == 0) { XuiDialog.Info(this, "Ничего не выбрано"); return; }
            list = string.Join(" ", sel);
        }
        else if (mode == "users")
        {
            var items = L(lst, "emails").Select(x => (Key: x, Text: x)).ToList();
            var sel = CheckPick(this, "Клиенты (VLESS, Hysteria и AWG по имени), которые идут через каскад:", "Кого каскадить", items,
                cur == "users" ? curList : null);
            if (sel is null) return;
            if (sel.Count == 0) { XuiDialog.Info(this, "Ничего не выбрано"); return; }
            list = string.Join(" ", sel);
        }
        await CascOp("Кого каскадить", async (_, r) =>
        {
            await r.SetAsync(new Dictionary<string, string> { ["QC_XRAY_MODE"] = mode, ["QC_XRAY_LIST"] = list });
            Log("  3x-ui перезапускается — клиенты переподключатся", LogKind.Dim);
            var res = await r.QcAsync(mode == "off" ? "xray off" : "xray on", 180);
            LogQc(res.Out);
            if (!res.Ok) throw new XuiException("перехват не переключился — 3x-ui в прежнем состоянии (причина выше)");
        });
    }

    // ── DIRECT ──

    private async void CascDirect_Click(object sender, RoutedEventArgs e)
    {
        if (CascSel is null || _cascStatus is null) { XuiDialog.Info(this, "Каскад на сервере не установлен"); return; }
        const string direct = "DIRECT — напрямую с этого сервера";
        var groups = (_cascStatus["groups"] as JsonArray ?? new()).Select(g => S(g, "name")).Where(x => x.Length > 0).ToList();
        var items = new List<string> { direct };
        items.AddRange(groups);
        var cur = S(_cascStatus["env"], "directTarget");
        var pick = XuiDialog.Pick(this,
            "Куда отправлять DIRECT из правил — ru-трафик, госуслуги, MATCH. DIRECT = IP этого сервера: если он за границей, " +
            "российское лучше вести через MSK.",
            "DIRECT →", items, cur is "" or "DIRECT" ? direct : cur, "Применить");
        if (pick is null) return;
        var target = pick == direct ? "DIRECT" : pick.Trim();
        await CascOp($"DIRECT → {target}", async (_, r) =>
        {
            await r.SetAsync(new Dictionary<string, string> { ["QC_DIRECT_TARGET"] = target });
            await ApplyAsync(r);
        });
    }

    // ── группы и правила ──

    private async void CascGroups_Click(object sender, RoutedEventArgs e) =>
        await EditRemote($"{CascConf}/groups.conf", "Группы каскада",
            "Составные группы, как на Кинетиках: ИМЯ ТИП ИНТЕРВАЛ УЧАСТНИКИ… (по приоритету). На каждую ноду подписки группа с тем же " +
            "именем создаётся сама. Участники, которых нет в подписке, пропускаются. Сохранение = применение с проверкой и откатом.");

    private async void CascRules_Click(object sender, RoutedEventArgs e) =>
        await EditRemote($"{CascConf}/rules.yaml", "Правила каскада",
            "rule-providers и rules — тот же формат, что в config.yaml Кинетика (пути /opt/etc/mihomo/… переписываются сами). " +
            "Сохранение = применение: конфиг с ошибкой не встанет, работает прежний.");

    private async Task EditRemote(string path, string title, string caption)
    {
        if (CascSel is not { } c || _cascVersion is null) { XuiDialog.Info(this, "Каскад на сервере не установлен"); return; }
        string text;
        try { text = await Remote(c).ReadRootFileAsync(path); }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); return; }
        var edited = EditText(this, $"{title} · {c.Name}", caption + $"\n{path}", text);
        if (edited is null) return;
        await CascOp($"{title}: сохранить и применить", async (_, r) =>
        {
            await r.WriteRootFileAsync(path, edited);
            Log($"  ✓ {path} записан", LogKind.Ok);
            await ApplyAsync(r);
        });
    }

    // ── ядро, журнал, удаление ──

    private async void CascCore_Click(object sender, RoutedEventArgs e)
    {
        if (CascSel is null || _cascVersion is null) { XuiDialog.Info(this, "Каскад на сервере не установлен"); return; }
        var cur = S(_cascStatus?["env"], "mihomoUrl");
        var f = XuiDialog.Form(this,
            "Ядро mihomo. Пусто — последний стоковый MetaCubeX. Своя сборка (например ff148 с firefox-отпечатком) — прямая ссылка " +
            "на .gz или бинарь под архитектуру сервера. Новое ядро сначала проверяет текущий конфиг, при сбое — откат.",
            "Ядро mihomo", new[] { new XuiDialog.Field("Ссылка на ядро (пусто — стоковое)", cur) }, "Обновить");
        if (f is null) return;
        var url = f[0].Trim();
        await CascOp("Ядро mihomo", async (_, r) =>
        {
            if (url != cur) await r.SetAsync(new Dictionary<string, string> { ["QC_MIHOMO_URL"] = url });
            var res = await r.QcAsync("update-core", 600);
            LogQc(res.Out);
            if (!res.Ok) throw new XuiException("ядро не обновилось (причина выше)");
        });
    }

    private async void CascLogs_Click(object sender, RoutedEventArgs e)
    {
        if (CascSel is not { } c || _cascVersion is null) { XuiDialog.Info(this, "Каскад на сервере не установлен"); return; }
        try
        {
            var res = await Remote(c).QcAsync("logs 300", 60);
            EditText(this, $"Журнал mihomo · {c.Name}", "journalctl -u qcascade, последние 300 строк", res.Out, readOnly: true);
        }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); }
    }

    private async void CascRemove_Click(object sender, RoutedEventArgs e)
    {
        if (CascSel is not { } c) return;
        var opts = new List<string>();
        if (_cascVersion is not null)
        {
            opts.Add("Снять перехват и удалить qcascade (правила и подписку на сервере оставить)");
            opts.Add("Удалить с сервера полностью (--purge)");
        }
        opts.Add("Только убрать сервер из списка QTerm");
        var pick = XuiDialog.Pick(this,
            $"«{c.Name}»: что сделать? Перехват снимается первым — клиенты 3x-ui снова пойдут напрямую.",
            "Убрать каскад", opts, opts[^1], "Выполнить");
        if (pick is null) return;
        var i = opts.IndexOf(pick);
        if (i < 0) return;
        if (pick.StartsWith("Только"))
        {
            _store.DeleteCascade(c.Id);
            _cascRemotes.Remove(c.Id);
            Log($"✓ «{c.Name}» убран из QTerm (на сервере ничего не трогал)", LogKind.Ok);
            LoadCascades();
            await RefreshCascadeAsync();
            return;
        }
        var purge = pick.Contains("--purge");
        if (!XuiDialog.Confirm(this, $"Точно {(purge ? "удалить каскад полностью" : "удалить qcascade")} с «{c.Name}»?", "Убрать каскад", "Удалить")) return;
        await CascOp("Удаление каскада", async (cs, r) =>
        {
            var res = await r.QcAsync(purge ? "uninstall --purge" : "uninstall", 300);
            LogQc(res.Out);
            if (!res.Ok) throw new XuiException("не удалилось (причина выше)");
            _store.DeleteCascade(cs.Id);
            _cascRemotes.Remove(cs.Id);
            Log($"  ✓ каскад с «{cs.Name}» снят, сервер убран из QTerm", LogKind.Ok);
        }, refresh: false);
        LoadCascades();
        await RefreshCascadeAsync();
    }

    // ── диалоги ──

    /// <summary>Большой текст: правка (null — отмена или без изменений) или просмотр (readOnly).</summary>
    private static string? EditText(Window owner, string title, string caption, string text, bool readOnly = false)
    {
        string? result = null;
        var w = new Window
        {
            Title = title, Owner = owner, Width = 980, Height = 680, MinWidth = 560, MinHeight = 360,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        w.SetResourceReference(Window.BackgroundProperty, "BgBrush");
        w.SetResourceReference(Window.ForegroundProperty, "FgBrush");
        var root = new DockPanel { Margin = new Thickness(14) };
        var cap = new TextBox
        {
            Text = caption, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, Margin = new Thickness(0, 0, 0, 8),
        };
        cap.SetResourceReference(Control.ForegroundProperty, "DimBrush");
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
            var save = new Button { Content = "Сохранить и применить", MinWidth = 170, IsDefault = false };
            save.Click += (_, _) => { if (box.Text != text) result = box.Text; w.Close(); };
            row.Children.Add(save);
        }
        var close = new Button { Content = readOnly ? "Закрыть" : "Отмена", MinWidth = 100, Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        close.Click += (_, _) => w.Close();
        row.Children.Add(close);
        root.Children.Add(row);
        root.Children.Add(box);
        w.Content = root;
        w.Loaded += (_, _) =>
        {
            box.Focus();
            if (readOnly) { box.CaretIndex = box.Text.Length; box.ScrollToEnd(); }
        };
        w.ShowDialog();
        return result;
    }

    /// <summary>Список с галками. null — отмена; иначе отмеченные ключи.</summary>
    private static List<string>? CheckPick(Window owner, string text, string title,
        IList<(string Key, string Text)> items, ISet<string>? selected)
    {
        List<string>? result = null;
        var w = new Window
        {
            Title = title, Owner = owner, Width = 560, Height = 560, MinHeight = 320,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        w.SetResourceReference(Window.BackgroundProperty, "BgBrush");
        w.SetResourceReference(Window.ForegroundProperty, "FgBrush");
        var root = new DockPanel { Margin = new Thickness(16) };
        var cap = new TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
            Background = Brushes.Transparent, Margin = new Thickness(0, 0, 0, 8),
        };
        cap.SetResourceReference(Control.ForegroundProperty, "FgBrush");
        DockPanel.SetDock(cap, Dock.Top);
        root.Children.Add(cap);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(row, Dock.Bottom);
        var boxes = new List<(string Key, CheckBox Box)>();
        var panel = new StackPanel();
        foreach (var (key, t) in items)
        {
            var cb = new CheckBox { Content = t, IsChecked = selected?.Contains(key) == true, Margin = new Thickness(4, 3, 4, 3) };
            cb.SetResourceReference(Control.ForegroundProperty, "FgBrush");
            boxes.Add((key, cb));
            panel.Children.Add(cb);
        }
        var ok = new Button { Content = "OK", MinWidth = 100, IsDefault = true };
        var cancel = new Button { Content = "Отмена", MinWidth = 100, Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        ok.Click += (_, _) => { result = boxes.Where(b => b.Box.IsChecked == true).Select(b => b.Key).ToList(); w.Close(); };
        cancel.Click += (_, _) => w.Close();
        row.Children.Add(ok);
        row.Children.Add(cancel);
        root.Children.Add(row);
        var sv = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = panel };
        sv.SetResourceReference(Control.BackgroundProperty, "PanelBrush");
        root.Children.Add(sv);
        w.Content = root;
        w.ShowDialog();
        return result;
    }
}
