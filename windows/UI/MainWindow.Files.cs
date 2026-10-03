using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using QTermWin.Models;
using QTermWin.Terminal;

namespace QTermWin.UI;

/// <summary>
/// Файловая панель по мотивам MobaXterm: тулбар иконок, путь + история,
/// иконки типов, множественное выделение, мобовское контекстное меню,
/// drag&amp;drop в обе стороны, средняя кнопка = путь в терминал,
/// «следовать за папкой терминала». Бекенд живёт с нодой (мак-канон),
/// панель следует за активной вкладкой.
/// </summary>
public partial class MainWindow
{
    // ── Состояние ──

    private readonly Dictionary<Guid, Files.FileService> _files = new();
    private Guid? _filesTab;
    private bool _fsBusy;
    private bool _filesUserHidden; // пользователь скрыл панель кнопкой
    private readonly HashSet<Guid> _filesCreating = new();
    private bool _fsShowHidden = Security.AppSettings.Load().FsShowHidden ?? true;
    private bool _fsFollow = Security.AppSettings.Load().FsFollowTerminal ?? false;
    private string _fsSort = "name";
    private bool _fsDesc;

    private sealed record FsRow(string Name, string Glyph, Brush IconBrush, double Dim,
        string SizeText, string Modified, string Perms, string Owner, Files.RemoteEntry? Entry);

    private Files.FileService? ActiveFs =>
        _filesTab is { } id && _files.TryGetValue(id, out var s) ? s : null;

    private const long EditorMaxBytes = 2 * 1024 * 1024;

    // ── Иконки типов (Segoe Fluent Icons / MDL2) ──

    private static Brush Fz(string hex)
    {
        var b = (SolidColorBrush)new BrushConverter().ConvertFromString(hex)!;
        b.Freeze();
        return b;
    }

    private static readonly Brush IcFolder = Fz("#E8B44C"), IcBlue = Fz("#4FA3E3"), IcGreen = Fz("#3FB950"),
        IcOrange = Fz("#DB6D28"), IcPurple = Fz("#A371F7"), IcCyan = Fz("#39C5CF"), IcGray = Fz("#9AA0A6");

    private static readonly HashSet<string> ExtArchive = new(StringComparer.OrdinalIgnoreCase)
        { ".zip", ".tar", ".gz", ".tgz", ".xz", ".bz2", ".7z", ".rar", ".zst", ".deb", ".rpm", ".ipk", ".apk" };
    private static readonly HashSet<string> ExtImage = new(StringComparer.OrdinalIgnoreCase)
        { ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".bmp" };
    private static readonly HashSet<string> ExtCode = new(StringComparer.OrdinalIgnoreCase)
        { ".sh", ".bash", ".py", ".js", ".ts", ".go", ".c", ".h", ".cpp", ".cs", ".rs", ".java", ".pl", ".rb", ".php", ".lua", ".ps1", ".swift", ".kt" };
    private static readonly HashSet<string> ExtConfig = new(StringComparer.OrdinalIgnoreCase)
        { ".yaml", ".yml", ".json", ".conf", ".cfg", ".ini", ".toml", ".xml", ".env", ".service", ".rules", ".list", ".properties" };
    private static readonly HashSet<string> ExtText = new(StringComparer.OrdinalIgnoreCase)
        { ".txt", ".md", ".log", ".csv", ".good", ".bak", ".old", ".orig" };

    private static (string Glyph, Brush Brush) IconFor(Files.RemoteEntry? e)
    {
        if (e is null) return ("", IcBlue);          // ..
        if (e.IsDir) return ("", IcFolder);
        if (e.IsLink) return ("", IcCyan);
        var ext = Path.GetExtension(e.Name);
        if (ExtArchive.Contains(ext)) return ("", IcOrange);
        if (ExtImage.Contains(ext)) return ("", IcPurple);
        if (ExtCode.Contains(ext)) return ("", IcGreen);
        if (ExtConfig.Contains(ext)) return ("", IcBlue);
        if (ExtText.Contains(ext)) return ("", IcGray);
        if (e.Perms.Length >= 3 && e.Perms[2] is 'x' or 's') return ("", IcGreen); // исполняемый
        return ("", IcGray);
    }

    // ── Показ/скрытие панели и жизненный цикл бекенда ──

    /// <summary>Кнопка «Файлы» — только скрыть/показать (бекенд живёт с нодой).</summary>
    private void FilesButton_Click(object sender, RoutedEventArgs e)
    {
        if (FilesCol.Width.Value > 0)
        {
            _filesUserHidden = true;
            HideFiles();
            return;
        }
        _filesUserHidden = false;
        ShowFilesPanel();
        RenderFilesOrProgress();
    }

    private void ShowFilesPanel()
    {
        FilesCol.Width = new GridLength(400);
        FilesSplitCol.Width = new GridLength(4);
        FilesSplitter.Visibility = Visibility.Visible;
        FsFollowBox.IsChecked = _fsFollow;
        PaintHiddenBtn();
    }

    private void HideFiles()
    {
        FilesCol.Width = new GridLength(0);
        FilesSplitCol.Width = new GridLength(0);
        FilesSplitter.Visibility = Visibility.Collapsed;
    }

