using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>Раздел «AWG»: клиенты awg-panel всех нод в одной таблице — создать, вкл/выкл, удалить,
/// конфиг в буфер / в файл, QR. Доступ — логин/пароль админа (Basic), хранятся в вейлте.</summary>
public partial class XuiWindow
{
    public sealed class AwgRow
    {
        public AwgClient Src { get; init; } = null!;
        public string Panel => Src.Panel;
        public string Name => Src.Name;
        public string Iface { get; init; } = "";
        public string Address => Src.Address;
        public string Enabled => Src.Enabled ? "да" : "нет";
        public string Handshake { get; init; } = "";
        public string Traffic { get; init; } = "";
        public Brush DotBrush { get; init; } = Brushes.Gray;
    }

    private const string AllAwg = "Все AWG-ноды";
    private List<XuiPanel> _awgPanels = new();
    private List<AwgClient> _awgClients = new();
    private readonly Dictionary<Guid, List<AwgInterface>> _awgIfaces = new();
    private bool _awgLoading;

    private void LoadAwgPanels()
    {
        var keep = (AwgPanelBox.SelectedItem as XuiPanel)?.Id;
        _awgPanels = _store.Panels().Where(p => p.IsAwg).ToList();
        var items = new List<object> { AllAwg };
        items.AddRange(_awgPanels);
        AwgPanelBox.ItemsSource = items;
        AwgPanelBox.DisplayMemberPath = null;
        AwgPanelBox.ItemTemplate = null;
        AwgPanelBox.SelectedItem = items.OfType<XuiPanel>().FirstOrDefault(p => p.Id == keep) ?? (object)AllAwg;
    }

    private XuiPanel? AwgSelectedPanel => AwgPanelBox.SelectedItem as XuiPanel;

    /// <summary>Открыть раздел AWG на ноде.</summary>
    public void OpenAwg(Guid id)
    {
        if (!IsLoaded) { Loaded += (_, _) => OpenAwg(id); return; }
        LoadAwgPanels();
        if (AwgPanelBox.Items.OfType<XuiPanel>().FirstOrDefault(p => p.Id == id) is { } p)
            AwgPanelBox.SelectedItem = p;
        ShowSeg("awg");
    }

    /// <summary>«＋ Нода из выделения»: итог установщика в буфере (или пустая форма), новая или переустановка.</summary>
    private async void NodeFromSelection_Click(object sender, RoutedEventArgs e)
    {
        var text = "";
        try { text = Clipboard.GetText(); } catch { }
        var dlg = new NodeAddWindow(_store, text) { Owner = this };
        dlg.ShowDialog();
        if (dlg.Saved.Count == 0) return;
        try
        {
            var clip = Clipboard.GetText();
            if (dlg.Passwords.Any(pw => clip.Contains(pw, StringComparison.Ordinal))) Clipboard.Clear();
        }
        catch { }
        await AfterNodeAddedAsync(dlg.Saved, dlg.ConnectId);
    }

    /// <summary>После «Нода из выделения» (из главного окна или отсюда): перечитать панели и показать результат —
    /// новую 3x-ui ноду подключить к главной, AWG — открыть её клиентов.</summary>
    public void AfterNodeAdded(List<(Guid Id, string Role)> saved, Guid? connectId)
    {
        if (!IsLoaded) { Loaded += async (_, _) => await AfterNodeAddedAsync(saved, connectId); return; }
        _ = AfterNodeAddedAsync(saved, connectId);
    }

    private async Task AfterNodeAddedAsync(List<(Guid Id, string Role)> saved, Guid? connectId)
    {
        foreach (var (id, _) in saved)
            if (_store.PanelById(id) is { } p) Log($"✓ {p.RoleText} «{p.Name}» сохранена", LogKind.Ok);
        await ReloadPanelsAsync();
        if (connectId is { } cid && _store.PanelById(cid) is { } node && _master is not null)
        {
            ShowSeg("nodes");
            await RefreshAsync(); // план ревизии строится по свежим инбаундам/узлам главной
            await ConnectOrRevise(node.Url, node.Token, node.VerifyTls, node.Name, attachOthers: false, save: false);
            return;
        }
        var awg = saved.LastOrDefault(s => s.Role is "awg" or "awg1");
        if (awg.Id != Guid.Empty) { OpenAwg(awg.Id); return; }
        ShowSeg("nodes");
    }

