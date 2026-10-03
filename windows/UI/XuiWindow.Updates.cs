using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>Раздел «Обновления»: версии панелей 3x-ui и ядра Xray, самообновление с бэкапом базы,
/// смена ядра, geo-файлы, бэкапы и откат (версия панели через SSH-терминал сервера + база из бэкапа).</summary>
public partial class XuiWindow
{
    public sealed class UpdRow
    {
        public XuiPanel P { get; init; } = null!;
        public string Name => P.Name;
        public string Role => P.RoleText;
        public string Version { get; init; } = "";
        public string Latest { get; init; } = "";
        public string Xray { get; init; } = "";
        public string Ssh { get; init; } = "";
        public string LastBackup { get; init; } = "";
        public string State { get; init; } = "";
        public Brush Dot { get; init; } = Brushes.Gray;
    }

    public sealed class BakRow
    {
        public XuiBackup B { get; init; } = null!;
        public string When => B.Time.ToString("dd.MM.yyyy HH:mm:ss");
        public string Panel => B.Panel;
        public string Version => B.Version.Length > 0 ? B.Version : "—";
        public string Size => Bytes(B.Size);
        public string File => B.FileName;
    }

    private sealed class UpdInfo
    {
        public string Version = "", Latest = "", Xray = "", State = "", Ssh = "";
        public bool Available, Error, Busy;
    }

    /// <summary>Отправить команду в SSH-терминал сессии QTerm (открыть вкладку, дождаться подключения).
    /// Ставит главное окно — без него «версия через терминал» недоступна.</summary>
    public Func<Guid, string, Task<bool>>? RunInTerminal { get; set; }

    private readonly Dictionary<string, UpdInfo> _upd = new();
    private bool _updBusy;

    private List<XuiPanel> UpdPanels() => _store.Panels().Where(p => p.IsXui).ToList();

    private UpdInfo Info(XuiPanel p)
    {
        if (!_upd.TryGetValue(p.Id.ToString(), out var i)) _upd[p.Id.ToString()] = i = new UpdInfo();
        return i;
    }

    private void SetState(XuiPanel p, string state, bool error = false)
    {
        var i = Info(p);
        i.State = state;
        i.Error = error;
        RenderUpdates();
    }

    private void RenderUpdates()
    {
        var sel = UpdList.SelectedItems.OfType<UpdRow>().Select(r => r.P.Id).ToHashSet();
        var rows = UpdPanels()
            .OrderBy(p => p.IsMaster ? 1 : 0).ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
            .Select(p =>
            {
                var i = Info(p);
                var last = XuiBackups.For(p).FirstOrDefault();
                return new UpdRow
                {
                    P = p,
                    Version = i.Version.Length > 0 ? i.Version : "…",
                    Latest = i.Available ? i.Latest + " ⬆" : i.Latest,
                    Xray = i.Xray,
                    Ssh = i.Ssh.Length > 0 ? i.Ssh : "…",
                    LastBackup = last is null ? "—" : $"{last.Time:dd.MM HH:mm} · v{(last.Version.Length > 0 ? last.Version : "?")}",
                    State = i.State,
                    Dot = i.Error ? Red : i.Busy ? Amber : i.Available ? Blue : i.Version.Length > 0 ? Green : Dim,
                };
            }).ToList();
        UpdList.ItemsSource = rows;
        foreach (var r in rows.Where(r => sel.Contains(r.P.Id))) UpdList.SelectedItems.Add(r);
        RenderBackups();
    }

    private void UpdList_SelectionChanged(object sender, SelectionChangedEventArgs e) => RenderBackups();

    private List<XuiPanel> UpdSelected() => UpdList.SelectedItems.OfType<UpdRow>().Select(r => r.P).ToList();

    private void RenderBackups()
    {
        var sel = UpdSelected();
        var list = sel.Count == 1 ? XuiBackups.For(sel[0]) : XuiBackups.List();
        BakCaption.Text = sel.Count == 1 ? $"Бэкапы «{sel[0].Name}» ({list.Count})" : $"Все бэкапы ({list.Count}) — выдели панель, чтобы отфильтровать";
        BakList.ItemsSource = list.Select(b => new BakRow { B = b }).ToList();
    }

