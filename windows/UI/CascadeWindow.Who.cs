using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>
/// «Кто идёт в каскад»: клиенты 3x-ui (правка шаблона Xray — выход в mihomo), клиенты AWG-панели
/// (nftables tproxy с интерфейсов wg*/awg*) и Telegram-трафик MTProto-прокси (mtg/teleproxy — мост докера,
/// telemt/WEB — по пользователю процесса). Выбор на экране меняется только по явному действию —
/// автообновление трогает лишь строки состояния.
/// </summary>
public partial class CascadeWindow
{
    private void RenderWho(bool full)
    {
        if (!Ready(out var c, out var st))
        {
            XrayState.Text = AwgState.Text = MtpState.Text = "";
            if (full) { XrayChecks.Children.Clear(); AwgChecks.Children.Clear(); }
            _whoFor = null;
            return;
        }
        var s = st.Status!;
        var env = s["env"];
        var d = st.Detect;

        var hasXui = d is null ? S(s, "xray") != "нет 3x-ui" : B(d, "xui");
        XrayState.Text = "сейчас: " + XrayText(S(s, "xray"));
        foreach (var rb in new[] { XrayAll, XrayInb, XrayUsers, XrayOff }) rb.IsEnabled = hasXui;

        var ifs = AwgIfaces(d);
        var am = S(env, "awgMode");
        AwgState.Text = (ifs.Count == 0 ? "WireGuard/AWG-интерфейсов на сервере нет" :
                            "на сервере: " + string.Join(", ", ifs.Select(i => i.Addr.Length > 0 ? $"{i.Name} ({i.Addr})" : i.Name))) +
                        " · сейчас: " + (am switch { "all" => "все", "list" => S(env, "awgIfaces"), _ => "никто" }) +
                        (am != "off" ? (B(s, "nf") ? " · перехват стоит" : " · перехват НЕ стоит") : "");

        var mtp = d?["mtp"];
        var users = L(mtp, "users");
        var ctrs = (mtp?["containers"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Select(o => $"{S(o, "name")} ({S(o, "image")})").ToList();
        MtpState.Text = (users.Count + ctrs.Count == 0
                            ? "MTProto-прокси на сервере не найдено — поставишь потом (скрипт MTProto), перехват подхватит сам"
                            : "найдено: " + string.Join(", ", users.Select(u => "пользователь " + u).Concat(ctrs.Select(x => "docker " + x)))) +
                        (S(env, "mtp") == "on" ? (B(s, "nf") ? " · перехват стоит" : " · перехват НЕ стоит") : " · сейчас выключено");

        if (!full) return;
        _whoFor = c.Id;
        _loadingUi = true;
        try
        {
            var xm = S(env, "xrayMode");
            (xm switch { "inbounds" => XrayInb, "users" => XrayUsers, "off" => XrayOff, _ => XrayAll }).IsChecked = true;
            BuildXrayChecks(xm, S(env, "xrayList").Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal));
            (am switch { "list" => AwgList, "off" => AwgOff, _ => AwgAll }).IsChecked = true;
            BuildAwgChecks(ifs.Select(i => i.Name).ToList(),
                S(env, "awgIfaces").Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal));
            AwgSrcBox.Text = S(env, "awgSrc");
            MtpBox.IsChecked = S(env, "mtp") == "on";
            MtpUsersBox.Text = S(env, "mtpUsers") is { Length: > 0 } mu ? mu : "telemt mtproxy";
        }
        finally { _loadingUi = false; }
    }