    /// <summary>Файловый бекенд поднимается вместе с нодой (мак-канон):
    /// зовётся при каждом Connected, при реконнекте пересоздаёт мёртвый.</summary>
    private void EnsureFiles(Guid tabId, SshSessionController ctl)
    {
        if (_filesCreating.Contains(tabId)) return;
        if (_files.Remove(tabId, out var stale)) stale.Dispose(); // после реконнекта — свежий
        _filesCreating.Add(tabId);
        if (!_filesUserHidden) ShowFilesPanel();
        if (_filesTab == tabId || _filesTab is null) { _filesTab = tabId; RenderFilesOrProgress(); }
        Task.Run(() =>
        {
            try
            {
                var svc = Files.FileService.Create(ctl);
                svc.Refresh();
                RunOnUi(() =>
                {
                    _filesCreating.Remove(tabId);
                    _files[tabId] = svc;
                    if (_filesTab == tabId)
                    {
                        FsBusy(false);
                        RenderFiles();
                        FsStatus.Text = $"Режим: {svc.Fs.Kind} · элементов: {svc.Entries.Count}";
                    }
                });
            }
            catch (Exception ex)
            {
                RunOnUi(() =>
                {
                    _filesCreating.Remove(tabId);
                    if (_filesTab == tabId)
                    {
                        FsBusy(false);
                        FsPath.Text = "";
                        FsStatus.Text = "Файлы: " + ex.Message;
                    }
                });
            }
        });
    }

    private void RenderFilesOrProgress()
    {
        if (_filesTab is { } id && _filesCreating.Contains(id))
        {
            FsBusy(true);
            FsPath.Text = "подключение…";
            FsStatus.Text = "Определяю режим (SFTP/exec)…";
            FsList.ItemsSource = null;
            return;
        }
        FsBusy(false);
        RenderFiles();
    }

    private void FsBusy(bool busy)
    {
        _fsBusy = busy;
        FsList.IsEnabled = !busy;
        FsPath.IsEnabled = !busy;
        FsToolbar.IsEnabled = !busy;
        FsHistoryBtn.IsEnabled = !busy;
    }

    // ── Список ──

    private static readonly string[] DateFormats =
        { "dd.MM.yy HH:mm", "MMM d HH:mm", "MMM dd HH:mm", "MMM d yyyy", "MMM dd yyyy" };

    private static DateTime ParseDate(string s)
    {
        var norm = Regex.Replace(s.Trim(), @"\s+", " ");
        return DateTime.TryParseExact(norm, DateFormats, CultureInfo.InvariantCulture,
            DateTimeStyles.AllowWhiteSpaces, out var d) ? d : DateTime.MinValue;
    }

    private void RenderFiles()
    {
        var svc = ActiveFs;
        if (svc is null) { FsList.ItemsSource = null; FsPath.Text = ""; return; }
        FsPath.Text = svc.CurrentPath;

        IEnumerable<Files.RemoteEntry> items = svc.Entries;
        if (!_fsShowHidden) items = items.Where(en => !en.Name.StartsWith('.'));
        Func<Files.RemoteEntry, object> key = _fsSort switch
        {
            "size" => en => en.Size,
            "date" => en => ParseDate(en.Modified),
            "perms" => en => en.Perms,
            "owner" => en => en.Owner,
            _ => en => en.Name.ToLowerInvariant(),
        };
        var dirsFirst = items.OrderByDescending(en => en.IsDir);
        var sorted = _fsDesc ? dirsFirst.ThenByDescending(key) : dirsFirst.ThenBy(key);

        var rows = new List<FsRow>();
        if (svc.CurrentPath != "/")
        {
            var (g0, b0) = IconFor(null);
            rows.Add(new FsRow("..", g0, b0, 1, "", "", "", "", null));
        }
        foreach (var en in sorted)
        {
            var (g, b) = IconFor(en);
            rows.Add(new FsRow(en.Name + (en.IsLink ? " →" : ""), g, b,
                en.Name.StartsWith('.') ? 0.6 : 1,
                en.IsDir ? "" : FmtSize(en.Size), en.Modified, en.Perms, en.Owner, en));
        }
        FsList.ItemsSource = rows;
    }

    private static string FmtSize(long b) => b switch
    {
        < 1024 => $"{b} Б",
        < 1024 * 1024 => $"{b / 1024.0:0.#} КБ",
        < 1024L * 1024 * 1024 => $"{b / 1048576.0:0.#} МБ",
        _ => $"{b / 1073741824.0:0.##} ГБ",
    };

    private List<Files.RemoteEntry> SelectedEntries() =>
        FsList.SelectedItems.OfType<FsRow>().Where(r => r.Entry is not null).Select(r => r.Entry!).ToList();

    private static FsRow? RowAt(object? src)
    {
        var d = src as DependencyObject;
        while (d is not null and not ListViewItem)
            d = d is Visual or System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(d)
                : LogicalTreeHelper.GetParent(d);
        return (d as ListViewItem)?.DataContext as FsRow;
    }

    private string Remote(Files.FileService svc, Files.RemoteEntry en) =>
        Files.RemotePath.Join(svc.CurrentPath, en.Name);