    private async void AwgPanel_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (IsLoaded) await RefreshAwgAsync();
    }

    private void AwgSearch_Changed(object sender, TextChangedEventArgs e) => RenderAwg();

    private async Task RefreshAwgAsync(bool quiet = false)
    {
        if (_awgLoading) return;
        if (_awgPanels.Count == 0)
        {
            AwgStatus.Text = "AWG-нод нет — «＋ Нода из выделения» (выдели итог установщика в терминале) или «Панели и токены…»";
            _awgClients = new();
            RenderAwg();
            return;
        }
        _awgLoading = true;
        if (!quiet) AwgStatus.Text = "обновляю…";
        var list = new List<AwgClient>();
        var errors = new List<string>();
        var targets = AwgSelectedPanel is { } one ? new List<XuiPanel> { one } : _awgPanels;
        // все ноды параллельно: одна лежащая не тормозит остальные
        var tasks = targets.Select(async p =>
        {
            try
            {
                using var api = AwgApi.For(p);
                var ifs = await api.InterfacesAsync();
                var cl = await api.ClientsAsync(p);
                return (p, ifs, cl, (string?)null);
            }
            catch (XuiException ex) { return (p, new List<AwgInterface>(), new List<AwgClient>(), ex.Message); }
            catch (Exception ex) { return (p, new List<AwgInterface>(), new List<AwgClient>(), $"{p.Name}: {ex.Message}"); }
        }).ToList();
        foreach (var (p, ifs, cl, err) in await Task.WhenAll(tasks))
        {
            if (err is not null) { errors.Add(err); continue; }
            _awgIfaces[p.Id] = ifs;
            list.AddRange(cl);
            SnapshotAwgClients(p.Id, cl);
        }
        _awgClients = list;
        _awgLoading = false;
        RenderAwg();
        AwgStatus.Text = errors.Count > 0
            ? "✗ " + string.Join(" · ", errors)
            : $"нод {targets.Count}, клиентов {list.Count}, на связи {list.Count(c => IsFresh(c.Handshake))} · {DateTime.Now:HH:mm:ss}";
        if (errors.Count > 0 && !quiet) foreach (var er in errors) Log("✗ " + er, LogKind.Err);
    }

    /// <summary>Запомнить имена клиентов ноды в вейлте: после переустановки их можно пересоздать на новой панели.
    /// Пустой список старый не затирает — пустая свежая панель как раз и есть переустановка.</summary>
    private void SnapshotAwgClients(Guid id, List<AwgClient> cl)
    {
        var names = cl.Select(c => c.Name).Where(n => n.Length > 0).Distinct()
            .OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();
        if (_store.PanelById(id) is not { } fresh) return;
        if (names.Count == 0 && fresh.Clients is { Count: > 0 }) return;
        if (fresh.Clients is not null && fresh.Clients.SequenceEqual(names)) return;
        fresh.Clients = names;
        _store.SavePanel(fresh);
    }

    private static bool IsFresh(DateTime? hs) => hs is { } d && DateTime.UtcNow - d < TimeSpan.FromMinutes(3);

    private static string Ago(DateTime? hs)
    {
        if (hs is not { } d) return "—";
        var t = DateTime.UtcNow - d;
        if (t.TotalSeconds < 60) return $"{(int)t.TotalSeconds} с назад";
        if (t.TotalMinutes < 60) return $"{(int)t.TotalMinutes} мин назад";
        if (t.TotalHours < 48) return $"{(int)t.TotalHours} ч назад";
        return $"{(int)t.TotalDays} д назад";
    }

    private void RenderAwg()
    {
        var f = AwgSearch.Text.Trim();
        var sel = AwgList.SelectedItems.OfType<AwgRow>().Select(r => (r.Src.PanelId, r.Src.Id)).ToHashSet();
        var rows = _awgClients
            .Where(c => f.Length == 0 || c.Name.Contains(f, StringComparison.OrdinalIgnoreCase) || c.Address.Contains(f))
            .OrderBy(c => c.Panel, StringComparer.OrdinalIgnoreCase).ThenBy(c => c.Name, StringComparer.OrdinalIgnoreCase)
            .Select(c =>
            {
                var ifs = _awgIfaces.GetValueOrDefault(c.PanelId);
                var i = ifs?.FirstOrDefault(x => x.Name == c.InterfaceId);
                return new AwgRow
                {
                    Src = c,
                    Iface = i?.Label ?? c.InterfaceId,
                    Handshake = Ago(c.Handshake),
                    Traffic = $"{Bytes(c.Rx)} / {Bytes(c.Tx)}",
                    DotBrush = !c.Enabled ? Red : IsFresh(c.Handshake) ? Green : Dim,
                };
            }).ToList();
        AwgList.ItemsSource = rows;
        foreach (var r in rows.Where(r => sel.Contains((r.Src.PanelId, r.Src.Id)))) AwgList.SelectedItems.Add(r);
    }

    private List<AwgClient> AwgSelected() => AwgList.SelectedItems.OfType<AwgRow>().Select(r => r.Src).ToList();

    private XuiPanel? PanelOf(AwgClient c) => _awgPanels.FirstOrDefault(p => p.Id == c.PanelId);

    private async Task<string?> ConfigOf(AwgClient c)
    {
        if (PanelOf(c) is not { } p) return null;
        try
        {
            using var api = AwgApi.For(p);
            return await api.ConfigAsync(c.Id);
        }
        catch (XuiException ex) { Log("✗ " + ex.Message, LogKind.Err); return null; }
    }

    private AwgClient? OneAwg()
    {
        var s = AwgSelected();
        if (s.Count == 1) return s[0];
        XuiDialog.Info(this, "Выбери одного клиента");
        return null;
    }

    private async void AwgCopy_Click(object sender, RoutedEventArgs e)
    {
        if (OneAwg() is not { } c) return;
        if (await ConfigOf(c) is not { } conf) return;
        try { Clipboard.SetText(conf); Log($"✓ конфиг {c.Panel}/{c.Name} в буфере", LogKind.Ok); } catch { }
    }

    private async void AwgQr_Click(object sender, RoutedEventArgs e)
    {
        if (OneAwg() is not { } c) return;
        if (await ConfigOf(c) is not { } conf) return;
        XuiQrWindow.ShowConfig(this, $"{c.Panel} · {c.Name}", conf);
    }

    private void AwgList_DoubleClick(object sender, MouseButtonEventArgs e) => AwgQr_Click(sender, e);

    private static string SafeFile(string s) =>
        string.Concat(s.Select(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_' or '.' ? ch : '_'));

    private async void AwgSave_Click(object sender, RoutedEventArgs e)
    {
        var sel = AwgSelected();
        if (sel.Count == 0) { XuiDialog.Info(this, "Выдели клиентов"); return; }
        string? dir;
        if (sel.Count == 1)
        {
            var dlg = new Microsoft.Win32.SaveFileDialog
            {
                FileName = SafeFile($"{sel[0].Panel}-{sel[0].Name}") + ".conf",
                Filter = "Конфиг WireGuard/AWG (*.conf)|*.conf",
            };
            if (dlg.ShowDialog(this) != true) return;
            if (await ConfigOf(sel[0]) is { } conf)
            {
                await File.WriteAllTextAsync(dlg.FileName, conf);
                Log("✓ сохранено: " + dlg.FileName, LogKind.Ok);
            }
            return;
        }
        var fd = new Microsoft.Win32.OpenFolderDialog { Title = "Куда сохранить конфиги" };
        if (fd.ShowDialog(this) != true) return;
        dir = fd.FolderName;
        foreach (var c in sel)
            if (await ConfigOf(c) is { } conf)
            {
                var path = Path.Combine(dir, SafeFile($"{c.Panel}-{c.Name}") + ".conf");
                await File.WriteAllTextAsync(path, conf);
                Log("✓ " + path, LogKind.Ok);
            }
    }

    private async void AwgToggle_Click(object sender, RoutedEventArgs e)
    {
        var sel = AwgSelected();
        if (sel.Count == 0) return;
        var on = !sel.All(c => c.Enabled);
        foreach (var g in sel.GroupBy(c => c.PanelId))
        {
            if (PanelOf(g.First()) is not { } p) continue;
            using var api = AwgApi.For(p);
            foreach (var c in g)
            {
                try { await api.EnableAsync(c.Id, on); Log($"✓ {c.Panel}/{c.Name}: {(on ? "вкл" : "выкл")}", LogKind.Ok); }
                catch (XuiException ex) { Log("✗ " + ex.Message, LogKind.Err); }
            }
        }
        await RefreshAwgAsync(quiet: true);
    }

    private async void AwgDelete_Click(object sender, RoutedEventArgs e)
    {
        var sel = AwgSelected();
        if (sel.Count == 0) return;
        if (!XuiDialog.Confirm(this, "Удалить клиентов AWG: " + string.Join(", ", sel.Select(c => $"{c.Panel}/{c.Name}")) +
                "?\n\nУстройства с их конфигами перестанут подключаться.", "Удаление", "Удалить")) return;
        foreach (var g in sel.GroupBy(c => c.PanelId))
        {
            if (PanelOf(g.First()) is not { } p) continue;
            using var api = AwgApi.For(p);
            foreach (var c in g)
            {
                try { await api.DeleteAsync(c.Id); Log($"✓ {c.Panel}/{c.Name} удалён", LogKind.Ok); }
                catch (XuiException ex) { Log("✗ " + ex.Message, LogKind.Err); }
            }
        }
        await RefreshAwgAsync(quiet: true);
    }

    private async void AwgNew_Click(object sender, RoutedEventArgs e)
    {
        if (_awgPanels.Count == 0) { XuiDialog.Info(this, "Сначала добавь AWG-ноду в «AWG-панели…»"); return; }
        var name = InputDialog.Ask(this, "Имя клиента AWG:");
        if (name is null) return;
        var targets = AwgSelectedPanel is { } one ? new List<XuiPanel> { one } : _awgPanels;
        if (AwgSelectedPanel is null && _awgPanels.Count > 1)
        {
            var w = XuiDialog.Show(this, $"Создать «{name}» на всех AWG-нодах ({_awgPanels.Count})?\n" +
                "Чтобы создать на одной — выбери её в списке слева сверху.", "Новый клиент AWG", "На всех", "Отмена");
            if (w != 0) return;
        }
        // версия AWG: если где-то есть и 2.0, и 3.1 — спросить
        var all = targets.SelectMany(p => _awgIfaces.GetValueOrDefault(p.Id) ?? new()).ToList();
        bool has20 = all.Any(i => !i.IsAwg31 && i.Enabled), has31 = all.Any(i => i.IsAwg31 && i.Enabled);
        int ver = 0; // 0 — по умолчанию (интерфейс по умолчанию), 1 — 2.0, 2 — 3.1, 3 — оба
        if (has20 && has31)
        {
            var v = XuiDialog.Show(this, "На каком интерфейсе? (Keenetic понимает только AWG 2.0)", "Новый клиент AWG",
                "AWG 2.0", "AWG 3.1", "Оба", "Отмена");
            if (v is < 0 or 3) return;
            ver = v + 1;
        }
        foreach (var p in targets)
        {
            var ifs = _awgIfaces.GetValueOrDefault(p.Id) ?? new();
            var want = ver switch
            {
                1 => ifs.Where(i => !i.IsAwg31 && i.Enabled).Take(1),
                2 => ifs.Where(i => i.IsAwg31 && i.Enabled).Take(1),
                3 => ifs.Where(i => i.Enabled).GroupBy(i => i.IsAwg31).Select(g => g.First()),
                _ => Enumerable.Empty<AwgInterface>(),
            };
            var list = want.Select(i => (string?)i.Name).ToList();
            if (list.Count == 0) list.Add(null); // интерфейс по умолчанию
            using var api = AwgApi.For(p);
            foreach (var iface in list)
            {
                var nm = ver == 3 && iface is not null
                    ? $"{name}-{(ifs.First(i => i.Name == iface).IsAwg31 ? "31" : "20")}" : name;
                try { await api.CreateAsync(nm, iface); Log($"✓ {p.Name}: {nm}{(iface is null ? "" : " на " + iface)}", LogKind.Ok); }
                catch (XuiException ex) { Log("✗ " + ex.Message, LogKind.Err); }
            }
        }
        await RefreshAwgAsync(quiet: true);
    }
}
