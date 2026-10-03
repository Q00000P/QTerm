using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using DiffPlex;
using DiffPlex.DiffBuilder;
using DiffPlex.DiffBuilder.Model;
using ICSharpCode.AvalonEdit.Document;
using QTermShared;

namespace QEditor;

/// <summary>
/// QEditor — отдельное приложение (мак-канон QTermEditor.app) уровня
/// MobaTextEditor: строка меню, тулбар, вкладки, нумерация строк, подсветка,
/// поиск/замена, закладки, кодировки, концы строк, сравнение, печать.
/// </summary>
public partial class EditorHostWindow : Window
{
    // ── Модель вкладки ──
    public sealed class TabVM : INotifyPropertyChanged
    {
        public Guid Id { get; } = Guid.NewGuid();
        public string Glyph { get; init; } = "";
        private string _name = "", _tip = "";
        private bool _active, _dirty;
        public string Name { get => _name; set { _name = value; N(); } }
        public string Tip { get => _tip; set { _tip = value; N(); } }
        public bool IsActive { get => _active; set { _active = value; N(nameof(TabBrush)); N(nameof(TabBorder)); N(nameof(NameBrush)); } }
        public bool Dirty { get => _dirty; set { _dirty = value; N(nameof(DirtyVis)); } }
        public Visibility DirtyVis => Dirty ? Visibility.Visible : Visibility.Collapsed;
        public Brush TabBrush => ThemeManager.Brush(IsActive ? "TabActiveBrush" : "TabIdleBrush");
        public Brush TabBorder => ThemeManager.Brush(IsActive ? "TabActiveEdge" : "TabIdleEdge");
        public Brush NameBrush => ThemeManager.Brush(IsActive ? "FgBrush" : "DimBrush");
        public void ThemeChanged() { N(nameof(TabBrush)); N(nameof(TabBorder)); N(nameof(NameBrush)); }
        public event PropertyChangedEventHandler? PropertyChanged;
        private void N([CallerMemberName] string? p = null) => PropertyChanged?.Invoke(this, new(p));
    }

    private static readonly FontFamily IconFont = new("Segoe Fluent Icons, Segoe MDL2 Assets, Segoe UI Symbol");
    private static readonly FontFamily SymFont = new("Segoe UI Symbol, Segoe UI");

    private readonly HostLink _link;
    private readonly ObservableCollection<TabVM> _tabs = new();
    private readonly Dictionary<Guid, EditorPane> _panes = new();
    private readonly DispatcherTimer _findTimer;
    private readonly List<(Button Btn, Func<bool>? Enabled, Func<bool>? Checked)> _toolButtons = new();
    private int _untitled;
    private bool _hostConnected;

    private EditorPane? Active =>
        _tabs.FirstOrDefault(t => t.IsActive) is { } vm && _panes.TryGetValue(vm.Id, out var p) ? p : null;
    private TabVM? ActiveVm => _tabs.FirstOrDefault(t => t.IsActive);

    public EditorHostWindow(HostLink link)
    {
        InitializeComponent();
        _link = link;
        var st = EditorSettings.Current;
        Width = Math.Max(MinWidth, st.Width);
        Height = Math.Max(MinHeight, st.Height);
        TabStrip.ItemsSource = _tabs;

        _findTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(160) };
        _findTimer.Tick += (_, _) => { _findTimer.Stop(); RefreshMatches(); };

        BuildMenu();
        BuildToolbar();
        ApplyChromeVisibility();

        _link.Open += OpenRemote;
        _link.NewDoc += () => { NewLocalDocument(); BringToFront(); };
        _link.Activate += BringToFront;
        _link.OpenLocal += p => { OpenLocalFile(p); BringToFront(); };
        _link.Compare += CompareFromHost;
        _link.HostChanged += c => { _hostConnected = c; UpdateStatus(); };
        ThemeManager.Changed += () => Dispatcher.Invoke(OnThemeChanged);