    private void FsList_HeaderClick(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is not GridViewColumnHeader { Column: { } col }) return;
        var k = (col.Header as string) switch
        {
            "Размер" => "size",
            "Дата" => "date",
            "Права" => "perms",
            "Владелец" => "owner",
            _ => "name",
        };
        _fsDesc = _fsSort == k && !_fsDesc;
        _fsSort = k;
        RenderFiles();
    }

    // ── Навигация ──

    private void FsNavigate(string path)
    {
        var svc = ActiveFs;
        if (svc is null || _fsBusy) return;
        FsBusy(true);
        FsStatus.Text = "Чтение…";
        Task.Run(() =>
        {
            try
            {
                var entries = svc.ListL(path);
                RunOnUi(() =>
                {
                    svc.CurrentPath = path;
                    svc.Entries = entries;
                    svc.Remember(path);
                    FsBusy(false);
                    RenderFiles();
                    FsStatus.Text = $"Режим: {svc.Fs.Kind} · элементов: {entries.Count}";
                });
            }
            catch (Exception ex)
            {
                RunOnUi(() => { FsBusy(false); FsStatus.Text = "Ошибка: " + ex.Message; });
            }
        });
    }

    private void FsUp_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is { } svc && svc.CurrentPath != "/") FsNavigate(Files.RemotePath.Parent(svc.CurrentPath));
    }

    private void FsRefresh_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is { } svc) FsNavigate(svc.CurrentPath);
    }

    private void FsPath_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || string.IsNullOrWhiteSpace(FsPath.Text)) return;
        var p = FsPath.Text.Trim();
        if (p.StartsWith('~') && ActiveFs is { } svc) p = svc.HomeDir.TrimEnd('/') + p[1..];
        FsNavigate(p);
        e.Handled = true;
    }

    private void FsHistory_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc) return;
        var menu = new ContextMenu { PlacementTarget = FsHistoryBtn, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        foreach (var p in svc.History)
        {
            var path = p;
            var mi = new MenuItem { Header = p.Replace("_", "__"), IsChecked = p == svc.CurrentPath };
            mi.Click += (s, a) => FsNavigate(path);
            menu.Items.Add(mi);
        }
        if (svc.History.Count > 0) menu.Items.Add(new Separator());
        var home = new MenuItem { Header = "Домашняя папка  " + svc.HomeDir.Replace("_", "__") };
        home.Click += (s, a) => FsNavigate(svc.HomeDir);
        menu.Items.Add(home);
        var root = new MenuItem { Header = "Корень  /" };
        root.Click += (s, a) => FsNavigate("/");
        menu.Items.Add(root);
        var start = _filesTab is { } id ? StartPathOf(id) : null;
        if (!string.IsNullOrWhiteSpace(start))
        {
            var st = new MenuItem { Header = "Стартовая папка  " + start!.Replace("_", "__") };
            st.Click += (s, a) => FsNavigate(start);
            menu.Items.Add(st);
        }
        menu.IsOpen = true;
    }

    private string? StartPathOf(Guid tabId)
    {
        SshSessionController? c;
        lock (_controllers) _controllers.TryGetValue(tabId, out c);
        return c?.SessionRef.Extra.GetValueOrDefault("sftpPath");
    }

    // ── Открытие ──

    private void FsList_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (RowAt(e.OriginalSource) is not { } row) return;
        OpenRow(row);
    }

    private void OpenRow(FsRow row)
    {
        if (ActiveFs is not { } svc || _fsBusy) return;
        if (row.Entry is null) { FsUp_Click(this, new RoutedEventArgs()); return; }
        var en = row.Entry;
        if (en.IsDir) { FsNavigate(Remote(svc, en)); return; }
        if (en.IsLink) { OpenLink(svc, en); return; }
        _ = OpenInEditorAsync(svc, en);
    }

    /// <summary>Симлинк: сначала пробуем как папку, не вышло — как файл.</summary>
    private void OpenLink(Files.FileService svc, Files.RemoteEntry en)
    {
        var remote = Remote(svc, en);
        FsBusy(true);
        Task.Run(() =>
        {
            List<Files.RemoteEntry>? entries = null;
            try { entries = svc.ListL(remote); } catch { }
            RunOnUi(() =>
            {
                FsBusy(false);
                if (entries is not null)
                {
                    svc.CurrentPath = remote;
                    svc.Entries = entries;
                    svc.Remember(remote);
                    RenderFiles();
                    FsStatus.Text = $"Режим: {svc.Fs.Kind} · элементов: {entries.Count}";
                }
                else _ = OpenInEditorAsync(svc, en);
            });
        });
    }

    private static bool LooksBinary(byte[] data)
    {
        // UTF-16 (BOM FF FE / FE FF) полон нулей, но это текст — QEditor его читает
        var utf16 = data.Length >= 2 && (data[0] == 0xFF && data[1] == 0xFE || data[0] == 0xFE && data[1] == 0xFF);
        return !utf16 && data.Take(8192).Contains((byte)0);
    }

    private string NodeName()
    {
        if (_filesTab is not { } id) return "?";
        SshSessionController? c;
        lock (_controllers) _controllers.TryGetValue(id, out c);
        return c?.SessionRef.Name ?? "?";
    }

    /// <summary>Скачать и открыть в QEditor. Возвращает id документа (или null).</summary>
    private async Task<string?> OpenInEditorAsync(Files.FileService svc, Files.RemoteEntry en)
    {
        if (en.Size > EditorMaxBytes)
        {
            FsStatus.Text = $"«{en.Name}» больше 2 МБ — редактор не для таких, есть «Скачать»";
            return null;
        }
        var remote = Remote(svc, en);
        FsBusy(true);
        FsStatus.Text = "Открытие…";
        try
        {
            var data = await Task.Run(() => svc.DownloadL(remote));
            if (LooksBinary(data)) { FsStatus.Text = $"«{en.Name}» — бинарный, только «Скачать»"; return null; }
            FsStatus.Text = $"Режим: {svc.Fs.Kind}";
            return await _editor.OpenAsync(svc, remote, data, NodeName()); // сырые байты: кодировку решает QEditor
        }
        catch (Exception ex)
        {
            FsStatus.Text = "Ошибка: " + ex.Message;
            return null;
        }
        finally { FsBusy(false); }
    }

    private void FsOpenEditor_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc) return;
        var files = SelectedEntries().Where(en => !en.IsDir).ToList();
        if (files.Count == 0) { FsStatus.Text = "Выдели файл"; return; }
        _ = OpenManyAsync(svc, files);
    }

    private async Task OpenManyAsync(Files.FileService svc, List<Files.RemoteEntry> files)
    {
        foreach (var en in files) await OpenInEditorAsync(svc, en);
    }

    // ── Внешние программы: temp-файл + вотчер → авто-заливка на ноду ──

    /// <summary>exe = null — программа по умолчанию (ассоциация Windows).</summary>
    private void OpenExternal(Files.FileService svc, Files.RemoteEntry en, string? exe)
    {
        var remote = Remote(svc, en);
        FsBusy(true);
        FsStatus.Text = "Скачивание для внешней программы…";
        Task.Run(() =>
        {
            try
            {
                var data = svc.DownloadL(remote);
                var dir = Path.Combine(Path.GetTempPath(), "QTerm",
                    remote.TrimStart('/').Replace('/', '_') + "_" + Guid.NewGuid().ToString("N")[..6]);
                Directory.CreateDirectory(dir);
                var local = Path.Combine(dir, en.Name);
                File.WriteAllBytes(local, data);
                RunOnUi(() =>
                {
                    FsBusy(false);
                    try
                    {
                        System.Diagnostics.Process.Start(string.IsNullOrWhiteSpace(exe)
                            ? new System.Diagnostics.ProcessStartInfo(local) { UseShellExecute = true }
                            : new System.Diagnostics.ProcessStartInfo(exe, $"\"{local}\""));
                    }
                    catch (Exception ex)
                    {
                        FsStatus.Text = "Не открылось: " + ex.Message;
                        return;
                    }
                    var w = new FileSystemWatcher(dir, en.Name)
                    {
                        NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size,
                        EnableRaisingEvents = true,
                    };
                    DateTime last = DateTime.MinValue;
                    w.Changed += (s, a) =>
                    {
                        // дебаунс: редакторы пишут несколькими событиями
                        var now = DateTime.UtcNow;
                        if ((now - last).TotalMilliseconds < 500) return;
                        last = now;
                        Task.Run(() =>
                        {
                            try
                            {
                                System.Threading.Thread.Sleep(200); // дописаться
                                var bytes = File.ReadAllBytes(local);
                                svc.UploadL(remote, bytes);
                                RunOnUi(() => FsStatus.Text =
                                    $"↻ {en.Name} залит {DateTime.Now:HH:mm:ss} ({bytes.Length} байт)");
                            }
                            catch (Exception ex)
                            {
                                RunOnUi(() => FsStatus.Text = "Заливка не удалась: " + ex.Message);
                            }
                        });
                    };
                    _externalEdits.Add(new ExternalEdit(w, local, remote, svc));
                    FsStatus.Text = $"Сохранения {en.Name} улетают на ноду сами";
                });
            }
            catch (Exception ex)
            {
                RunOnUi(() => { FsBusy(false); FsStatus.Text = "Ошибка: " + ex.Message; });
            }
        });
    }

    private void OpenWithPicked(Files.FileService svc, Files.RemoteEntry en)
    {
        var dlg = new OpenFileDialog { Title = $"Открыть «{en.Name}» с помощью…", Filter = "Программы (*.exe)|*.exe" };
        if (dlg.ShowDialog(this) == true) OpenExternal(svc, en, dlg.FileName);
    }

    // ── Сравнение (в QEditor) ──

    private async Task CompareSelectedAsync()
    {
        if (ActiveFs is not { } svc) return;
        var files = SelectedEntries().Where(en => !en.IsDir).ToList();
        try
        {
            if (files.Count == 2)
            {
                var a = await OpenInEditorAsync(svc, files[0]);
                var b = a is null ? null : await OpenInEditorAsync(svc, files[1]);
                if (a is not null && b is not null) await _editor.CompareAsync(a, b);
                return;
            }
            if (files.Count != 1) { FsStatus.Text = "Сравнение: выдели 1 файл (с локальным) или 2 файла"; return; }
            var dlg = new OpenFileDialog { Title = $"С каким локальным файлом сравнить «{files[0].Name}»?" };
            if (dlg.ShowDialog(this) != true) return;
            var doc = await OpenInEditorAsync(svc, files[0]);
            if (doc is not null) await _editor.CompareLocalAsync(doc, dlg.FileName);
        }
        catch (Exception ex) { FsStatus.Text = "Сравнение: " + ex.Message; }
    }

    // ── Операции ──

    /// <summary>Фоновая операция с перечитыванием папки по окончании.</summary>
    private void FsOp(Files.FileService svc, string busyText, Action op, string doneText = "Готово", bool relist = true)
    {
        FsBusy(true);
        FsStatus.Text = busyText;
        Task.Run(() =>
        {
            try
            {
                op();
                var entries = relist ? svc.ListL(svc.CurrentPath) : null;
                RunOnUi(() =>
                {
                    if (entries is not null) svc.Entries = entries;
                    FsBusy(false);
                    if (entries is not null) RenderFiles();
                    FsStatus.Text = doneText;
                });
            }
            catch (Exception ex)
            {
                RunOnUi(() => { FsBusy(false); FsStatus.Text = "Ошибка: " + ex.Message; });
            }
        });
    }

    private void FsDownload_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc || _fsBusy) return;
        var sel = SelectedEntries();
        if (sel.Count == 0) { FsStatus.Text = "Выдели файлы или папки для скачивания"; return; }
        if (sel.Count == 1 && !sel[0].IsDir)
        {
            var en = sel[0];
            var dlg = new SaveFileDialog { FileName = en.Name };
            if (dlg.ShowDialog(this) != true) return;
            var remote = Remote(svc, en);
            var local = dlg.FileName;
            FsOp(svc, "Скачивание…", () => File.WriteAllBytes(local, svc.DownloadL(remote)),
                $"Скачано: {en.Name} ({FmtSize(en.Size)})", relist: false);
            return;
        }
        var fd = new OpenFolderDialog { Title = "Куда скачать" };
        if (fd.ShowDialog(this) != true) return;
        var dir = fd.FolderName;
        FsOp(svc, "Скачивание…", () => DownloadEntries(svc, sel, dir),
            $"Скачано: {sel.Count} → {dir}", relist: false);
    }

    /// <summary>Фоновый поток: файлы и папки (рекурсивно) в локальную папку.</summary>
    private void DownloadEntries(Files.FileService svc, List<Files.RemoteEntry> entries, string localDir)
    {
        int i = 0;
        foreach (var en in entries)
        {
            i++;
            var n = i;
            var remote = Files.RemotePath.Join(svc.CurrentPath, en.Name);
            var local = Path.Combine(localDir, en.Name);
            RunOnUi(() => FsStatus.Text = $"Скачивание {n}/{entries.Count}: {en.Name}");
            if (en.IsDir) svc.DownloadDirL(remote, local, st => RunOnUi(() => FsStatus.Text = st));
            else File.WriteAllBytes(local, svc.DownloadL(remote));
        }
    }

    private void FsUpload_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc || _fsBusy) return;
        var dlg = new OpenFileDialog { Multiselect = true, Title = "Залить в " + svc.CurrentPath };
        if (dlg.ShowDialog(this) != true) return;
        UploadPaths(svc, dlg.FileNames, svc.CurrentPath);
    }

    private void FsUploadDir()
    {
        if (ActiveFs is not { } svc || _fsBusy) return;
        var dlg = new OpenFolderDialog { Title = "Какую папку залить в " + svc.CurrentPath };
        if (dlg.ShowDialog(this) != true) return;
        UploadPaths(svc, new[] { dlg.FolderName }, svc.CurrentPath);
    }

    /// <summary>Локальные файлы/папки → targetDir на ноде (диалог и перетаскивание).</summary>
    private void UploadPaths(Files.FileService svc, IReadOnlyList<string> paths, string targetDir)
    {
        FsOp(svc, "Заливка…", () =>
        {
            int i = 0;
            foreach (var p in paths)
            {
                i++;
                var n = i;
                var name = Path.GetFileName(p.TrimEnd('\\', '/'));
                var remote = Files.RemotePath.Join(targetDir, name);
                RunOnUi(() => FsStatus.Text = $"Заливка {n}/{paths.Count}: {name}");
                if (Directory.Exists(p)) svc.UploadDirL(p, remote, st => RunOnUi(() => FsStatus.Text = st));
                else svc.UploadL(remote, File.ReadAllBytes(p));
            }
        }, paths.Count == 1 ? $"Залито: {Path.GetFileName(paths[0].TrimEnd('\\', '/'))}" : $"Залито: {paths.Count}");
    }

    private void FsMkdir_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc || _fsBusy) return;
        var name = InputDialog.Ask(this, "Имя новой папки:");
        if (string.IsNullOrWhiteSpace(name)) return;
        var remote = Files.RemotePath.Join(svc.CurrentPath, name.Trim());
        FsOp(svc, "Создание папки…", () => svc.MkdirL(remote), $"Создана папка {name.Trim()}");
    }

    private void FsNewFile_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc || _fsBusy) return;
        var name = InputDialog.Ask(this, "Имя нового файла:");
        if (string.IsNullOrWhiteSpace(name)) return;
        name = name.Trim();
        if (svc.Entries.Any(x => x.Name == name))
        {
            FsStatus.Text = $"«{name}» уже есть";
            return;
        }
        var remote = Files.RemotePath.Join(svc.CurrentPath, name);
        FsBusy(true);
        FsStatus.Text = "Создание файла…";
        Task.Run(() =>
        {
            try
            {
                svc.UploadL(remote, Array.Empty<byte>());
                var entries = svc.ListL(svc.CurrentPath);
                RunOnUi(() =>
                {
                    svc.Entries = entries;
                    FsBusy(false);
                    RenderFiles();
                    FsStatus.Text = $"Создан {name}";
                    _ = OpenEmptyAsync(svc, remote);
                });
            }
            catch (Exception ex)
            {
                RunOnUi(() => { FsBusy(false); FsStatus.Text = "Ошибка: " + ex.Message; });
            }
        });
    }

    private async Task OpenEmptyAsync(Files.FileService svc, string remote)
    {
        try { await _editor.OpenAsync(svc, remote, Array.Empty<byte>(), NodeName()); }
        catch (Exception ex) { FsStatus.Text = "Редактор: " + ex.Message; }
    }

    private void FsDelete_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc || _fsBusy) return;
        var sel = SelectedEntries();
        if (sel.Count == 0) return;
        var what = sel.Count == 1
            ? $"{(sel[0].IsDir ? "папку" : "файл")} «{sel[0].Name}»{(sel[0].IsDir ? " со всем содержимым" : "")}"
            : $"{sel.Count} объектов:\n" + string.Join("\n", sel.Take(12).Select(x => "  " + x.Name + (x.IsDir ? "/" : ""))) +
              (sel.Count > 12 ? "\n  …" : "");
        if (MessageBox.Show(this, $"Удалить {what}?", "QTerm", MessageBoxButton.YesNo,
                MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        FsOp(svc, "Удаление…", () =>
        {
            foreach (var en in sel) svc.DeleteL(Files.RemotePath.Join(svc.CurrentPath, en.Name), en.IsDir);
        }, $"Удалено: {sel.Count}");
    }

    private void FsRename()
    {
        if (ActiveFs is not { } svc || _fsBusy || SelectedEntries() is not { Count: 1 } sel) return;
        var en = sel[0];
        var name = InputDialog.Ask(this, "Новое имя:", en.Name);
        if (string.IsNullOrWhiteSpace(name) || name == en.Name) return;
        var from = Remote(svc, en);
        var to = Files.RemotePath.Join(svc.CurrentPath, name.Trim());
        FsOp(svc, "Переименование…", () => svc.RenameL(from, to), $"{en.Name} → {name.Trim()}");
    }

    /// <summary>rwxr-xr-x → 755 (s/t — с исполнением).</summary>
    private static string PermsToOctal(string perms, bool isDir)
    {
        if (perms.Length < 9) return isDir ? "755" : "644";
        int Grp(int o) => (perms[o] == 'r' ? 4 : 0) + (perms[o + 1] == 'w' ? 2 : 0) +
                          (perms[o + 2] is 'x' or 's' or 't' ? 1 : 0);
        return $"{Grp(0)}{Grp(3)}{Grp(6)}";
    }

    private void FsChmod_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc || _fsBusy) return;
        var sel = SelectedEntries();
        if (sel.Count == 0) { FsStatus.Text = "Выдели файлы для смены прав"; return; }
        var label = sel.Count == 1 ? $"Права для «{sel[0].Name}» (октально):" : $"Права для {sel.Count} объектов (октально):";
        var mode = InputDialog.Ask(this, label, PermsToOctal(sel[0].Perms, sel[0].IsDir));
        if (mode is null) return;
        mode = mode.Trim();
        if (!Regex.IsMatch(mode, "^[0-7]{3,4}$"))
        {
            FsStatus.Text = "Права — 3-4 октальные цифры (например 644)";
            return;
        }
        FsOp(svc, "chmod…", () =>
        {
            foreach (var en in sel) svc.ChmodL(Files.RemotePath.Join(svc.CurrentPath, en.Name), mode);
        }, $"chmod {mode}: {sel.Count}");
    }

    private void FsProps()
    {
        if (ActiveFs is not { } svc || _fsBusy || SelectedEntries() is not { Count: 1 } sel) return;
        var d = new FilePropsDialog(svc, sel[0], Remote(svc, sel[0])) { Owner = this };
        d.ShowDialog();
        if (d.Changed) FsNavigate(svc.CurrentPath); // перечитать права
    }

    // ── Пути и терминал ──

    private static string ShellQuote(string p) =>
        Regex.IsMatch(p, @"^[A-Za-z0-9_./@%+=:,\-]+$") ? p : Files.RemotePath.Q(p);

    private void WriteToFilesTerm(string text)
    {
        if (_filesTab is not { } id) return;
        SshSessionController? c;
        lock (_controllers) _controllers.TryGetValue(id, out c);
        c?.Write(System.Text.Encoding.UTF8.GetBytes(text));
    }

    private List<string> SelectedPaths()
    {
        if (ActiveFs is not { } svc) return new();
        var sel = SelectedEntries();
        return sel.Count > 0 ? sel.Select(en => Remote(svc, en)).ToList() : new List<string> { svc.CurrentPath };
    }

    private void CopyPaths()
    {
        var paths = SelectedPaths();
        if (paths.Count == 0) return;
        try
        {
            Clipboard.SetText(string.Join(Environment.NewLine, paths));
            FsStatus.Text = paths.Count == 1 ? $"Скопировано: {paths[0]}" : $"Скопировано путей: {paths.Count}";
        }
        catch (Exception ex) { FsStatus.Text = "Буфер занят: " + ex.Message; }
    }

    private void PathsToTerminal(IEnumerable<string> paths) =>
        WriteToFilesTerm(string.Join(" ", paths.Select(ShellQuote)) + " ");

    private void FsCdHere_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc) return;
        var target = SelectedEntries() is { Count: 1 } s && s[0].IsDir ? Remote(svc, s[0]) : svc.CurrentPath;
        WriteToFilesTerm("cd " + ShellQuote(target) + "\n");
        FsStatus.Text = "Терминал: cd " + target;
    }

    private void FsSetStart_Click(object sender, RoutedEventArgs e)
    {
        if (ActiveFs is not { } svc || _filesTab is not { } id) return;
        SshSessionController? c;
        lock (_controllers) _controllers.TryGetValue(id, out c);
        if (c is null) return;
        var s = _repo.Data.Sessions.FirstOrDefault(x => x.Id == c.SessionRef.Id);
        if (s is null) return;
        s.Extra["sftpPath"] = svc.CurrentPath;
        s.UpdatedAt = QtJson.NowIso();
        _repo.Persist();
        FsStatus.Text = $"Стартовая папка ноды: {svc.CurrentPath}";
    }

    // ── Скрытые / следовать за терминалом ──

    private void PaintHiddenBtn()
    {
        if (_fsShowHidden) FsHiddenBtn.SetResourceReference(BackgroundProperty, "SelBrush");
        else FsHiddenBtn.ClearValue(BackgroundProperty);
        FsHiddenBtn.ToolTip = _fsShowHidden ? "Скрытые файлы (.dot) показаны — спрятать" : "Скрытые файлы (.dot) спрятаны — показать";
    }

    private void FsHidden_Click(object sender, RoutedEventArgs e)
    {
        _fsShowHidden = !_fsShowHidden;
        var st = Security.AppSettings.Load();
        st.FsShowHidden = _fsShowHidden;
        st.Save();
        PaintHiddenBtn();
        RenderFiles();
    }

    private void FsFollow_Click(object sender, RoutedEventArgs e)
    {
        _fsFollow = FsFollowBox.IsChecked == true;
        var st = Security.AppSettings.Load();
        st.FsFollowTerminal = _fsFollow;
        st.Save();
        FsStatus.Text = _fsFollow
            ? "Панель идёт за cd в терминале (нужен заголовок «user@host: путь» или OSC 7)"
            : "Не следовать за терминалом";
    }

    private static readonly Regex TitleCwd = new(@"^[^@\s:]+@[^:\s]+\s*:\s*(.+?)\s*$", RegexOptions.Compiled);

    /// <summary>Шелл сообщил папку (заголовок окна или OSC 7) — панель идёт следом.</summary>
    private void OnTermCwd(Guid tabId, string raw, bool osc7)
    {
        if (!_fsFollow || tabId != _filesTab || ActiveFs is not { } svc || _fsBusy) return;
        string? path = null;
        if (osc7)
        {
            if (Uri.TryCreate(raw, UriKind.Absolute, out var u) && u.Scheme == "file")
                path = Uri.UnescapeDataString(u.AbsolutePath);
        }
        else if (TitleCwd.Match(raw) is { Success: true } m)
        {
            path = m.Groups[1].Value;
            if (path == "~") path = svc.HomeDir;
            else if (path.StartsWith("~/", StringComparison.Ordinal)) path = svc.HomeDir.TrimEnd('/') + path[1..];
        }
        if (path is null || !path.StartsWith('/')) return;
        if (path.Length > 1) path = path.TrimEnd('/');
        if (path == svc.CurrentPath) return;
        FsNavigate(path);
    }

    // ── Клавиатура и мышь ──

    private void FsList_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var m = Keyboard.Modifiers;
        switch (e.Key)
        {
            case Key.Enter when m == ModifierKeys.None:
                if (FsList.SelectedItem is FsRow row) OpenRow(row);
                break;
            case Key.Back when m == ModifierKeys.None:
                FsUp_Click(this, e);
                break;
            case Key.Delete when m == ModifierKeys.None:
                FsDelete_Click(this, e);
                break;
            case Key.F2 when m == ModifierKeys.None:
                FsRename();
                break;
            case Key.F5 when m == ModifierKeys.None:
                FsRefresh_Click(this, e);
                break;
            case Key.C when m == ModifierKeys.Control:
                CopyPaths();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    private Point _fsDragStart;
    private bool _fsDragArmed;
    private bool _fsDraggingOut;

    private void FsList_PreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        var row = RowAt(e.OriginalSource);
        if (e.ChangedButton == MouseButton.Middle)
        {
            // Моба: средняя кнопка — путь в терминал
            if (row?.Entry is { } en && ActiveFs is { } svc)
            {
                PathsToTerminal(new[] { Remote(svc, en) });
                e.Handled = true;
            }
            return;
        }
        if (e.ChangedButton == MouseButton.Left)
        {
            _fsDragStart = e.GetPosition(FsList);
            _fsDragArmed = row?.Entry is not null;
        }
        else if (e.ChangedButton == MouseButton.Right && row is not null && !FsList.SelectedItems.Contains(row))
        {
            FsList.SelectedItem = row; // ПКМ по невыделенной строке — выделить её
        }
    }

    /// <summary>Перетаскивание из панели в проводник: скачиваем во временную папку и отдаём как файлы.</summary>
    private void FsList_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (!_fsDragArmed || e.LeftButton != MouseButtonState.Pressed || _fsBusy) return;
        var d = e.GetPosition(FsList) - _fsDragStart;
        if (Math.Abs(d.X) < SystemParameters.MinimumHorizontalDragDistance * 2 &&
            Math.Abs(d.Y) < SystemParameters.MinimumVerticalDragDistance * 2) return;
        _fsDragArmed = false;
        if (ActiveFs is not { } svc) return;
        var sel = SelectedEntries();
        if (sel.Count == 0) return;
        var total = sel.Where(x => !x.IsDir).Sum(x => x.Size);
        if (total > 200L * 1024 * 1024)
        {
            FsStatus.Text = "Больше 200 МБ — перетаскиванием не тащим, есть «Скачать»";
            return;
        }
        var tmp = Path.Combine(Path.GetTempPath(), "QTerm", "drag", Guid.NewGuid().ToString("N")[..8]);
        try
        {
            Directory.CreateDirectory(tmp);
            Mouse.OverrideCursor = Cursors.Wait;
            FsStatus.Text = "Готовлю файлы для перетаскивания…";
            foreach (var en in sel)
            {
                var remote = Remote(svc, en);
                var local = Path.Combine(tmp, en.Name);
                if (en.IsDir) svc.DownloadDirL(remote, local, _ => { });
                else File.WriteAllBytes(local, svc.DownloadL(remote));
            }
        }
        catch (Exception ex)
        {
            FsStatus.Text = "Перетаскивание: " + ex.Message;
            return;
        }
        finally { Mouse.OverrideCursor = null; }

        var paths = sel.Select(en => Path.Combine(tmp, en.Name)).ToArray();
        FsStatus.Text = "Отпусти в папке проводника";
        _fsDraggingOut = true;
        try { DragDrop.DoDragDrop(FsList, new DataObject(DataFormats.FileDrop, paths), DragDropEffects.Copy); }
        finally { _fsDraggingOut = false; }
        FsStatus.Text = $"Перетащено: {paths.Length}";
    }

    private void FsList_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = !_fsDraggingOut && ActiveFs is not null && !_fsBusy &&
                    e.Data.GetDataPresent(DataFormats.FileDrop)
            ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    /// <summary>Файлы/папки из проводника → в текущую папку (или в папку под курсором).</summary>
    private void FsList_Drop(object sender, DragEventArgs e)
    {
        if (_fsDraggingOut || ActiveFs is not { } svc || _fsBusy) return;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] { Length: > 0 } paths) return;
        var target = RowAt(e.OriginalSource)?.Entry is { IsDir: true } dir ? Remote(svc, dir) : svc.CurrentPath;
        UploadPaths(svc, paths, target);
        e.Handled = true;
    }

    // ── Контекстное меню (порядок мобы) ──

    private static MenuItem FsMi(string header, string? glyph, Brush? brush, Action act, string gesture = "", bool enabled = true)
    {
        var mi = new MenuItem { Header = header, InputGestureText = gesture, IsEnabled = enabled };
        if (glyph is not null)
            mi.Icon = new TextBlock
            {
                Text = glyph, FontSize = 14, Foreground = brush ?? IcGray,
                FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
            };
        mi.Click += (s, e) => act();
        return mi;
    }

    private void FsList_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (ActiveFs is not { } svc || _fsBusy) { e.Handled = true; return; }
        var menu = FsList.ContextMenu!;
        menu.Items.Clear();

        // клик по пустому месту — меню папки
        if (RowAt(e.OriginalSource) is null) FsList.SelectedItems.Clear();
        var sel = SelectedEntries();
        var one = sel.Count == 1 ? sel[0] : null;
        var files = sel.Where(x => !x.IsDir).ToList();

        if (sel.Count > 0)
        {
            menu.Items.Add(FsMi(one is { IsDir: true } ? "Открыть папку" : "Открыть", "", IcFolder,
                () =>
                {
                    if (one is not null && FsList.SelectedItem is FsRow r) OpenRow(r);
                    else _ = OpenManyAsync(svc, files); // несколько файлов — все в QEditor
                }, "Enter", sel.Count == 1 || files.Count > 0));
            if (files.Count > 0)
            {
                var ext = Security.AppSettings.Load().ExternalEditor;
                menu.Items.Add(FsMi("Открыть во внешнем редакторе", "", IcBlue,
                    () => { foreach (var f in files) OpenExternal(svc, f, string.IsNullOrWhiteSpace(ext) ? null : ext); }));
                menu.Items.Add(FsMi("Открыть с помощью…", "", IcBlue,
                    () => { if (one is not null) OpenWithPicked(svc, one); }, "", one is { IsDir: false }));
                menu.Items.Add(FsMi("Открыть программой по умолчанию", "", IcBlue,
                    () => { foreach (var f in files) OpenExternal(svc, f, null); }));
                menu.Items.Add(FsMi(files.Count == 2 ? "Сравнить эти два файла" : "Сравнить с…", "", IcPurple,
                    () => _ = CompareSelectedAsync(), "", files.Count is 1 or 2 && files.Count == sel.Count));
            }
            menu.Items.Add(new Separator());
            menu.Items.Add(FsMi(sel.Count == 1 ? "Скачать" : $"Скачать ({sel.Count})", "", IcBlue,
                () => FsDownload_Click(this, new RoutedEventArgs())));
            menu.Items.Add(new Separator());
            menu.Items.Add(FsMi(sel.Count == 1 ? "Удалить" : $"Удалить ({sel.Count})", "", Fz("#E5534B"),
                () => FsDelete_Click(this, new RoutedEventArgs()), "Del"));
            menu.Items.Add(FsMi("Переименовать", "", IcGray, FsRename, "F2", one is not null));
            menu.Items.Add(new Separator());
            menu.Items.Add(FsMi(sel.Count == 1 ? "Копировать путь" : "Копировать пути", "", IcGray, CopyPaths, "Ctrl+C"));
            menu.Items.Add(FsMi("Путь в терминал", "", IcGreen,
                () => PathsToTerminal(sel.Select(x => Remote(svc, x))), "Средняя кнопка"));
            if (one is { IsDir: true })
                menu.Items.Add(FsMi("Перейти в терминале (cd)", "", IcGreen,
                    () => FsCdHere_Click(this, new RoutedEventArgs())));
            menu.Items.Add(new Separator());
            menu.Items.Add(FsMi("Свойства…", "", IcBlue, FsProps, "", one is not null));
            menu.Items.Add(FsMi("Права (chmod)…", "", IcFolder, () => FsChmod_Click(this, new RoutedEventArgs())));
            menu.Items.Add(new Separator());
        }

        // Действия с текущей папкой
        menu.Items.Add(FsMi("Обновить", "", IcGreen, () => FsRefresh_Click(this, new RoutedEventArgs()), "F5"));
        menu.Items.Add(FsMi("Новая папка…", "", IcFolder, () => FsMkdir_Click(this, new RoutedEventArgs())));
        menu.Items.Add(FsMi("Новый файл…", "", IcGray, () => FsNewFile_Click(this, new RoutedEventArgs())));
        menu.Items.Add(FsMi("Залить файлы сюда…", "", IcGreen, () => FsUpload_Click(this, new RoutedEventArgs())));
        menu.Items.Add(FsMi("Залить папку сюда…", "", IcGreen, FsUploadDir));
        if (sel.Count == 0)
        {
            menu.Items.Add(new Separator());
            menu.Items.Add(FsMi("Копировать путь папки", "", IcGray, CopyPaths));
            menu.Items.Add(FsMi("Перейти в терминале (cd)", "", IcGreen, () => FsCdHere_Click(this, new RoutedEventArgs())));
            menu.Items.Add(FsMi("Сделать стартовой папкой ноды", "", IcOrange, () => FsSetStart_Click(this, new RoutedEventArgs())));
        }
    }
}