    private static List<(string Name, string Addr)> AwgIfaces(JsonObject? d) =>
        (d?["awg"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Select(o => (Name: S(o, "name"), Addr: S(o, "addr"))).Where(x => x.Name.Length > 0).ToList();

    private string XrayModeUi() =>
        XrayInb.IsChecked == true ? "inbounds" : XrayUsers.IsChecked == true ? "users" : XrayOff.IsChecked == true ? "off" : "all";

    private string AwgModeUi() =>
        AwgList.IsChecked == true ? "list" : AwgOff.IsChecked == true ? "off" : "all";

    private static IEnumerable<string> Checked(Panel p) =>
        p.Children.OfType<CheckBox>().Where(cb => cb.IsChecked == true).Select(cb => cb.Tag as string ?? "").Where(x => x.Length > 0);

    private void BuildXrayChecks(string mode, ISet<string> selected)
    {
        XrayChecks.Children.Clear();
        var d = Sel is { } c ? St(c).Detect : null;
        if (mode == "inbounds")
        {
            foreach (var ib in (d?["inbounds"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
            {
                var tag = S(ib, "tag");
                XrayChecks.Children.Add(new CheckBox
                {
                    Content = $"{(S(ib, "remark") is { Length: > 0 } rm ? rm : tag)}  ·  {S(ib, "protocol")}",
                    Tag = tag, IsChecked = selected.Contains(tag), Margin = new Thickness(0, 3, 18, 3),
                    ToolTip = tag,
                });
            }
            if (XrayChecks.Children.Count == 0) XrayChecks.Children.Add(new TextBlock { Text = "инбаундов не нашлось — «Обновить»" });
        }
        else if (mode == "users")
        {
            foreach (var em in L(d, "emails"))
                XrayChecks.Children.Add(new CheckBox
                {
                    Content = em, Tag = em, IsChecked = selected.Contains(em), Margin = new Thickness(0, 3, 18, 3),
                });
            if (XrayChecks.Children.Count == 0) XrayChecks.Children.Add(new TextBlock { Text = "клиентов не нашлось — «Обновить»" });
        }
    }

    private void BuildAwgChecks(List<string> ifs, ISet<string> selected)
    {
        AwgChecks.Children.Clear();
        var names = ifs.Concat(selected.Where(x => !ifs.Contains(x))).ToList();
        foreach (var n in names)
            AwgChecks.Children.Add(new CheckBox
            {
                Content = ifs.Contains(n) ? n : n + " (нет на сервере)",
                Tag = n, IsChecked = selected.Contains(n), Margin = new Thickness(0, 3, 18, 3),
            });
        AwgChecks.IsEnabled = AwgList.IsChecked == true;
    }

    private void XrayMode_Changed(object sender, RoutedEventArgs e)
    {
        if (_loadingUi) return;
        var keep = Checked(XrayChecks).ToHashSet(StringComparer.Ordinal);
        if (Ready(out _, out var st) && keep.Count == 0)
            keep = S(st.Status!["env"], "xrayList").Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet(StringComparer.Ordinal);
        BuildXrayChecks(XrayModeUi(), keep);
    }

    private void AwgMode_Changed(object sender, RoutedEventArgs e)
    {
        AwgChecks.IsEnabled = AwgList.IsChecked == true;
    }

    private async void WhoXray_Click(object sender, RoutedEventArgs e)
    {
        if (!SourcesReady(out _, out var st)) return;
        if (st.Detect is { } d && !B(d, "xui")) { XuiDialog.Info(this, "На сервере нет 3x-ui — перехватывать нечего", "Каскад"); return; }
        var mode = XrayModeUi();
        var list = string.Join(" ", Checked(XrayChecks));
        if (mode is "inbounds" or "users" && list.Length == 0) { XuiDialog.Info(this, "Ничего не отмечено", "Каскад"); return; }
        await Op("Клиенты 3x-ui через каскад", async (_, r) =>
        {
            await r.SetAsync(new Dictionary<string, string>
            {
                ["QC_XRAY_MODE"] = mode,
                ["QC_XRAY_LIST"] = mode is "inbounds" or "users" ? list : "",
            });
            Log("  3x-ui перезапускается — клиенты переподключатся", LogKind.Dim);
            var res = await r.QcAsync(mode == "off" ? "xray off" : "xray on", 240);
            LogQc(res.Out);
            if (!res.Ok) throw new XuiException("перехват не переключился — 3x-ui в прежнем состоянии (причина выше)");
        });
    }

    private async void WhoNf_Click(object sender, RoutedEventArgs e)
    {
        if (!SourcesReady(out _, out _)) return;
        var am = AwgModeUi();
        var ifs = string.Join(" ", Checked(AwgChecks));
        if (am == "list" && ifs.Length == 0) { XuiDialog.Info(this, "Отметь интерфейсы AWG-панели", "Каскад"); return; }
        var src = Regex.Replace(AwgSrcBox.Text.Trim(), @"[\s,;]+", " ");
        if (!Regex.IsMatch(src, @"^[0-9./ ]*$")) { XuiDialog.Info(this, "Адреса клиентов — IPv4-адреса или подсети через пробел", "Каскад"); return; }
        var users = Regex.Replace(MtpUsersBox.Text.Trim(), @"[\s,;]+", " ");
        if (!Regex.IsMatch(users, @"^[A-Za-z0-9._ -]*$")) { XuiDialog.Info(this, "Пользователи — системные имена через пробел", "Каскад"); return; }
        var mtp = MtpBox.IsChecked == true ? "on" : "off";
        await Op("AWG-панель и MTProto через каскад", async (c, r) =>
        {
            await r.SetAsync(new Dictionary<string, string>
            {
                ["QC_AWG_MODE"] = am,
                ["QC_AWG_IFACES"] = ifs,
                ["QC_AWG_SRC"] = src,
                ["QC_MTP"] = mtp,
                ["QC_MTP_USERS"] = users.Length > 0 ? users : "telemt mtproxy",
            });
            await ApplyAsync(c, r);
        });
    }
}