        PreviewKeyDown += OnPreviewKeyDown;
        FindBox.KeyDown += FindBox_KeyDown;
        ReplaceBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Replace(); e.Handled = true; } };
        Drop += OnDrop;
        Closing += OnClosing;
        UpdateAll();
    }

    // ══════════════════════ Вкладки ══════════════════════

    private void AddPane(EditorPane pane, string title, string tip, string glyph)
    {
        var vm = new TabVM { Name = title, Tip = tip, Glyph = glyph };
        pane.StateChanged += () => Dispatcher.Invoke(() =>
        {
            vm.Dirty = pane.Dirty;
            if (pane.IsLocal && !pane.IsReadOnlyView) { vm.Name = pane.FileName; vm.Tip = pane.Location; }
            if (vm.IsActive) UpdateAll();
        });
        var ta = pane.Editor.TextArea;
        ta.Caret.PositionChanged += (_, _) => { if (vm.IsActive) UpdateStatus(); };
        ta.SelectionChanged += (_, _) => { if (vm.IsActive) UpdateStatus(); };
        pane.Editor.Document.TextChanged += (_, _) =>
        {
            if (vm.IsActive && FindBar.Visibility == Visibility.Visible) { _findTimer.Stop(); _findTimer.Start(); }
        };
        pane.Editor.ContextMenu = BuildContextMenu();
        _panes[vm.Id] = pane;
        PaneHost.Children.Add(pane);
        _tabs.Add(vm);
        ActivateTab(vm.Id);
    }

    private void ActivateTab(Guid id)
    {
        foreach (var t in _tabs) t.IsActive = t.Id == id;
        foreach (var kv in _panes)
            kv.Value.Visibility = kv.Key == id ? Visibility.Visible : Visibility.Collapsed;
        if (_panes.TryGetValue(id, out var p))
        {
            Dispatcher.InvokeAsync(p.FocusEditor, DispatcherPriority.Input);
            if (FindBar.Visibility == Visibility.Visible) RefreshMatches();
        }
        UpdateAll();
    }

    private bool CloseTab(Guid id)
    {
        if (!_panes.TryGetValue(id, out var pane)) return true;
        if (!pane.TryClose()) return false;
        PaneHost.Children.Remove(pane);
        _panes.Remove(id);
        if (pane.DocId is { } doc) _link.NotifyClosed(doc); // QTerm забудет маршрут
        var idx = _tabs.ToList().FindIndex(t => t.Id == id);
        var wasActive = _tabs[idx].IsActive;
        _tabs.RemoveAt(idx);
        if (wasActive && _tabs.Count > 0) ActivateTab(_tabs[Math.Min(idx, _tabs.Count - 1)].Id);
        UpdateAll();
        return true;
    }

    private void CloseAll(Guid? except = null)
    {
        foreach (var t in _tabs.ToList())
            if (t.Id != except && !CloseTab(t.Id)) return;
    }

    private void CycleTab(int dir)
    {
        if (_tabs.Count < 2 || ActiveVm is not { } a) return;
        var i = _tabs.IndexOf(a);
        ActivateTab(_tabs[(i + dir + _tabs.Count) % _tabs.Count].Id);
    }

    private void Tab_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not Guid id) return;
        if (e.ChangedButton == MouseButton.Middle) { CloseTab(id); e.Handled = true; }
        else if (e.ChangedButton == MouseButton.Left) ActivateTab(id);
    }

    private void TabClose_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if ((sender as FrameworkElement)?.Tag is Guid id) CloseTab(id);
    }

    private void Tab_RightUp(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not Guid id || !_panes.TryGetValue(id, out var p)) return;
        ActivateTab(id);
        var m = new ContextMenu();
        m.Items.Add(Mi("Сохранить", () => _ = SaveActive(), "Ctrl+S", "", () => !p.IsReadOnlyView));
        m.Items.Add(Mi("Сохранить как…", () => p.SaveAs(), "Ctrl+Shift+S", ""));
        m.Items.Add(Mi("Перечитать", () => _ = p.ReloadAsync(), "F5", "", () => !p.IsReadOnlyView));
        m.Items.Add(new Separator());
        m.Items.Add(Mi("Копировать путь", () => SafeCopy(p.IsLocal ? p.LocalPath ?? "" : p.RemotePath)));
        m.Items.Add(new Separator());
        m.Items.Add(Mi("Закрыть", () => CloseTab(id), "Ctrl+W", ""));
        m.Items.Add(Mi("Закрыть остальные", () => CloseAll(id)));
        m.Items.Add(Mi("Закрыть все", () => CloseAll()));
        RefreshStates(m.Items);
        m.PlacementTarget = sender as UIElement;
        m.IsOpen = true;
        e.Handled = true;
    }

    // ══════════════════════ Открытие ══════════════════════

    /// <summary>Файл ноды от QTerm: каждое открытие — новая вкладка
    /// (одинаковые пути разных нод — разные файлы), нода в имени вкладки.</summary>
    private void OpenRemote(EditorMsg m)
    {
        if (m.Doc is null || m.Path is null) return;
        byte[] data;
        try { data = m.Data is not null ? Convert.FromBase64String(m.Data) : System.Text.Encoding.UTF8.GetBytes(m.Text ?? ""); }
        catch { data = Array.Empty<byte>(); }
        var doc = m.Doc;
        var node = m.Node ?? "?";
        var pane = EditorPane.Remote(doc, node, m.Path, data,
            bytes => _link.SaveAsync(doc, bytes), () => _link.ReloadAsync(doc));
        AddPane(pane, $"{pane.FileName} — {node}", $"{node}: {m.Path}", "");
        BringToFront();
    }

    public void NewLocalDocument()
    {
        var name = $"Без имени {++_untitled}";
        AddPane(EditorPane.Local(null, Array.Empty<byte>(), name), name, "локальный — Ctrl+S запишет на диск", "");
    }

    public void OpenFromDisk()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog
        {
            Title = "Открыть", Multiselect = true,
            Filter = "Все файлы (*.*)|*.*|Текст и конфиги|*.txt;*.sh;*.conf;*.json;*.yaml;*.yml;*.ini;*.md;*.log;*.xml;*.py;*.ps1",
        };
        if (dlg.ShowDialog(this) != true) return;
        foreach (var f in dlg.FileNames) OpenLocalFile(f);
    }

    public void OpenLocalFile(string path)
    {
        var existing = _panes.FirstOrDefault(kv => string.Equals(kv.Value.LocalPath, path, StringComparison.OrdinalIgnoreCase));
        if (existing.Value is not null) { ActivateTab(existing.Key); return; }
        byte[] data;
        try
        {
            var len = new FileInfo(path).Length;
            if (len > 50L * 1024 * 1024 &&
                MessageBox.Show(this, $"Файл {len / 1048576} МБ. Открыть всё равно?", "QEditor",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
            data = File.ReadAllBytes(path);
        }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "QEditor"); return; }
        var pane = EditorPane.Local(path, data, Path.GetFileName(path));
        AddPane(pane, pane.FileName, path, "");
        EditorSettings.AddRecent(path);
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
            foreach (var f in files.Where(File.Exists)) OpenLocalFile(f);
    }

    public void BringToFront()
    {
        if (!IsVisible) Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        Topmost = true;   // Activate из фона Windows иногда только мигает кнопкой
        Topmost = false;
        Focus();
    }

    // ══════════════════════ Сохранение / печать ══════════════════════

    private async Task SaveActive()
    {
        if (Active is { } p) await p.SaveAsync();
    }

    private async Task SaveAll()
    {
        foreach (var p in _panes.Values.Where(p => p.Dirty && !p.IsReadOnlyView).ToList())
            await p.SaveAsync();
    }

    private void Print()
    {
        if (Active is not { } p) return;
        var dlg = new PrintDialog();
        if (dlg.ShowDialog() != true) return;
        var fd = new FlowDocument(new Paragraph(new Run(p.Editor.Document.Text)))
        {
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 10,
            Foreground = Brushes.Black,
            Background = Brushes.White,
            PagePadding = new Thickness(48),
            ColumnWidth = double.PositiveInfinity,
            PageWidth = dlg.PrintableAreaWidth,
            PageHeight = dlg.PrintableAreaHeight,
        };
        dlg.PrintDocument(((IDocumentPaginatorSource)fd).DocumentPaginator, "QEditor — " + p.FileName);
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        foreach (var t in _tabs.ToList())
            if (!CloseTab(t.Id)) { e.Cancel = true; return; }
        if (WindowState == WindowState.Normal)
        {
            EditorSettings.Current.Width = ActualWidth;
            EditorSettings.Current.Height = ActualHeight;
        }
        EditorSettings.Save();
    }

    // ══════════════════════ Меню ══════════════════════

    private sealed record MState(Func<bool>? Enabled, Func<bool>? Checked);

    private MenuItem Mi(string header, Action act, string? key = null, string? glyph = null,
        Func<bool>? enabled = null, Func<bool>? isChecked = null)
    {
        var m = new MenuItem { Header = header, InputGestureText = key ?? "" };
        if (glyph is not null)
        {
            var icon = new TextBlock
            {
                Text = glyph, FontSize = 13,
                FontFamily = glyph.Length == 1 && glyph[0] >= '' ? IconFont : SymFont,
            };
            icon.SetResourceReference(TextBlock.ForegroundProperty, "DimBrush"); // следует за темой
            m.Icon = icon;
        }
        m.Tag = new MState(enabled, isChecked);
        m.Click += (_, e) => { e.Handled = true; act(); };
        return m;
    }

    /// <summary>Подменю, содержимое строится при открытии (закладки, недавние, вкладки…).</summary>
    private MenuItem Sub(string header, Action<ItemCollection> fill, string? glyph = null)
    {
        var m = Mi(header, () => { }, null, glyph);
        m.Items.Add(new MenuItem { Header = "…" }); // чтобы была стрелка подменю
        m.SubmenuOpened += (_, e) =>
        {
            if (!ReferenceEquals(e.OriginalSource, m)) return;
            m.Items.Clear();
            fill(m.Items);
            if (m.Items.Count == 0) m.Items.Add(new MenuItem { Header = "(пусто)", IsEnabled = false });
            RefreshStates(m.Items);
        };
        return m;
    }

    /// <summary>«_» в заголовке пункта — это клавиша доступа WPF; в путях/строках удваиваем.</summary>
    private static string AccessSafe(string s) => s.Replace("_", "__");

    private static void RefreshStates(ItemCollection items)
    {
        foreach (var o in items)
        {
            if (o is not MenuItem mi) continue;
            if (mi.Tag is MState st)
            {
                mi.IsEnabled = st.Enabled?.Invoke() ?? true;
                mi.IsChecked = st.Checked?.Invoke() ?? false;
            }
        }
    }

    private bool HasPane => Active is not null;
    private bool Editable => Active is { IsReadOnlyView: false };

    private void BuildMenu()
    {
        var file = new MenuItem { Header = "_Файл" };
        file.Items.Add(Mi("Новый", NewLocalDocument, "Ctrl+N", ""));
        file.Items.Add(Mi("Открыть…", OpenFromDisk, "Ctrl+O", ""));
        file.Items.Add(Sub("Недавние", items =>
        {
            foreach (var r in EditorSettings.Current.Recent.Where(File.Exists))
                items.Add(Mi(AccessSafe(r), () => OpenLocalFile(r)));
        }));
        file.Items.Add(Mi("Перечитать", () => _ = Active?.ReloadAsync(), "F5", "", () => Editable));
        file.Items.Add(new Separator());
        file.Items.Add(Mi("Сохранить", () => _ = SaveActive(), "Ctrl+S", "", () => Editable));
        file.Items.Add(Mi("Сохранить как…", () => Active?.SaveAs(), "Ctrl+Shift+S", "", () => HasPane));
        file.Items.Add(Mi("Сохранить все", () => _ = SaveAll(), "Ctrl+Alt+S", null, () => _panes.Values.Any(p => p.Dirty)));
        file.Items.Add(new Separator());
        file.Items.Add(Mi("Печать…", Print, "Ctrl+P", "", () => HasPane));
        file.Items.Add(new Separator());
        file.Items.Add(Mi("Закрыть вкладку", () => { if (ActiveVm is { } v) CloseTab(v.Id); }, "Ctrl+W", "", () => HasPane));
        file.Items.Add(Mi("Закрыть остальные", () => CloseAll(ActiveVm?.Id), null, null, () => _tabs.Count > 1));
        file.Items.Add(Mi("Закрыть все", () => CloseAll(), null, null, () => _tabs.Count > 0));
        file.Items.Add(new Separator());
        file.Items.Add(Mi("Выход", Close, "Alt+F4"));

        var edit = new MenuItem { Header = "_Правка" };
        edit.Items.Add(Mi("Отменить", () => Active?.Editor.Undo(), "Ctrl+Z", "", () => Active?.Editor.CanUndo == true));
        edit.Items.Add(Mi("Повторить", () => Active?.Editor.Redo(), "Ctrl+Y", "", () => Active?.Editor.CanRedo == true));
        edit.Items.Add(new Separator());
        edit.Items.Add(Mi("Вырезать", () => Active?.Editor.Cut(), "Ctrl+X", "", () => Editable));
        edit.Items.Add(Mi("Копировать", () => Active?.Editor.Copy(), "Ctrl+C", "", () => HasPane));
        edit.Items.Add(Mi("Вставить", () => Active?.Editor.Paste(), "Ctrl+V", "", () => Editable && Clipboard.ContainsText()));
        edit.Items.Add(Mi("Удалить", () => Active?.Editor.Delete(), "Del", null, () => Editable));
        edit.Items.Add(Mi("Выделить всё", () => Active?.Editor.SelectAll(), "Ctrl+A", null, () => HasPane));
        edit.Items.Add(new Separator());
        edit.Items.Add(Mi("Дублировать строку", () => Active?.DuplicateLines(), "Ctrl+D", null, () => Editable));
        edit.Items.Add(Mi("Удалить строку", () => Active?.DeleteLines(), "Ctrl+Shift+K", null, () => Editable));
        edit.Items.Add(Mi("Строку вверх", () => Active?.MoveLines(true), "Alt+↑", null, () => Editable));
        edit.Items.Add(Mi("Строку вниз", () => Active?.MoveLines(false), "Alt+↓", null, () => Editable));
        edit.Items.Add(new Separator());
        edit.Items.Add(Mi("Сдвинуть вправо", () => Active?.Indent(), "Tab", "⇥", () => Editable));
        edit.Items.Add(Mi("Сдвинуть влево", () => Active?.Unindent(), "Shift+Tab", "⇤", () => Editable));
        edit.Items.Add(Mi("Комментарий вкл/выкл", () => Active?.ToggleComment(), "Ctrl+/", "//", () => Editable));
        edit.Items.Add(CommentSub(true));
        edit.Items.Add(CommentSub(false));
        edit.Items.Add(new Separator());
        var caseSub = Mi("Регистр", () => { }, null, "Aa");
        caseSub.Items.Add(Mi("ВЕРХНИЙ РЕГИСТР", () => Active?.TransformSelection(s => s.ToUpperInvariant(), "Верхний регистр"), "Ctrl+Shift+U"));
        caseSub.Items.Add(Mi("нижний регистр", () => Active?.TransformSelection(s => s.ToLowerInvariant(), "Нижний регистр"), "Ctrl+U"));
        caseSub.Items.Add(Mi("Каждое Слово С Заглавной", () => Active?.TransformSelection(
            s => System.Globalization.CultureInfo.CurrentCulture.TextInfo.ToTitleCase(s.ToLower()), "Заглавные")));
        edit.Items.Add(caseSub);
        edit.Items.Add(Mi("Вставить дату и время", () => Active?.InsertAtCaret(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")), "F7", null, () => Editable));
        edit.Items.Add(Mi("Отменить все правки файла", () => Active?.Revert(), "Ctrl+Alt+Z", null, () => Active?.Dirty == true));

        var search = new MenuItem { Header = "П_оиск" };
        search.Items.Add(Mi("Найти…", () => ShowFind(false), "Ctrl+F", "", () => HasPane));
        search.Items.Add(Mi("Заменить…", () => ShowFind(true), "Ctrl+H", "", () => Editable));
        search.Items.Add(Mi("Найти далее", () => FindNext(false), "F3", null, () => HasPane));
        search.Items.Add(Mi("Найти предыдущее", () => FindNext(true), "Shift+F3", null, () => HasPane));
        search.Items.Add(new Separator());
        search.Items.Add(Mi("Перейти к строке…", GoToLine, "Ctrl+G", "#", () => HasPane));
        search.Items.Add(new Separator());
        search.Items.Add(Mi("Закладка на строке", () => Active?.ToggleBookmark(), "Ctrl+F2", "", () => HasPane));
        search.Items.Add(Mi("Следующая закладка", () => Active?.NextBookmark(false), "F2", "", () => Active?.Marks.Lines.Any() == true));
        search.Items.Add(Mi("Предыдущая закладка", () => Active?.NextBookmark(true), "Shift+F2", "", () => Active?.Marks.Lines.Any() == true));
        search.Items.Add(BookmarksSub());
        search.Items.Add(Mi("Убрать все закладки", () => Active?.Marks.Clear(), null, null, () => Active?.Marks.Lines.Any() == true));

        var view = new MenuItem { Header = "_Вид" };
        var theme = Mi("Тема", () => { }, null, "◐");
        foreach (var (mode, title) in ThemeManager.Modes)
        {
            var md = mode;
            theme.Items.Add(Mi(title, () => SetTheme(md), null, null, null, () => EditorSettings.Current.Theme == md));
        }
        theme.SubmenuOpened += (_, e) => { if (ReferenceEquals(e.OriginalSource, theme)) RefreshStates(theme.Items); };
        view.Items.Add(theme);
        view.Items.Add(new Separator());
        view.Items.Add(Toggle("Номера строк", s => s.LineNumbers, (s, v) => s.LineNumbers = v, null, "#"));
        view.Items.Add(Toggle("Перенос строк", s => s.WordWrap, (s, v) => s.WordWrap = v, "Alt+Z", "↩"));
        view.Items.Add(Toggle("Пробелы и табы", s => s.ShowWhitespace, (s, v) => s.ShowWhitespace = v, null, "·"));
        view.Items.Add(Toggle("Концы строк", s => s.ShowEol, (s, v) => s.ShowEol = v, null, "¶"));
        view.Items.Add(Toggle("Подсветка текущей строки", s => s.HighlightLine, (s, v) => s.HighlightLine = v));
        view.Items.Add(Toggle("Линейка 80 символов", s => s.ColumnRuler, (s, v) => s.ColumnRuler = v));
        view.Items.Add(new Separator());
        view.Items.Add(Mi("Крупнее", () => Active?.Zoom(1), "Ctrl++", "", () => HasPane));
        view.Items.Add(Mi("Мельче", () => Active?.Zoom(-1), "Ctrl+−", "", () => HasPane));
        view.Items.Add(Mi("Обычный размер", () => Active?.Zoom(0), "Ctrl+0", null, () => HasPane));
        view.Items.Add(new Separator());
        view.Items.Add(Toggle("Панель инструментов", s => s.Toolbar, (s, v) => s.Toolbar = v));
        view.Items.Add(Toggle("Строка состояния", s => s.StatusBar, (s, v) => s.StatusBar = v));

        var format = new MenuItem { Header = "Фо_рмат" };
        format.Items.Add(EolSub());
        var indent = Mi("Отступ", () => { }, null, "⇥");
        indent.Items.Add(Mi("Пробелами", () => SetIndent(true, null), null, null, null, () => EditorSettings.Current.UseSpaces));
        indent.Items.Add(Mi("Табами", () => SetIndent(false, null), null, null, null, () => !EditorSettings.Current.UseSpaces));
        indent.Items.Add(new Separator());
        foreach (var n in new[] { 2, 4, 8 })
            indent.Items.Add(Mi($"Ширина {n}", () => SetIndent(null, n), null, null, null, () => EditorSettings.Current.TabSize == n));
        indent.SubmenuOpened += (_, _) => RefreshStates(indent.Items);
        format.Items.Add(indent);
        format.Items.Add(new Separator());
        format.Items.Add(Mi("Табы → пробелы", () => Active?.TabsToSpaces(), null, null, () => Editable));
        format.Items.Add(Mi("Пробелы → табы", () => Active?.SpacesToTabs(), null, null, () => Editable));
        format.Items.Add(Mi("Убрать пробелы в концах строк", () => Active?.TrimTrailing(), null, null, () => Editable));
        format.Items.Add(Mi("Объединить строки", () => Active?.JoinLines(), null, null, () => Editable));
        format.Items.Add(new Separator());
        format.Items.Add(Mi("Сортировать строки А → Я", () => Active?.SortLines(false), null, "", () => Editable));
        format.Items.Add(Mi("Сортировать строки Я → А", () => Active?.SortLines(true), null, null, () => Editable));
        format.Items.Add(Mi("Убрать повторы строк", () => Active?.UniqueLines(), null, null, () => Editable));

        var enc = new MenuItem { Header = "_Кодировка" };
        enc.Items.Add(Sub("Открыть заново как", items =>
        {
            foreach (var e in TextCodec.All)
                items.Add(Mi(e.Name, () => Active?.ReopenAs(e), null, null, () => Editable, () => Active?.Encoding == e));
        }));
        enc.Items.Add(Sub("Сохранять в", items =>
        {
            foreach (var e in TextCodec.All)
                items.Add(Mi(e.Name, () => Active?.SaveEncoding(e), null, null, () => Editable, () => Active?.Encoding == e));
        }));

        var syntax = new MenuItem { Header = "_Синтаксис" };
        foreach (var (name, _, _) in SyntaxRegistry.All)
            syntax.Items.Add(Mi(name, () => Active?.SetSyntax(name), null, null, () => HasPane, () => Active?.Syntax == name));

        var tools = new MenuItem { Header = "_Инструменты" };
        tools.Items.Add(Mi("Base64: закодировать", () => Active?.TransformSelection(EditorPane.ToBase64, "Base64 ←"), null, null, () => Editable));
        tools.Items.Add(Mi("Base64: раскодировать", () => Active?.TransformSelection(EditorPane.FromBase64, "Base64 →"), null, null, () => Editable));
        tools.Items.Add(Mi("URL: закодировать", () => Active?.TransformSelection(Uri.EscapeDataString, "URL ←"), null, null, () => Editable));
        tools.Items.Add(Mi("URL: раскодировать", () => Active?.TransformSelection(Uri.UnescapeDataString, "URL →"), null, null, () => Editable));
        tools.Items.Add(new Separator());
        tools.Items.Add(Mi("JSON: форматировать", () => Active?.TransformSelection(EditorPane.JsonPretty, "JSON отформатирован"), null, "{ }", () => Editable));
        tools.Items.Add(Mi("JSON: сжать в строку", () => Active?.TransformSelection(EditorPane.JsonMinify, "JSON сжат"), null, null, () => Editable));
        tools.Items.Add(new Separator());
        var hash = Mi("Хеш выделения → буфер", () => { }, null, "#");
        foreach (var alg in new[] { "MD5", "SHA-1", "SHA-256", "SHA-512" })
            hash.Items.Add(Mi(alg, () => HashToClipboard(alg), null, null, () => HasPane));
        tools.Items.Add(hash);
        tools.Items.Add(CompareSub());
        tools.Items.Add(new Separator());
        tools.Items.Add(Mi("Статистика документа", ShowStats, null, "Σ", () => HasPane));

        foreach (var top in new[] { file, edit, search, view, format, enc, syntax, tools })
        {
            var t = top;
            t.SubmenuOpened += (_, e) => { if (ReferenceEquals(e.OriginalSource, t)) RefreshStates(t.Items); };
            MenuBar.Items.Add(t);
        }
    }

    private MenuItem Toggle(string header, Func<EditorSettings, bool> get, Action<EditorSettings, bool> set,
        string? key = null, string? glyph = null) =>
        Mi(header, () =>
        {
            var s = EditorSettings.Current;
            set(s, !get(s));
            EditorSettings.Save();
            foreach (var p in _panes.Values) p.ApplySettings(s);
            ApplyChromeVisibility();
            UpdateAll();
        }, key, glyph, null, () => get(EditorSettings.Current));

    private void SetTheme(string mode)
    {
        EditorSettings.Current.Theme = mode;
        EditorSettings.Save();
        ThemeManager.Apply(mode); // → Changed → OnThemeChanged
    }

    private void OnThemeChanged()
    {
        foreach (var p in _panes.Values) p.ApplyTheme();
        foreach (var t in _tabs) t.ThemeChanged();
        UpdateAll();
    }

    private void SetIndent(bool? spaces, int? width)
    {
        var s = EditorSettings.Current;
        if (spaces is { } sp) s.UseSpaces = sp;
        if (width is { } w) s.TabSize = w;
        EditorSettings.Save();
        foreach (var p in _panes.Values) p.ApplySettings(s);
        UpdateStatus();
    }

    private static readonly (string Prefix, string Title)[] CommentKinds =
    {
        ("#", "#  (shell, python, yaml, conf)"),
        ("//", "//  (js, c, go, json5)"),
        ("--", "--  (sql, lua)"),
        (";", ";  (ini, asm)"),
        ("<!--", "<!-- -->  (xml, html, md)"),
    };

    private MenuItem CommentSub(bool comment)
    {
        var m = Mi(comment ? "Закомментировать" : "Раскомментировать", () => { }, null, comment ? "//" : null);
        foreach (var (prefix, title) in CommentKinds)
        {
            var pr = prefix;
            m.Items.Add(Mi(title, () => { if (comment) Active?.Comment(pr); else Active?.Uncomment(pr); },
                null, null, () => Editable));
        }
        m.SubmenuOpened += (_, e) => { if (ReferenceEquals(e.OriginalSource, m)) RefreshStates(m.Items); };
        return m;
    }

    private MenuItem BookmarksSub() => Sub("Перейти к закладке", items =>
    {
        if (Active is not { } p) return;
        foreach (var line in p.Marks.Lines)
        {
            var l = line;
            items.Add(Mi(AccessSafe($"{l}:  {p.LinePreview(l)}"), () => p.GoToLine(l)));
        }
    }, "");

    private MenuItem EolSub()
    {
        var m = Mi("Концы строк", () => { }, null, "¶");
        foreach (var (eol, title) in new[] { (TextCodec.LF, "LF — Unix/Linux (для нод)"), (TextCodec.CRLF, "CRLF — Windows"), (TextCodec.CR, "CR — старый Mac") })
        {
            var e = eol;
            m.Items.Add(Mi(title, () => Active?.ConvertEol(e), null, null, () => Editable, () => Active?.Eol == e));
        }
        m.SubmenuOpened += (_, ev) => { if (ReferenceEquals(ev.OriginalSource, m)) RefreshStates(m.Items); };
        return m;
    }

    private MenuItem CompareSub() => Sub("Сравнить с", items =>
    {
        if (Active is not { } cur) return;
        foreach (var kv in _panes.Where(kv => !ReferenceEquals(kv.Value, cur)))
        {
            var other = kv.Value;
            var vm = _tabs.FirstOrDefault(t => t.Id == kv.Key);
            items.Add(Mi(AccessSafe(vm?.Name ?? other.FileName), () => Compare(cur, other, vm?.Name ?? other.FileName)));
        }
    }, "⇄");

    // ── Контекстное меню редактора (канон MobaTextEditor) ──
    private ContextMenu BuildContextMenu()
    {
        var m = new ContextMenu();
        m.Items.Add(Mi("Отменить", () => Active?.Editor.Undo(), "Ctrl+Z", "", () => Active?.Editor.CanUndo == true));
        m.Items.Add(Mi("Повторить", () => Active?.Editor.Redo(), "Ctrl+Y", "", () => Active?.Editor.CanRedo == true));
        m.Items.Add(new Separator());
        m.Items.Add(Mi("Выделить всё", () => Active?.Editor.SelectAll(), "Ctrl+A"));
        m.Items.Add(Mi("Вырезать", () => Active?.Editor.Cut(), "Ctrl+X", "", () => Editable && Active!.Editor.SelectionLength > 0));
        m.Items.Add(Mi("Копировать", () => Active?.Editor.Copy(), "Ctrl+C", "", () => Active?.Editor.SelectionLength > 0));
        m.Items.Add(Mi("Вставить", () => Active?.Editor.Paste(), "Ctrl+V", "", () => Editable && Clipboard.ContainsText()));
        m.Items.Add(new Separator());
        m.Items.Add(Mi("Сдвинуть строки вправо", () => Active?.Indent(), "Tab", "⇥", () => Editable));
        m.Items.Add(Mi("Сдвинуть строки влево", () => Active?.Unindent(), "Shift+Tab", "⇤", () => Editable));
        m.Items.Add(new Separator());
        m.Items.Add(CommentSub(true));
        m.Items.Add(CommentSub(false));
        m.Items.Add(new Separator());
        m.Items.Add(Mi("Закладка на этой строке", () => Active?.ToggleBookmark(), "Ctrl+F2", ""));
        m.Items.Add(BookmarksSub());
        m.Items.Add(new Separator());
        m.Items.Add(Mi("Найти далее", () => FindNext(false), "F3", ""));
        m.Items.Add(CompareSub());
        m.Opened += (_, _) => RefreshStates(m.Items);
        return m;
    }

    // ══════════════════════ Тулбар ══════════════════════

    private void BuildToolbar()
    {
        void B(string glyph, string tip, Action act, Func<bool>? enabled = null, Func<bool>? isOn = null)
        {
            var b = new Button
            {
                Style = (Style)FindResource("ToolBtn"),
                Content = glyph,
                ToolTip = tip,
            };
            if (!(glyph.Length == 1 && glyph[0] >= '')) { b.FontFamily = SymFont; b.FontSize = 14; }
            b.Click += (_, _) => { act(); UpdateAll(); };
            ToolBarPanel.Children.Add(b);
            _toolButtons.Add((b, enabled, isOn));
        }
        void Sep() => ToolBarPanel.Children.Add(new Border
        {
            Width = 1, Height = 20, Margin = new Thickness(6, 0, 6, 0),
            Background = (Brush)FindResource("BorderDim"),
        });

        B("", "Новый (Ctrl+N)", NewLocalDocument);
        B("", "Открыть (Ctrl+O)", OpenFromDisk);
        B("", "Перечитать (F5)", () => _ = Active?.ReloadAsync(), () => Editable);
        B("", "Сохранить (Ctrl+S)", () => _ = SaveActive(), () => Active?.Dirty == true);
        B("", "Сохранить как (Ctrl+Shift+S)", () => Active?.SaveAs(), () => HasPane);
        B("", "Печать (Ctrl+P)", Print, () => HasPane);
        B("", "Закрыть вкладку (Ctrl+W)", () => { if (ActiveVm is { } v) CloseTab(v.Id); }, () => HasPane);
        Sep();
        B("", "Отменить (Ctrl+Z)", () => Active?.Editor.Undo(), () => Active?.Editor.CanUndo == true);
        B("", "Повторить (Ctrl+Y)", () => Active?.Editor.Redo(), () => Active?.Editor.CanRedo == true);
        Sep();
        B("", "Вырезать (Ctrl+X)", () => Active?.Editor.Cut(), () => Editable);
        B("", "Копировать (Ctrl+C)", () => Active?.Editor.Copy(), () => HasPane);
        B("", "Вставить (Ctrl+V)", () => Active?.Editor.Paste(), () => Editable);
        Sep();
        B("", "Найти (Ctrl+F)", () => ShowFind(false), () => HasPane);
        B("", "Заменить (Ctrl+H)", () => ShowFind(true), () => Editable);
        B("#", "Перейти к строке (Ctrl+G)", GoToLine, () => HasPane);
        Sep();
        B("⇤", "Сдвинуть влево (Shift+Tab)", () => Active?.Unindent(), () => Editable);
        B("⇥", "Сдвинуть вправо (Tab)", () => Active?.Indent(), () => Editable);
        B("//", "Комментарий вкл/выкл (Ctrl+/)", () => Active?.ToggleComment(), () => Editable);
        Sep();
        B("", "Закладка (Ctrl+F2)", () => Active?.ToggleBookmark(), () => HasPane);
        B("", "Предыдущая закладка (Shift+F2)", () => Active?.NextBookmark(true), () => Active?.Marks.Lines.Any() == true);
        B("", "Следующая закладка (F2)", () => Active?.NextBookmark(false), () => Active?.Marks.Lines.Any() == true);
        Sep();
        B("↩", "Перенос строк (Alt+Z)", () => FlipSetting(s => s.WordWrap = !s.WordWrap), null, () => EditorSettings.Current.WordWrap);
        B("¶", "Пробелы, табы и концы строк", () => FlipSetting(s => { var v = !(s.ShowWhitespace || s.ShowEol); s.ShowWhitespace = v; s.ShowEol = v; }),
            null, () => EditorSettings.Current.ShowWhitespace || EditorSettings.Current.ShowEol);
        B("№", "Номера строк", () => FlipSetting(s => s.LineNumbers = !s.LineNumbers), null, () => EditorSettings.Current.LineNumbers);
        Sep();
        B("", "Крупнее (Ctrl++ / Ctrl+колесо)", () => Active?.Zoom(1), () => HasPane);
        B("", "Мельче (Ctrl+−)", () => Active?.Zoom(-1), () => HasPane);
        Sep();
        B("⇄", "Сравнить с соседней вкладкой", CompareWithNeighbour, () => _tabs.Count > 1);
    }

    private void FlipSetting(Action<EditorSettings> f)
    {
        f(EditorSettings.Current);
        EditorSettings.Save();
        foreach (var p in _panes.Values) p.ApplySettings(EditorSettings.Current);
    }

    private void ApplyChromeVisibility()
    {
        ToolBarHost.Visibility = EditorSettings.Current.Toolbar ? Visibility.Visible : Visibility.Collapsed;
        StatusBarHost.Visibility = EditorSettings.Current.StatusBar ? Visibility.Visible : Visibility.Collapsed;
    }

    // ══════════════════════ Горячие клавиши ══════════════════════

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var m = Keyboard.Modifiers;
        bool ctrl = m == ModifierKeys.Control, cs = m == (ModifierKeys.Control | ModifierKeys.Shift),
             ca = m == (ModifierKeys.Control | ModifierKeys.Alt), alt = m == ModifierKeys.Alt,
             shift = m == ModifierKeys.Shift, none = m == ModifierKeys.None;
        bool inFind = FindBar.IsKeyboardFocusWithin;

        Action? act = null;
        if (none && key == Key.Escape && FindBar.Visibility == Visibility.Visible) act = HideFind;
        else if (none && key == Key.F3) act = () => FindNext(false);
        else if (shift && key == Key.F3) act = () => FindNext(true);
        else if (ctrl && key == Key.F) act = () => ShowFind(false);
        else if (ctrl && key == Key.H) act = () => ShowFind(true);
        else if (ctrl && key == Key.S) act = () => _ = SaveActive();
        else if (inFind) { /* в строке поиска остальное — её собственные клавиши */ }
        else if (ctrl && key is Key.N or Key.T) act = NewLocalDocument;
        else if (ctrl && key == Key.O) act = OpenFromDisk;
        else if (cs && key == Key.S) act = () => Active?.SaveAs();
        else if (ca && key == Key.S) act = () => _ = SaveAll();
        else if (ctrl && key is Key.W or Key.F4) act = () => { if (ActiveVm is { } v) CloseTab(v.Id); };
        else if (ctrl && key == Key.P) act = Print;
        else if (none && key == Key.F5) act = () => _ = Active?.ReloadAsync();
        else if (ctrl && key == Key.G) act = GoToLine;
        else if (ctrl && key == Key.F2) act = () => Active?.ToggleBookmark();
        else if (none && key == Key.F2) act = () => Active?.NextBookmark(false);
        else if (shift && key == Key.F2) act = () => Active?.NextBookmark(true);
        else if (none && key == Key.F7) act = () => Active?.InsertAtCaret(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
        else if (ctrl && key == Key.D) act = () => Active?.DuplicateLines();
        else if (cs && key == Key.K) act = () => Active?.DeleteLines();
        else if (alt && key == Key.Up) act = () => Active?.MoveLines(true);
        else if (alt && key == Key.Down) act = () => Active?.MoveLines(false);
        else if (alt && key == Key.Z) act = () => FlipSetting(s => s.WordWrap = !s.WordWrap);
        else if (ctrl && key is Key.Oem2 or Key.Divide) act = () => Active?.ToggleComment();
        else if (cs && key == Key.U) act = () => Active?.TransformSelection(s => s.ToUpperInvariant(), "Верхний регистр");
        else if (ctrl && key == Key.U) act = () => Active?.TransformSelection(s => s.ToLowerInvariant(), "Нижний регистр");
        else if (ca && key == Key.Z) act = () => Active?.Revert();
        else if (ctrl && key is Key.OemPlus or Key.Add) act = () => Active?.Zoom(1);
        else if (ctrl && key is Key.OemMinus or Key.Subtract) act = () => Active?.Zoom(-1);
        else if (ctrl && key is Key.D0 or Key.NumPad0) act = () => Active?.Zoom(0);
        else if (ctrl && key is Key.Tab or Key.PageDown) act = () => CycleTab(1);
        else if (cs && key == Key.Tab || ctrl && key == Key.PageUp) act = () => CycleTab(-1);

        if (act is null) return;
        e.Handled = true;
        act();
        UpdateAll();
    }

    // ══════════════════════ Поиск и замена ══════════════════════

    private void ShowFind(bool replace)
    {
        if (Active is not { } p) return;
        FindBar.Visibility = Visibility.Visible;
        var rv = replace && !p.IsReadOnlyView ? Visibility.Visible : Visibility.Collapsed;
        ReplaceLabel.Visibility = ReplaceBox.Visibility = ReplaceButtons.Visibility = rv;
        var sel = p.Editor.SelectedText;
        if (sel.Length > 0 && !sel.Contains('\n')) FindBox.Text = sel;
        FindBox.Focus();
        FindBox.SelectAll();
        RefreshMatches();
    }

    private void HideFind()
    {
        FindBar.Visibility = Visibility.Collapsed;
        foreach (var p in _panes.Values)
        {
            p.Matches.Matches.Clear();
            p.Editor.TextArea.TextView.InvalidateLayer(ICSharpCode.AvalonEdit.Rendering.KnownLayer.Selection);
        }
        Active?.FocusEditor();
    }

    private Regex? BuildRegex()
    {
        var text = FindBox.Text;
        if (text.Length == 0) return null;
        var pat = RegexChip.IsChecked == true ? text : Regex.Escape(text);
        if (WordChip.IsChecked == true) pat = @"\b" + pat + @"\b";
        var opts = RegexOptions.Multiline | (CaseChip.IsChecked == true ? RegexOptions.None : RegexOptions.IgnoreCase);
        try { return new Regex(pat, opts, TimeSpan.FromSeconds(2)); }
        catch { return null; }
    }

    private void RefreshMatches()
    {
        if (Active is not { } p) return;
        var list = p.Matches.Matches;
        list.Clear();
        var rx = BuildRegex();
        if (rx is null)
        {
            FindCount.Text = FindBox.Text.Length > 0 ? "ошибка в выражении" : "";
        }
        else
        {
            try
            {
                foreach (Match m in rx.Matches(p.Editor.Document.Text))
                {
                    if (m.Length == 0) continue;
                    list.Add(new TextSegment { StartOffset = m.Index, Length = m.Length });
                    if (list.Count >= 20000) break;
                }
            }
            catch (RegexMatchTimeoutException) { }
            FindCount.Text = list.Count == 0 ? "не найдено" : CountText(p);
        }
        p.Editor.TextArea.TextView.InvalidateLayer(ICSharpCode.AvalonEdit.Rendering.KnownLayer.Selection);
    }

    private static string CountText(EditorPane p)
    {
        var list = p.Matches.Matches;
        var i = list.FindIndex(s => s.StartOffset == p.Editor.SelectionStart && s.Length == p.Editor.SelectionLength);
        return i >= 0 ? $"{i + 1} из {list.Count}" : $"совпадений: {list.Count}";
    }

    private void FindNext(bool back)
    {
        if (Active is not { } p) return;
        if (FindBox.Text.Length == 0) { ShowFind(false); return; }
        if (FindBar.Visibility != Visibility.Visible || p.Matches.Matches.Count == 0) RefreshMatches();
        var list = p.Matches.Matches;
        if (list.Count == 0) { FindCount.Text = "не найдено"; return; }
        var ed = p.Editor;
        TextSegment target;
        if (!back)
        {
            var from = ed.SelectionStart + ed.SelectionLength;
            target = list.FirstOrDefault(s => s.StartOffset >= from) ?? list[0];
        }
        else
        {
            var from = ed.SelectionStart;
            target = list.LastOrDefault(s => s.StartOffset < from) ?? list[^1];
        }
        ed.Select(target.StartOffset, target.Length);
        var loc = ed.Document.GetLocation(target.StartOffset);
        ed.ScrollTo(loc.Line, loc.Column);
        FindCount.Text = CountText(p);
    }

    private void Replace()
    {
        if (Active is not { IsReadOnlyView: false } p) return;
        var rx = BuildRegex();
        if (rx is null) return;
        var ed = p.Editor;
        var m = ed.SelectionLength > 0 ? rx.Match(ed.SelectedText) : Match.Empty;
        if (m.Success && m.Index == 0 && m.Length == ed.SelectionLength)
        {
            var repl = RegexChip.IsChecked == true ? m.Result(ReplaceBox.Text) : ReplaceBox.Text;
            ed.Document.Replace(ed.SelectionStart, ed.SelectionLength, repl);
            ed.Select(ed.SelectionStart + repl.Length, 0);
            RefreshMatches();
        }
        FindNext(false);
    }

    private void ReplaceAll()
    {
        if (Active is not { IsReadOnlyView: false } p) return;
        var rx = BuildRegex();
        if (rx is null) return;
        var doc = p.Editor.Document;
        int n = 0;
        string res;
        try
        {
            res = rx.Replace(doc.Text, m =>
            {
                n++;
                return RegexChip.IsChecked == true ? m.Result(ReplaceBox.Text) : ReplaceBox.Text;
            });
        }
        catch (RegexMatchTimeoutException) { FindCount.Text = "слишком сложное выражение"; return; }
        if (n > 0) doc.Replace(0, doc.TextLength, res); // один шаг отмены
        RefreshMatches();
        FindCount.Text = $"заменено: {n}";
    }

    private void Find_Changed(object sender, TextChangedEventArgs e) { _findTimer.Stop(); _findTimer.Start(); }
    private void FindOpt_Click(object sender, RoutedEventArgs e) => RefreshMatches();
    private void FindNext_Click(object sender, RoutedEventArgs e) => FindNext(false);
    private void FindPrev_Click(object sender, RoutedEventArgs e) => FindNext(true);
    private void FindClose_Click(object sender, RoutedEventArgs e) => HideFind();
    private void Replace_Click(object sender, RoutedEventArgs e) => Replace();
    private void ReplaceAll_Click(object sender, RoutedEventArgs e) => ReplaceAll();

    private void FindBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        FindNext(Keyboard.Modifiers == ModifierKeys.Shift);
        e.Handled = true;
    }

    // ══════════════════════ Прочие команды ══════════════════════

    private void GoToLine()
    {
        if (Active is not { } p) return;
        var max = p.Editor.Document.LineCount;
        var s = Prompt("Перейти к строке", $"Номер строки (1–{max}):", p.CaretLine.ToString());
        if (s is not null && int.TryParse(s.Trim(), out var n)) p.GoToLine(n);
    }

    private void HashToClipboard(string alg)
    {
        if (Active is not { } p) return;
        var h = EditorPane.Hash(p.SelectionOrAll(), alg);
        SafeCopy(h);
        StInfo.Text = $"{alg}: {h} — в буфере";
    }

    private void ShowStats()
    {
        if (Active is not { } p) return;
        var t = p.Editor.Document.Text;
        var words = Regex.Matches(t, @"\S+").Count;
        MessageBox.Show(this,
            $"Строк: {p.Editor.Document.LineCount}\nСлов: {words}\nСимволов: {t.Length}\n" +
            $"Байт в {p.Encoding.Name}: {TextCodec.Encode(t, p.Encoding).Length}",
            "Статистика — " + p.FileName, MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void CompareWithNeighbour()
    {
        if (Active is not { } cur || ActiveVm is not { } vm || _tabs.Count < 2) return;
        var i = _tabs.IndexOf(vm);
        var other = _tabs[i > 0 ? i - 1 : 1];
        if (_panes.TryGetValue(other.Id, out var op)) Compare(cur, op, other.Name);
    }

    /// <summary>Сравнение по запросу QTerm (файловая панель → «Сравнить»).</summary>
    private void CompareFromHost(EditorMsg m)
    {
        var a = _panes.FirstOrDefault(kv => kv.Value.DocId == m.Doc);
        if (a.Value is null) return;
        KeyValuePair<Guid, EditorPane> b;
        if (!string.IsNullOrEmpty(m.Text))
            b = _panes.FirstOrDefault(kv => kv.Value.DocId == m.Text);
        else if (!string.IsNullOrEmpty(m.Path) && File.Exists(m.Path))
        {
            OpenLocalFile(m.Path);
            b = _panes.FirstOrDefault(kv => string.Equals(kv.Value.LocalPath, m.Path, StringComparison.OrdinalIgnoreCase));
        }
        else return;
        if (b.Value is null) return;
        ActivateTab(a.Key);
        var bName = _tabs.FirstOrDefault(t => t.Id == b.Key)?.Name ?? b.Value.FileName;
        Compare(a.Value, b.Value, bName);
        BringToFront();
    }

    /// <summary>Сравнение двух вкладок: отдельная вкладка с построчным diff.</summary>
    private void Compare(EditorPane a, EditorPane b, string bName)
    {
        var aName = ActiveVm?.Name ?? a.FileName;
        var model = new InlineDiffBuilder(new Differ()).BuildDiffModel(a.Editor.Document.Text, b.Editor.Document.Text);
        var sb = new System.Text.StringBuilder();
        int plus = 0, minus = 0;
        foreach (var l in model.Lines)
        {
            switch (l.Type)
            {
                case ChangeType.Inserted: plus++; sb.Append("+ ").AppendLine(l.Text); break;
                case ChangeType.Deleted: minus++; sb.Append("- ").AppendLine(l.Text); break;
                default: sb.Append("  ").AppendLine(l.Text); break;
            }
        }
        var head = $"Сравнение: {aName}  ⇄  {bName}\n--- {aName}\n+++ {bName}\n@@ добавлено строк: {plus}, удалено: {minus} @@\n";
        var pane = EditorPane.View("Сравнение", head + sb, "Diff");
        AddPane(pane, $"⇄ {aName} / {bName}", "сравнение (только чтение)", "⇄");
    }

    private string? Prompt(string title, string label, string value)
    {
        var box = new TextBox { Text = value, MinWidth = 260, Margin = new Thickness(0, 6, 0, 12) };
        var ok = new Button { Content = "OK", IsDefault = true, MinWidth = 80 };
        var cancel = new Button { Content = "Отмена", IsCancel = true, MinWidth = 80, Margin = new Thickness(8, 0, 0, 0) };
        var w = new Window
        {
            Title = title, Owner = this, SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false, Background = (Brush)FindResource("BgBrush"),
            Content = new StackPanel
            {
                Margin = new Thickness(16),
                Children =
                {
                    Themed(new TextBlock { Text = label }, TextBlock.ForegroundProperty, "FgBrush"),
                    box,
                    new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Children = { ok, cancel } },
                },
            },
        };
        string? result = null;
        ok.Click += (_, _) => { result = box.Text; w.DialogResult = true; };
        w.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        w.ShowDialog();
        return result;
    }

    private static T Themed<T>(T el, DependencyProperty dp, string key) where T : FrameworkElement
    {
        el.SetResourceReference(dp, key);
        return el;
    }

    private static void SafeCopy(string s)
    {
        try { Clipboard.SetText(s); } catch { /* буфер занят другим процессом */ }
    }

    // ══════════════════════ Статус, заголовок, тулбар ══════════════════════

    private void UpdateAll()
    {
        EmptyHint.Visibility = _tabs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var (btn, en, on) in _toolButtons)
        {
            btn.IsEnabled = en?.Invoke() ?? true;
            btn.Background = on?.Invoke() == true ? ThemeManager.Brush("SelBrush") : Brushes.Transparent;
        }
        var p = Active;
        Title = p is null ? "QEditor"
            : $"{(p.Dirty ? "• " : "")}{p.FileName}{(p.IsLocal ? "" : $" — {p.Node}")} — QEditor";
        if (ActiveVm is { } vm && p is not null) vm.Dirty = p.Dirty;
        UpdateStatus();
    }

    private void UpdateStatus()
    {
        var p = Active;
        if (p is null)
        {
            StPos.Text = StInfo.Text = StSyntax.Text = StEnc.Text = StEol.Text = StIns.Text = StZoom.Text = "";
            return;
        }
        var ed = p.Editor;
        var caret = ed.TextArea.Caret;
        var sel = ed.SelectionLength;
        StPos.Text = $"Стр {caret.Line}, Кол {caret.Column}   ·   строк {ed.Document.LineCount}" +
                     (sel > 0 ? $"   ·   выделено {sel}" : "");
        var where = p.IsReadOnlyView ? "только чтение" : p.Location;
        var link = !p.IsLocal && !_hostConnected ? "   ·   ⚠ нет связи с QTerm" : "";
        StInfo.Text = $"{where}{link}{(p.Status.Length > 0 ? "   ·   " + p.Status : "")}";
        StSyntax.Text = p.Syntax;
        StEnc.Text = p.Encoding.Name;
        StEol.Text = TextCodec.EolName(p.Eol);
        StIns.Text = ed.TextArea.OverstrikeMode ? "ЗАМ" : "ВСТ";
        StZoom.Text = $"{ed.FontSize:0.#} pt · {(EditorSettings.Current.UseSpaces ? "пробелы" : "табы")} {EditorSettings.Current.TabSize}";
    }

    private void PopupMenu(UIElement target, IEnumerable<MenuItem> items)
    {
        var m = new ContextMenu { PlacementTarget = target, Placement = PlacementMode.Top };
        foreach (var i in items) m.Items.Add(i);
        RefreshStates(m.Items);
        m.IsOpen = true;
    }

    private void StSyntax_Click(object sender, MouseButtonEventArgs e) =>
        PopupMenu(StSyntax, SyntaxRegistry.All.Select(s =>
        {
            var n = s.Name;
            return Mi(n, () => { Active?.SetSyntax(n); UpdateAll(); }, null, null, () => HasPane, () => Active?.Syntax == n);
        }));

    private void StEnc_Click(object sender, MouseButtonEventArgs e) =>
        PopupMenu(StEnc, TextCodec.All.Select(x =>
            Mi("Сохранять в " + x.Name, () => { Active?.SaveEncoding(x); UpdateAll(); }, null, null, () => Editable, () => Active?.Encoding == x)));

    private void StEol_Click(object sender, MouseButtonEventArgs e) =>
        PopupMenu(StEol, new[] { (TextCodec.LF, "LF — Unix/Linux"), (TextCodec.CRLF, "CRLF — Windows"), (TextCodec.CR, "CR — старый Mac") }
            .Select(t => Mi(t.Item2, () => { Active?.ConvertEol(t.Item1); UpdateAll(); }, null, null, () => Editable, () => Active?.Eol == t.Item1)));
}