    private async Task RefreshUpdatesAsync()
    {
        var panels = UpdPanels();
        RenderUpdates();
        if (panels.Count == 0) { UpdStatus.Text = "Нет панелей 3x-ui с токеном — «Панели и токены…» или «＋ Нода из выделения»"; return; }
        UpdStatus.Text = "проверяю версии…";
        var tasks = panels.Select(async p =>
        {
            var i = Info(p);
            if (i.Busy) return;
            // DNS-сопоставление панели с SSH-сессией — не на UI-потоке
            i.Ssh = await Task.Run(() => _store.SessionFor(p)?.Name ?? "—");
            try
            {
                using var api = XuiApi.For(p);
                var st = await api.StatusAsync();
                i.Version = XuiBackups.Norm(st?["panelVersion"]?.GetValue<string>());
                i.Xray = (st?["xray"] as JsonObject)?["version"]?.GetValue<string>() ?? "";
                var info = await api.UpdateInfoAsync();
                i.Latest = XuiBackups.Norm(info?["latestVersion"]?.GetValue<string>());
                i.Available = info?["updateAvailable"]?.GetValue<bool>() == true;
                if (i.State.StartsWith("✗", StringComparison.Ordinal) || i.State.Length == 0)
                    i.State = info is null ? "панель не достучалась до GitHub — обновление только через терминал" : "";
                i.Error = false;
            }
            catch (Exception ex) { i.State = "✗ " + ex.Message; i.Error = true; }
        }).ToList();
        await Task.WhenAll(tasks);
        RenderUpdates();
        var noToken = _nodes.Where(n => SavedFor(n) is null).Select(n => n.Name).ToList();
        UpdStatus.Text = $"панелей {panels.Count}, есть обновление: {panels.Count(p => Info(p).Available)} · {DateTime.Now:HH:mm:ss}" +
                         (noToken.Count > 0 ? $" · без токена в QTerm: {string.Join(", ", noToken)}" : "");
    }

    private async void UpdCheck_Click(object sender, RoutedEventArgs e) => await RefreshUpdatesAsync();

