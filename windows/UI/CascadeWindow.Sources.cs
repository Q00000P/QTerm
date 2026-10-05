using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>
/// «Источники нод»: откуда каскад берёт ноды. Две логики сразу:
/// • свой клиент каскада на любой панели 3x-ui (главной — с инбаундами всех узлов, или отдельной ноде) с нужным
///   набором инбаундов — его Clash-подписка и есть источник; единая подписка клиентов не трогается;
/// • подписки отдельных нод (ссылкой) и WireGuard/AWG (клиент AWG-панели другой ноды или .conf) — в т.ч. резерв.
/// Источники живут на сервере (/etc/qcascade/sources.json, 600): ссылки и ключи в QTerm не хранятся.
/// </summary>
public partial class CascadeWindow
{
    public sealed class SourceRow
    {
        public CascadeSource Src { get; init; } = null!;
        public string Name => Src.Name;
        public string TypeText => Src.IsWg ? "WireGuard" : "подписка";
        public string Origin => Src.Origin;
        public string Prefix => Src.Prefix;
        public string Nodes { get; init; } = "";
        public string State { get; init; } = "";
        public Brush Dot { get; init; } = Brushes.Gray;
    }

    private const string NoReserve = "— без резерва —";

    /// <summary>Источники из статуса сервера — без ссылок и конфигов (их сервер в статус не отдаёт).</summary>
    private static List<CascadeSource> Shown(ServerState st) =>
        (st.Status?["sources"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(CascadeSource.From).ToList();

    private static HashSet<string> Taken(IEnumerable<CascadeSource> list) =>
        list.Select(x => x.Name).ToHashSet(StringComparer.Ordinal);

    private void RenderSources()
    {
        _loadingUi = true;
        try
        {
            if (!Ready(out _, out var st))
            {
                SourceList.ItemsSource = null;
                ReserveBox.ItemsSource = null;
                ReserveBox.IsEnabled = false;
                return;
            }
            var s = st.Status!;
            var reserve = S(s["env"], "reserve");
            var srcState = (s["state"]?["sources"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
            var keep = (SourceList.SelectedItem as SourceRow)?.Name;
            var shown = Shown(st);
            var rows = new List<SourceRow>();
            foreach (var x in shown)
            {
                var ss = srcState.FirstOrDefault(y => S(y, "name") == x.Name);
                var n = ss is null ? null : I(ss, "nodes");
                var err = ss is null ? "" : S(ss, "error");
                string state;
                Brush dot;
                if (!x.Enabled) { state = "выключен"; dot = Gray; }
                else if (ss is null) { state = "не применён — «Применить»"; dot = Amber; }
                else if (err.Length > 0) { state = err; dot = n > 0 ? Amber : Red; }
                else if (x.IsWg) { state = "ok"; dot = Green; }
                else { state = n > 0 ? "ok" : "нод нет"; dot = n > 0 ? Green : Red; }
                if (x.Name == reserve) state = "резерв · " + state;
                rows.Add(new SourceRow
                {
                    Src = x,
                    Nodes = x.IsWg ? "1" : n?.ToString() ?? "—",
                    State = state,
                    Dot = dot,
                });
            }
            SourceList.ItemsSource = rows;
            SourceList.SelectedItem = rows.FirstOrDefault(r => r.Name == keep);

            var items = new List<string> { NoReserve };
            items.AddRange(shown.Where(x => x.IsWg && x.Enabled).Select(x => x.Name));
            foreach (var node in L(s["state"], "nodes"))
                if (!items.Contains(node)) items.Add(node);
            if (reserve.Length > 0 && !items.Contains(reserve)) items.Add(reserve);
            ReserveBox.ItemsSource = items;
            ReserveBox.SelectedItem = reserve.Length > 0 ? reserve : NoReserve;
            ReserveBox.IsEnabled = true;
        }
        finally { _loadingUi = false; }
    }

    private bool SourcesReady(out CascadeServer c, out ServerState st)
    {
        if (Ready(out c, out st)) return true;
        XuiDialog.Info(this, Sel is null ? "Сначала добавь каскад-сервер: «＋ Сервер…»"
            : "Каскад на сервере не установлен (или старой версии) — «Установить…»", "Каскад");
        return false;
    }

    private SourceRow? OneSource()
    {
        if (SourceList.SelectedItem is SourceRow r) return r;
        XuiDialog.Info(this, "Выбери источник в списке", "Каскад");
        return null;
    }

    /// <summary>Заменить источник oldName (на его месте) или добавить новый.</summary>
    private static void Upsert(List<CascadeSource> list, CascadeSource src, string? oldName)
    {
        var i = oldName is null ? -1 : list.FindIndex(x => x.Name == oldName);
        if (list.Any(x => x.Name == src.Name && x.Name != oldName))
            throw new XuiException($"источник «{src.Name}» уже есть");
        if (i >= 0) list[i] = src;
        else list.Add(src);
    }

    /// <summary>Источники целиком с сервера → правка → запись (сервер проверяет сам). В работу — по «Применить».</summary>
    private Task<bool> MutateSources(string title, Func<List<CascadeSource>, string> mutate, Dictionary<string, string>? env = null) =>
        Op(title, async (c, r) =>
        {
            var list = await r.SourcesAsync();
            var msg = mutate(list);
            await r.SaveSourcesAsync(list);
            if (env is { Count: > 0 }) await r.SetAsync(env);
            St(c).Pending = true;
            Log($"  ✓ {msg} — в работу по «Применить»", LogKind.Ok);
        });

    private void LogOk(string line) => Log(line, LogKind.Ok);

    // ── добавить ──

    private async void SrcAddXui_Click(object sender, RoutedEventArgs e)
    {
        if (!SourcesReady(out var c, out var st)) return;
        var src = new CascadeXuiSourceDialog(this, _store, c.Name, null, Taken(Shown(st)), LogOk).ShowDialog();
        if (src is null) return;
        await MutateSources($"Источник {src.Name}", list => { Upsert(list, src, null); return $"источник «{src.Name}»: {src.Origin}"; });
    }

    private async void SrcAddLink_Click(object sender, RoutedEventArgs e)
    {
        if (!SourcesReady(out _, out var st)) return;
        var taken = Taken(Shown(st));
        var src = CascadeLinkDialog.Show(this, null, taken, CUi.FreeName("SUB", taken));
        if (src is null) return;
        await MutateSources($"Источник {src.Name}", list => { Upsert(list, src, null); return $"источник «{src.Name}»: ссылка подписки"; });
    }

    private async void SrcAddWg_Click(object sender, RoutedEventArgs e)
    {
        if (!SourcesReady(out var c, out var st)) return;
        var dlg = new CascadeWgSourceDialog(this, _store, c.Name, null, S(st.Status!["env"], "reserve").Length == 0, Taken(Shown(st)), LogOk);
        var src = dlg.ShowDialog();
        if (src is null) return;
        var env = dlg.Reserve ? new Dictionary<string, string> { ["QC_RESERVE"] = src.Name } : null;
        await MutateSources($"Источник {src.Name}", list =>
        {
            Upsert(list, src, null);
            return $"источник «{src.Name}»: {src.Origin}" + (dlg.Reserve ? " · резерв" : "");
        }, env);
    }

    // ── изменить / вкл-выкл / удалить ──

    private async void SrcEdit_Click(object sender, RoutedEventArgs e)
    {
        if (!SourcesReady(out var c, out var st) || OneSource() is not { } row) return;
        if (_busy) { Log("! дождись окончания текущей операции", LogKind.Warn); return; }
        List<CascadeSource> full;
        try { full = await Remote(c).SourcesAsync(); }
        catch (Exception ex) { Log("✗ " + ex.Message, LogKind.Err); return; }
        var cur = full.FirstOrDefault(x => x.Name == row.Name);
        if (cur is null)
        {
            XuiDialog.Info(this, "Этого источника на сервере уже нет — список обновлён", "Каскад");
            await RefreshAsync();
            return;
        }
        var taken = Taken(full);
        var reserve = S(st.Status!["env"], "reserve");
        CascadeSource? upd;
        string? newReserve = null;
        switch (cur.Kind)
        {
            case "xui":
                upd = new CascadeXuiSourceDialog(this, _store, c.Name, cur, taken, LogOk).ShowDialog();
                break;
            case "awg":
            case "conf":
                var wd = new CascadeWgSourceDialog(this, _store, c.Name, cur, reserve == cur.Name, taken, LogOk);
                upd = wd.ShowDialog();
                if (upd is not null)
                {
                    var want = wd.Reserve ? upd.Name : reserve == cur.Name ? "" : reserve;
                    if (want != reserve) newReserve = want;
                }
                break;
            default:
                upd = CascadeLinkDialog.Show(this, cur, taken, cur.Name);
                break;
        }
        if (upd is null) return;
        if (newReserve is null && reserve == cur.Name && upd.Name != cur.Name) newReserve = upd.Name;   // переименовали резерв
        var env = newReserve is null ? null : new Dictionary<string, string> { ["QC_RESERVE"] = newReserve };
        await MutateSources($"Источник {cur.Name}", list => { Upsert(list, upd, cur.Name); return $"источник «{upd.Name}» сохранён"; }, env);
    }

    private async void SrcToggle_Click(object sender, RoutedEventArgs e)
    {
        if (!SourcesReady(out _, out _) || OneSource() is not { } row) return;
        var on = !row.Src.Enabled;
        await MutateSources($"Источник {row.Name}: {(on ? "включить" : "выключить")}", list =>
        {
            var x = list.FirstOrDefault(y => y.Name == row.Name) ?? throw new XuiException("этого источника на сервере уже нет");
            x.Enabled = on;
            return $"«{row.Name}» {(on ? "включён" : "выключен")}";
        });
    }

    private async void SrcDelete_Click(object sender, RoutedEventArgs e)
    {
        if (!SourcesReady(out _, out var st) || OneSource() is not { } row) return;
        var src = row.Src;
        var panel = src.PanelId is Guid pid ? _store.PanelById(pid) : null;
        int choice;
        if (src.Kind == "xui" && panel is not null)
            choice = XuiDialog.Show(this,
                $"Удалить источник «{src.Name}»?\n\nКлиент каскада {src.MetaStr("client")} на панели «{panel.Name}» можно удалить заодно — " +
                "если его подписка больше нигде не нужна.", "Удалить источник", "Удалить и клиента на панели", "Только источник", "Отмена");
        else if (src.Kind == "awg" && panel is not null)
            choice = XuiDialog.Show(this,
                $"Удалить источник «{src.Name}»?\n\nКлиента {src.MetaStr("client")} AWG-панели «{panel.Name}» можно удалить заодно.",
                "Удалить источник", "Удалить и клиента AWG", "Только источник", "Отмена");
        else
            choice = XuiDialog.Confirm(this, $"Удалить источник «{src.Name}»?", "Удалить источник", "Удалить") ? 1 : -1;
        if (choice is < 0 or 2) return;
        var reserve = S(st.Status!["env"], "reserve");
        var env = reserve == src.Name ? new Dictionary<string, string> { ["QC_RESERVE"] = "" } : null;
        var ok = await MutateSources($"Удалить источник {src.Name}", list =>
        {
            list.RemoveAll(x => x.Name == src.Name);
            return $"источник «{src.Name}» удалён" + (env is null ? "" : ", резерв выключен");
        }, env);
        if (!ok || choice != 0 || panel is null) return;
        try
        {
            if (src.Kind == "xui")
            {
                using var api = XuiApi.For(panel);
                await api.DeleteClientAsync(src.MetaStr("client"));
                Log($"  ✓ клиент {src.MetaStr("client")} удалён с «{panel.Name}»", LogKind.Ok);
            }
            else
            {
                using var api = AwgApi.For(panel);
                var id = src.MetaStr("clientId");
                if (id.Length == 0)
                    id = (await api.ClientsAsync(panel)).FirstOrDefault(x => x.Name == src.MetaStr("client"))?.Id ?? "";
                if (id.Length == 0) throw new XuiException($"клиента {src.MetaStr("client")} на «{panel.Name}» нет");
                await api.DeleteAsync(id);
                Log($"  ✓ клиент AWG {src.MetaStr("client")} удалён с «{panel.Name}»", LogKind.Ok);
            }
        }
        catch (Exception ex) { Log("✗ клиент не удалён: " + ex.Message, LogKind.Err); }
    }

    // ── резерв ──

    private async void Reserve_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingUi || ReserveBox.SelectedItem is not string pick || !Ready(out _, out var st)) return;
        var val = pick == NoReserve ? "" : pick;
        if (S(st.Status!["env"], "reserve") == val) return;
        await Op(val.Length > 0 ? $"Резерв → {val}" : "Резерв выключен", async (c, r) =>
        {
            await r.SetAsync(new Dictionary<string, string> { ["QC_RESERVE"] = val });
            St(c).Pending = true;
            Log("  ✓ сохранено — в работу по «Применить»", LogKind.Ok);
        });
    }

    // ── установка: источники и кого пускать — одним окном ──

    private Task<(List<CascadeSource> Sources, Dictionary<string, string> Env)?> InstallDialogAsync(CascadeServer c)
    {
        (List<CascadeSource> Sources, Dictionary<string, string> Env)? result = null;
        var w = CUi.Win(this, $"Установка каскада · {c.Name}", 760, 640);
        var sources = new List<CascadeSource>();
        var reserve = "";
        var list = new ListBox { MinHeight = 120 };
        list.SetResourceReference(Control.BackgroundProperty, "PanelBrush");
        list.SetResourceReference(Control.ForegroundProperty, "FgBrush");
        void Render() => list.ItemsSource = sources.Select(s => $"{s.Name}   ·   {s.Origin}{(s.Name == reserve ? "   · резерв" : "")}").ToList();

        var addXui = CUi.Btn("＋ Клиент на панели 3x-ui…", 0, 0);
        var addLink = CUi.Btn("＋ Ссылка подписки…", 0, 6);
        var addWg = CUi.Btn("＋ WireGuard / AWG…", 0, 6);
        var del = CUi.Btn("Убрать", 0, 6);
        addXui.Click += (_, _) =>
        {
            var s = new CascadeXuiSourceDialog(w, _store, c.Name, null, Taken(sources), LogOk).ShowDialog();
            if (s is null) return;
            sources.Add(s);
            Render();
        };
        addLink.Click += (_, _) =>
        {
            var s = CascadeLinkDialog.Show(w, null, Taken(sources), CUi.FreeName("SUB", Taken(sources)));
            if (s is null) return;
            sources.Add(s);
            Render();
        };
        addWg.Click += (_, _) =>
        {
            var d = new CascadeWgSourceDialog(w, _store, c.Name, null, reserve.Length == 0, Taken(sources), LogOk);
            if (d.ShowDialog() is not { } s) return;
            sources.Add(s);
            if (d.Reserve) reserve = s.Name;
            Render();
        };
        del.Click += (_, _) =>
        {
            if (list.SelectedIndex < 0) return;
            var s = sources[list.SelectedIndex];
            sources.RemoveAt(list.SelectedIndex);
            if (s.Name == reserve) reserve = "";
            Render();
        };

        var xray = CUi.Check("клиенты 3x-ui этого сервера (VLESS, Hysteria, встроенный AWG)", true);
        var awg = CUi.Check("клиенты AWG-панели этого сервера (интерфейсы wg* / awg*)", true);
        var mtp = CUi.Check("MTProto-прокси этого сервера (mtg, teleproxy, telemt, WEB): Telegram — по правилам TG", true);

        var root = new DockPanel { Margin = new Thickness(16) };
        var top = new StackPanel();
        top.Children.Add(CUi.Caption(
            "1. Источники нод — минимум один. Лучше свой клиент каскада на панели 3x-ui с нужным набором серверов " +
            "(единая подписка клиентов не трогается), можно и подписки отдельных нод, и WireGuard/AWG (например, резервом)."));
        var btns = CUi.H(addXui, addLink, addWg, del);
        btns.Margin = new Thickness(0, 0, 0, 8);
        top.Children.Add(btns);
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);

        var bottom = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        bottom.Children.Add(CUi.Caption("2. Кого сразу пустить через каскад (поменять можно потом — «Кто идёт в каскад»). " +
                                        "Чего на сервере нет — пропустится само.", 4));
        bottom.Children.Add(xray);
        bottom.Children.Add(awg);
        bottom.Children.Add(mtp);
        var status = CUi.Status();
        bottom.Children.Add(status);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var go = CUi.Btn("Установить", 130, 0);
        go.IsDefault = true;
        var cancel = CUi.Btn("Отмена");
        cancel.IsCancel = true;
        go.Click += (_, _) =>
        {
            if (sources.Count == 0) { status.Text = "✗ нужен хотя бы один источник нод"; return; }
            result = (sources, new Dictionary<string, string>
            {
                ["QC_XRAY_MODE"] = xray.IsChecked == true ? "all" : "off",
                ["QC_XRAY_LIST"] = "",
                ["QC_AWG_MODE"] = awg.IsChecked == true ? "all" : "off",
                ["QC_MTP"] = mtp.IsChecked == true ? "on" : "off",
                ["QC_RESERVE"] = reserve,
            });
            w.DialogResult = true;
        };
        cancel.Click += (_, _) => w.Close();
        row.Children.Add(go);
        row.Children.Add(cancel);
        bottom.Children.Add(row);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(bottom);
        root.Children.Add(list);
        w.Content = root;
        Render();
        w.ShowDialog();
        return Task.FromResult(result);
    }
}