    /// <summary>Одна операция за раз; ошибки — в лог.</summary>
    private async Task UpdOp(string title, Func<Task> op)
    {
        if (_updBusy || _busy) { Log("! дождись окончания текущей операции", LogKind.Warn); return; }
        _updBusy = true;
        Log($"━━ {title}", LogKind.Head);
        try { await op(); }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); }
        finally { _updBusy = false; RenderUpdates(); }
    }

    private async Task<string> BackupOne(XuiApi api, XuiPanel p)
    {
        SetState(p, "бэкап базы…");
        var path = await XuiBackups.SaveAsync(api, p.Name);
        Log($"  ✓ бэкап «{p.Name}» → {path}", LogKind.Ok);
        return path;
    }

    /// <summary>
    /// Ждём, пока панель ответит и покажет нужную версию (или любую, если want пусто).
    /// Панель поднялась, но токен не принимает (на ней пропали API-токены) — выпускаем новый по паролю.
    /// </summary>
    private async Task<string?> WaitPanel(XuiApi api, XuiPanel p, string? want, int seconds, string what)
    {
        var t0 = DateTime.UtcNow;
        var recovered = false;
        while ((DateTime.UtcNow - t0).TotalSeconds < seconds)
        {
            await Task.Delay(5000);
            try
            {
                var v = XuiBackups.Norm((await api.StatusAsync())?["panelVersion"]?.GetValue<string>());
                SetState(p, $"{what}… {(int)(DateTime.UtcNow - t0).TotalSeconds} с, сейчас v{v}");
                if (want is null || v == XuiBackups.Norm(want)) return v;
            }
            catch (XuiException ex) when (ex.Status == 401)
            {
                if (recovered) throw;
                SetState(p, $"{what}… панель поднялась, но не принимает токен");
                Log($"  ! «{p.Name}»: панель отвечает, но токен QTerm на ней больше не действует (API-токены пропали)", LogKind.Warn);
                if (!await RecoverToken(p, api)) throw;
                recovered = true;
            }
            catch (XuiException) { SetState(p, $"{what}… панель перезапускается"); }
        }
        return null;
    }

    // ── токены ──

    private XuiPanel Fresh(XuiPanel p) => _store.Panels().FirstOrDefault(x => x.Id == p.Id) ?? p;

    /// <summary>Перед рискованной операцией: есть пароль админа — токен восстановится сам; нет — спрашиваем и проверяем вход.</summary>
    private async Task<XuiPanel> Insure(XuiPanel p)
    {
        var cur = Fresh(p);
        if (cur.Login.Length > 0 && !string.IsNullOrEmpty(cur.Pass)) return cur;
        var login = cur.Login;
        while (true)
        {
            var c = XuiDialog.Credentials(this,
                "Если после операции панель перестанет принимать токен (бывает при обновлении — API-токены пропадают), QTerm войдёт этим логином и паролем, " +
                "выпустит новый токен, сохранит и покажет. Пароль хранится в вейлте (DPAPI), синком — в зашифрованном виде.",
                $"Страховка токена «{cur.Name}»", login);
            if (c is null)
            {
                Log($"  ! «{cur.Name}»: без пароля — если токен пропадёт, выпустишь его в «Панели и токены…»", LogKind.Warn);
                return cur;
            }
            login = c.Value.Login;
            try
            {
                var r = await XuiLogin.IssueTokenAsync(cur.Url, c.Value.Login, c.Value.Pass,
                    c.Value.TwoFa.Length > 0 ? c.Value.TwoFa : null, cur.VerifyTls, tokenName: null);
                if (r.Ok)
                {
                    cur.Login = c.Value.Login;
                    cur.Pass = c.Value.Pass;
                    _store.SavePanel(cur);
                    Log($"  ✓ «{cur.Name}»: логин и пароль проверены и сохранены", LogKind.Ok);
                    return Fresh(cur);
                }
                XuiDialog.Info(this, $"«{cur.Name}»: {r.Message}");
            }
            catch (Exception ex) { XuiDialog.Info(this, $"«{cur.Name}»: {ex.Message}"); }
        }
    }

    /// <summary>Панель не принимает токен: новый — по сохранённому паролю, иначе спросить; сохранить, поставить в api.</summary>
    private async Task<bool> RecoverToken(XuiPanel p, XuiApi api)
    {
        var cur = Fresh(p);
        string? token = null;
        if (cur.Login.Length > 0 && !string.IsNullOrEmpty(cur.Pass)) token = await XuiReauth.ReissueAsync(cur.Id);
        var login = cur.Login;
        while (token is null)
        {
            var c = XuiDialog.Credentials(this,
                $"Панель «{cur.Name}» не принимает токен QTerm. Войду логином и паролем админа и выпущу новый токен.",
                $"Новый токен «{cur.Name}»", login);
            if (c is null) return false;
            login = c.Value.Login;
            var r = await XuiReauth.IssueAndSaveAsync(cur.Id, c.Value.Login, c.Value.Pass, c.Value.TwoFa.Length > 0 ? c.Value.TwoFa : null);
            if (r.Token is not null) token = r.Token;
            else XuiDialog.Info(this, $"«{cur.Name}»: {r.Message}");
        }
        api.SetToken(token);
        Log($"  ✓ «{cur.Name}»: новый токен выпущен и сохранён в QTerm", LogKind.Ok);
        return true;
    }

    /// <summary>После операции: токен перевыпускался — какие токены были и какие остались на панели, показать новый.</summary>
    private async Task ReportTokens(XuiPanel p, XuiApi api, List<string>? before)
    {
        if (!api.Reissued) return;
        var after = await api.TokenNamesAsync() ?? new List<string>();
        if (before is not null)
        {
            var gone = before.Where(n => !after.Contains(n)).ToList();
            Log($"  · «{p.Name}»: API-токены до: {(before.Count == 0 ? "—" : string.Join(", ", before))}; после: {string.Join(", ", after)}" +
                (gone.Count == 0 ? "" : "; пропали: " + string.Join(", ", gone)), LogKind.Dim);
        }
        XuiDialog.Secret(this,
            $"Панель «{p.Name}» перестала принимать старый токен — выпущен новый, он уже сохранён в QTerm. " +
            "Если этот токен нужен где-то ещё (скрипты, другая главная), скопируй. Держи его в переменной окружения, не в коде.",
            $"Новый API-токен «{p.Name}»", api.CurrentToken);
    }

    // ── самообновление ──

    private async void UpdPanel_Click(object sender, RoutedEventArgs e)
    {
        var sel = UpdSelected();
        if (sel.Count == 0) sel = UpdPanels().Where(p => Info(p).Available).ToList();
        if (sel.Count == 0) { XuiDialog.Info(this, "Выдели панели (или сначала «Проверить версии» — обновлю те, где есть новая версия)"); return; }
        // ноды первыми: новая главная шлёт узлам поля, которых старый узел может не понять
        var order = sel.OrderBy(p => p.IsMaster ? 1 : 0).ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ToList();
        if (!XuiDialog.Confirm(this,
                "Обновить по очереди: " + string.Join(" → ", order.Select(p => p.Name)) + "\n\n" +
                "Каждая: бэкап базы → самообновление панели (update.sh с GitHub) → ждём, пока поднимется с новой версией. " +
                "На первой ошибке останавливаюсь. Откат — внизу, из бэкапа.\n\n" +
                "Совет: свежий релиз сначала поставь на одну ноду и проверь.",
                "Обновление панелей", "Обновить")) return;
        // страховка: без пароля админа пропавший после обновления токен сам не восстановить
        var insured = new List<XuiPanel>();
        foreach (var p in order) insured.Add(await Insure(p));
        await UpdOp("Обновление панелей", async () =>
        {
            foreach (var p in insured)
            {
                var i = Info(p);
                i.Busy = true;
                try
                {
                    using var api = XuiApi.For(p);
                    var st = await api.StatusAsync();
                    var from = XuiBackups.Norm(st?["panelVersion"]?.GetValue<string>());
                    var settings = await api.SettingsAsync();
                    if (J.Str(settings, "webCertFile").Length == 0)
                    {
                        // update.sh без сертификата в панели начинает выпускать его и спрашивать в консоли
                        SetState(p, "пропущена: в панели нет SSL-сертификата — обнови через терминал", true);
                        Log($"  ! «{p.Name}»: в настройках панели не задан сертификат — апдейтер 3x-ui начнёт выпускать его сам. Обнови её кнопкой «Версия через терминал…»", LogKind.Warn);
                        continue;
                    }
                    await BackupOne(api, p);
                    var tokensBefore = await api.TokenNamesAsync();
                    SetState(p, "обновляю…");
                    var runId = await api.StartUpdateAsync();
                    Log($"  … «{p.Name}»: обновление запущено (v{from})", LogKind.Dim);
                    // статус апдейтера, затем панель с новой версией
                    var t0 = DateTime.UtcNow;
                    string state = "pending";
                    while ((DateTime.UtcNow - t0).TotalSeconds < 420)
                    {
                        await Task.Delay(5000);
                        try
                        {
                            var us = await api.UpdateStatusAsync();
                            if (us?["runId"]?.GetValue<string>() == runId) state = us?["state"]?.GetValue<string>() ?? "pending";
                        }
                        catch (XuiException) { /* панель перезапускается */ }
                        SetState(p, $"обновляю… {(int)(DateTime.UtcNow - t0).TotalSeconds} с");
                        if (state is "success" or "failed") break;
                    }
                    if (state == "failed") throw new XuiException("апдейтер завершился с ошибкой (журнал: x-ui log на сервере)");
                    var now = await WaitPanel(api, p, null, 120, "жду панель");
                    if (now is null) throw new XuiException("панель не поднялась за 2 минуты после обновления");
                    await ReportTokens(p, api, tokensBefore);
                    if (now == from) throw new XuiException($"версия не поменялась (v{now}) — смотри журнал апдейтера на сервере");
                    i.Version = now;
                    i.Available = false;
                    SetState(p, $"✓ v{from} → v{now}");
                    Log($"  ✓ «{p.Name}»: v{from} → v{now}", LogKind.Ok);
                }
                catch (Exception ex)
                {
                    SetState(p, "✗ " + ex.Message, true);
                    Log($"  ✗ «{p.Name}»: {ex.Message}. Остальные не трогаю. Бэкап базы — внизу, откат — «Откатить панель к этому бэкапу…»", LogKind.Err);
                    break;
                }
                finally { i.Busy = false; }
            }
        });
        await RefreshUpdatesAsync();
    }

    // ── ядро Xray ──

    private async void UpdXray_Click(object sender, RoutedEventArgs e)
    {
        var sel = UpdSelected();
        if (sel.Count == 0) { XuiDialog.Info(this, "Выдели панели, на которые поставить ядро"); return; }
        List<string> versions;
        try
        {
            using var api = XuiApi.For(sel[0]);
            versions = await api.XrayVersionsAsync();
        }
        catch (Exception ex) { XuiDialog.Info(this, "Список версий Xray не получен: " + ex.Message); return; }
        if (versions.Count == 0) { XuiDialog.Info(this, "Панель не вернула версий Xray (нет выхода на GitHub?)"); return; }
        var cur = Info(sel[0]).Xray;
        var v = XuiDialog.Pick(this,
            $"Ядро Xray для: {string.Join(", ", sel.Select(p => p.Name))}\nСейчас: {(cur.Length > 0 ? cur : "?")}. Двойной клик — выбрать.",
            "Ядро Xray", versions, versions.FirstOrDefault(x => x.TrimStart('v') == cur.TrimStart('v')) ?? versions[0], "Поставить");
        if (v is null) return;
        await UpdOp($"Ядро Xray {v}", async () =>
        {
            foreach (var p in sel)
            {
                var i = Info(p);
                i.Busy = true;
                try
                {
                    using var api = XuiApi.For(p);
                    await BackupOne(api, p);
                    SetState(p, $"ставлю Xray {v}…");
                    await api.InstallXrayAsync(v);
                    await Task.Delay(3000);
                    var st = await api.StatusAsync();
                    var x = st["xray"] as JsonObject;
                    i.Xray = x?["version"]?.GetValue<string>() ?? "";
                    var state = x?["state"]?.GetValue<string>() ?? "";
                    SetState(p, $"✓ Xray {i.Xray} ({state})", state is not ("" or "running"));
                    Log($"  ✓ «{p.Name}»: Xray {i.Xray}, {state}", state is "" or "running" ? LogKind.Ok : LogKind.Warn);
                }
                catch (Exception ex) { SetState(p, "✗ " + ex.Message, true); Log($"  ✗ «{p.Name}»: {ex.Message}", LogKind.Err); }
                finally { i.Busy = false; }
            }
        });
    }

    private async void UpdGeo_Click(object sender, RoutedEventArgs e)
    {
        var sel = UpdSelected();
        if (sel.Count == 0) { XuiDialog.Info(this, "Выдели панели"); return; }
        await UpdOp("Geo-файлы", async () =>
        {
            foreach (var p in sel)
            {
                try
                {
                    using var api = XuiApi.For(p);
                    await api.UpdateGeoAsync();
                    SetState(p, "✓ geo-файлы обновлены");
                    Log($"  ✓ «{p.Name}»: geoip/geosite обновлены", LogKind.Ok);
                }
                catch (Exception ex) { SetState(p, "✗ " + ex.Message, true); Log($"  ✗ «{p.Name}»: {ex.Message}", LogKind.Err); }
            }
        });
    }

    private async void UpdBackup_Click(object sender, RoutedEventArgs e)
    {
        var sel = UpdSelected();
        if (sel.Count == 0) sel = UpdPanels();
        await UpdOp("Бэкап баз", async () =>
        {
            foreach (var p in sel)
            {
                try
                {
                    using var api = XuiApi.For(p);
                    await BackupOne(api, p);
                    SetState(p, "✓ бэкап снят");
                }
                catch (Exception ex) { SetState(p, "✗ " + ex.Message, true); Log($"  ✗ «{p.Name}»: {ex.Message}", LogKind.Err); }
            }
        });
    }

    // ── версия через терминал / откат ──

    private static async Task<List<string>> ReleasesAsync()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("QTerm");
        var arr = JsonNode.Parse(await http.GetStringAsync("https://api.github.com/repos/MHSanaei/3x-ui/releases?per_page=30")) as JsonArray;
        return (arr ?? new JsonArray()).OfType<JsonObject>()
            .Where(o => o["draft"]?.GetValue<bool>() != true && o["prerelease"]?.GetValue<bool>() != true)
            .Select(o => o["tag_name"]?.GetValue<string>() ?? "").Where(t => t.Length > 0).ToList();
    }

    /// <summary>Команда установки конкретного релиза: апдейтер 3x-ui с тегом (конфиг и база остаются на месте).</summary>
    private static string InstallCommand(string tag, string user)
    {
        var sudo = user == "root" ? "" : "sudo ";
        return "curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh -o /tmp/xui-update.sh && " +
               $"{sudo}env XUI_UPDATE_TAG={tag} bash /tmp/xui-update.sh";
    }

    private async void UpdInstall_Click(object sender, RoutedEventArgs e)
    {
        var sel = UpdSelected();
        if (sel.Count != 1) { XuiDialog.Info(this, "Выдели одну панель"); return; }
        var p = sel[0];
        List<string> tags;
        try { tags = await ReleasesAsync(); }
        catch (Exception ex) { tags = new(); Log("! список релизов 3x-ui с GitHub не получен: " + ex.Message, LogKind.Warn); }
        var cur = Info(p).Version;
        var prev = XuiBackups.For(p).Select(b => b.Version).FirstOrDefault(v => v.Length > 0 && cur.Length > 0 && v != cur);
        var tag = XuiDialog.Pick(this,
            $"Какую версию 3x-ui поставить на «{p.Name}»? Сейчас v{(cur.Length > 0 ? cur : "?")}.\n" +
            "Команда уйдёт в SSH-терминал сервера (видно, что происходит); база и настройки остаются. " +
            "Для отката на старую версию лучше «Откатить панель к этому бэкапу…» — вернёт и базу.",
            "Версия панели через терминал", tags, prev is null ? tags.FirstOrDefault() : "v" + prev, "Поставить");
        if (tag is null) return;
        await InstallViaTerminal(p, tag.StartsWith('v') ? tag : "v" + tag, restore: null);
    }

    private async void BakRollback_Click(object sender, RoutedEventArgs e)
    {
        if (BakList.SelectedItem is not BakRow r) { XuiDialog.Info(this, "Выбери бэкап в списке снизу"); return; }
        var p = PanelForBackup(r.B);
        if (p is null) return;
        if (r.B.Version.Length == 0)
        {
            XuiDialog.Info(this, "В этом бэкапе не записана версия панели (старый формат). Поставь версию кнопкой «Версия через терминал…», потом «Восстановить базу…».");
            return;
        }
        if (!XuiDialog.Confirm(this,
                $"Откат «{p.Name}» к v{r.B.Version} и базе от {r.B.Time:dd.MM.yyyy HH:mm}:\n\n" +
                "1) бэкап текущей базы (чтобы можно было вернуться);\n" +
                $"2) в SSH-терминале сервера — установка 3x-ui v{r.B.Version};\n" +
                "3) жду панель с этой версией;\n" +
                "4) загружаю базу из бэкапа (адреса, сертификаты и привязка узла этой машины сохраняются).\n\n" +
                "Клиенты, добавленные после бэкапа, на этой панели пропадут.",
                "Откат панели", "Откатить")) return;
        await InstallViaTerminal(p, "v" + r.B.Version, r.B);
    }

    private async Task InstallViaTerminal(XuiPanel target, string tag, XuiBackup? restore)
    {
        var p = target;
        if (RunInTerminal is null) { XuiDialog.Info(this, "Терминал QTerm недоступен из этого окна"); return; }
        var sess = _store.SessionFor(p);
        if (sess is null)
        {
            XuiDialog.Info(this, $"Для «{p.Name}» не найдена SSH-сессия QTerm (ни по адресу, ни по IP). Привяжи её в «Панели и токены…» → «SSH-сессия».");
            return;
        }
        p = await Insure(p);
        await UpdOp($"«{p.Name}» → {tag}{(restore is null ? "" : " + база из бэкапа")}", async () =>
        {
            var i = Info(p);
            i.Busy = true;
            try
            {
                using var api = XuiApi.For(p);
                await BackupOne(api, p);
                var tokensBefore = await api.TokenNamesAsync();
                var cmd = InstallCommand(tag, sess.Username);
                SetState(p, $"команда отправлена в терминал «{sess.Name}»");
                if (!await RunInTerminal(sess.Id, cmd)) throw new XuiException($"не удалось открыть терминал «{sess.Name}» — команда в буфере, вставь её сама");
                Log($"  … в терминале «{sess.Name}»: {cmd}", LogKind.Dim);
                var v = await WaitPanel(api, p, tag, 600, $"жду v{XuiBackups.Norm(tag)}");
                if (v is null) throw new XuiException($"за 10 минут панель не показала v{XuiBackups.Norm(tag)} — смотри терминал");
                i.Version = v;
                Log($"  ✓ «{p.Name}»: v{v}", LogKind.Ok);
                if (restore is not null)
                {
                    SetState(p, "загружаю базу из бэкапа…");
                    await api.ImportDbAsync(await File.ReadAllBytesAsync(restore.Path));
                    var back = await WaitPanel(api, p, null, 90, "панель перезапускается с базой");
                    if (back is null) throw new XuiException("после загрузки базы панель не ответила за 90 с");
                    Log($"  ✓ «{p.Name}»: база из {restore.FileName} на месте", LogKind.Ok);
                }
                await ReportTokens(p, api, tokensBefore);
                SetState(p, $"✓ v{v}{(restore is null ? "" : " + база от " + restore.Time.ToString("dd.MM HH:mm"))}");
            }
            catch (Exception ex)
            {
                SetState(p, "✗ " + ex.Message, true);
                Log($"  ✗ «{p.Name}»: {ex.Message}", LogKind.Err);
                if (ex.Message.Contains("в буфере")) try { Clipboard.SetText(InstallCommand(tag, sess.Username)); } catch { }
            }
            finally { i.Busy = false; }
        });
        await RefreshUpdatesAsync();
    }

    // ── бэкапы ──

    private XuiPanel? PanelForBackup(XuiBackup b)
    {
        var sel = UpdSelected();
        if (sel.Count == 1) return sel[0];
        var p = UpdPanels().FirstOrDefault(x => XuiBackups.Safe(x.Name).Equals(b.Panel, StringComparison.OrdinalIgnoreCase))
                ?? (b.Panel.Equals("master", StringComparison.OrdinalIgnoreCase) ? UpdPanels().FirstOrDefault(x => x.IsMaster) : null);
        if (p is null) XuiDialog.Info(this, $"Не понял, чей это бэкап («{b.Panel}») — выдели панель сверху");
        return p;
    }

    private async void BakRestore_Click(object sender, RoutedEventArgs e)
    {
        if (BakList.SelectedItem is not BakRow r) { XuiDialog.Info(this, "Выбери бэкап в списке снизу"); return; }
        var found = PanelForBackup(r.B);
        if (found is null) return;
        var p = found;
        var cur = Info(p).Version;
        var warn = r.B.Version.Length > 0 && cur.Length > 0 && r.B.Version != cur
            ? (XuiBackups.Compare(r.B.Version, cur) < 0
                ? $"\n\nБаза от v{r.B.Version}, панель v{cur}: панель сама доведёт её миграциями при старте."
                : $"\n\n⚠ База от более НОВОЙ v{r.B.Version}, а панель v{cur} — старая панель может её не понять. Лучше «Откатить панель к этому бэкапу…» наоборот: сначала версия, потом база.")
            : "";
        if (!XuiDialog.Confirm(this,
                $"Загрузить в «{p.Name}» базу из {r.B.FileName} ({r.B.Time:dd.MM.yyyy HH:mm})?\n" +
                "Перед этим сниму бэкап текущей базы. Адреса, сертификаты и привязка узла этой машины сохраняются; панель перезапустится." + warn,
                "Восстановление базы", "Восстановить")) return;
        p = await Insure(p);
        await UpdOp($"Восстановление базы «{p.Name}»", async () =>
        {
            var i = Info(p);
            i.Busy = true;
            try
            {
                using var api = XuiApi.For(p);
                await BackupOne(api, p);
                SetState(p, "загружаю базу…");
                await api.ImportDbAsync(await File.ReadAllBytesAsync(r.B.Path));
                var back = await WaitPanel(api, p, null, 90, "панель перезапускается");
                if (back is null) throw new XuiException("после загрузки базы панель не ответила за 90 с");
                await ReportTokens(p, api, null);
                SetState(p, $"✓ база от {r.B.Time:dd.MM HH:mm} на месте");
                Log($"  ✓ «{p.Name}»: база из {r.B.FileName} загружена", LogKind.Ok);
            }
            catch (Exception ex) { SetState(p, "✗ " + ex.Message, true); Log($"  ✗ «{p.Name}»: {ex.Message}", LogKind.Err); }
            finally { i.Busy = false; }
        });
        await RefreshAsync(quiet: true);
    }

    private void BakFolder_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(XuiBackups.Dir);
        try { Process.Start(new ProcessStartInfo("explorer.exe", XuiBackups.Dir) { UseShellExecute = true }); } catch { }
    }
}
