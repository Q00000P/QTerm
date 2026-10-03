using System.ComponentModel;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QTermWin.Models;
using QTermWin.Vault;

namespace QTermWin.UI;

/// <summary>
/// Команды с Git (гисты и т.п.): вручную — имя, варианты команды (curl / wget …)
/// и заметка. Одно окно и для быстрого вызова (хоткей: поиск → Enter), и для правки.
/// Результат (текст + запускать ли) забирает MainWindow и шлёт в терминал.
/// </summary>
public partial class GitCmdsWindow : Window
{
    public sealed record Row(Guid Id, string Name, string Preview, string Tip);

    private static readonly Regex UrlRx = new(@"https?://[^\s'""<>|;&]+", RegexOptions.Compiled);

    private readonly VaultRepo _repo;
    private Guid? _current;   // null = новая запись (ещё не сохранена)
    private bool _loading;    // программная загрузка полей/списка — не «изменено»
    private bool _dirty;
    private List<GitVariant> _vars = new() { new GitVariant() };
    private int _vi;          // выбранный вариант

    /// <summary>Что вставить в терминал (null — ничего).</summary>
    public string? ResultText { get; private set; }
    /// <summary>true — с Enter (запустить), false — только вставить.</summary>
    public bool ResultExecute { get; private set; }

    /// <param name="select">Сразу открыть эту запись (F2 из быстрого вызова).</param>
    /// <param name="startNew">Сразу новая запись (Ctrl+N из быстрого вызова).</param>
    public GitCmdsWindow(VaultRepo repo, Guid? select = null, bool startNew = false)
    {
        InitializeComponent();
        _repo = repo;
        Blank();
        Refresh(null);
        if (select is { } sel && _repo.GitCommandById(sel) is not null) Refresh(sel);
        Loaded += (s, e) =>
        {
            if (startNew) { NewEntry(); return; }
            SearchBox.Focus();
            Keyboard.Focus(SearchBox);
        };
        PreviewKeyDown += OnKeys;
        Closing += OnClosing;
    }

    // ── Список ──

    private static bool Has(string? s, string f) =>
        s?.Contains(f, StringComparison.OrdinalIgnoreCase) == true;

    private static string FirstLine(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return "";
        var line = s.Replace("\r", "").Split('\n').FirstOrDefault(l => l.Trim().Length > 0) ?? "";
        return line.Trim();
    }

    private static Row ToRow(GitCommand g)
    {
        var vars = g.AllVariants();
        var labels = vars.Count > 1 ? "[" + string.Join(" · ", vars.Select(v => v.Label)) + "] " : "";
        var tip = string.Join("\n", vars.Select(v => (vars.Count > 1 ? v.Label + ": " : "") + v.Command));
        if (!string.IsNullOrWhiteSpace(g.Note)) tip += "\n\n" + g.Note;
        return new Row(g.Id, g.Name, labels + FirstLine(g.Note), tip);
    }

    /// <summary>Перестроить список (без загрузки полей). Возвращает выбранную строку.</summary>
    private Row? RebuildList(Guid? select, bool pickFirst = true)
    {
        var f = SearchBox.Text.Trim();
        var rows = _repo.VisibleGitCommands
            .Where(g => f.Length == 0 || Has(g.Name, f) || Has(g.Note, f) || Has(g.Command, f) ||
                        g.Variants?.Any(v => Has(v.Command, f) || Has(v.Label, f)) == true)
            .Select(ToRow)
            .ToList();

        _loading = true;
        List.ItemsSource = rows;
        var pick = rows.FirstOrDefault(r => r.Id == select)
                   ?? rows.FirstOrDefault(r => r.Id == _current)
                   // идёт правка — не перескакиваем на другую запись при поиске
                   ?? (_dirty || !pickFirst ? null : rows.FirstOrDefault());
        List.SelectedItem = pick;
        if (pick is not null) List.ScrollIntoView(pick);
        _loading = false;
        return pick;
    }

    private void Refresh(Guid? select)
    {
        var pick = RebuildList(select);
        if (pick is not null && pick.Id != _current && !_dirty) Load(pick.Id);
        else if (_current is { } cur && _repo.GitCommandById(cur) is null) Blank(); // удалена
        UpdateStatus();
    }

    private void Search_Changed(object sender, TextChangedEventArgs e) => Refresh(null);

    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        if (List.SelectedItem is Row r && r.Id != _current) Load(r.Id);
    }

    private void List_DoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (List.SelectedItem is Row) Run(execute: true);
    }

    // ── Поля ──

    private void Load(Guid id)
    {
        var saved = AutoSave();
        var g = _repo.GitCommandById(id);
        if (g is null) { Blank(); return; }
        ShowEntry(g, GitUsage.Variant(g.Id));
        if (saved) RebuildList(id); // сохранённая при переходе запись — сразу в списке
    }

    private void ShowEntry(GitCommand g, int variant)
    {
        _current = g.Id;
        _vars = g.AllVariants();
        _vi = Math.Clamp(variant, 0, _vars.Count - 1);
        _loading = true;
        NameBox.Text = g.Name;
        NoteBox.Text = g.Note;
        _loading = false;
        _dirty = false;
        BuildChips();
        ShowVariant();
        UpdateStatus();
    }

    private void Blank()
    {
        _current = null;
        _vars = new List<GitVariant> { new() };
        _vi = 0;
        _loading = true;
        NameBox.Text = NoteBox.Text = "";
        _loading = false;
        _dirty = false;
        BuildChips();
        ShowVariant();
        UpdateStatus();
    }

    private string ChipText(int i)
    {
        var v = _vars[i];
        if (v.Label.Trim().Length > 0) return v.Label.Trim();
        return v.Command.Trim().Length > 0 ? GitVariant.DeriveLabel(v.Command) : $"#{i + 1}";
    }

    private void BuildChips()
    {
        VarPanel.Children.Clear();
        for (int i = 0; i < _vars.Count; i++)
        {
            var idx = i;
            var chip = new Button
            {
                Content = ChipText(i), Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(0, 0, 4, 4),
                ToolTip = (i < 9 ? $"Ctrl+{i + 1}\n" : "") + _vars[i].Command, Focusable = false,
            };
            chip.Click += (s, e) => SelectVariant(idx);
            VarPanel.Children.Add(chip);
        }
        PaintChips();
    }

    private void PaintChips()
    {
        for (int i = 0; i < VarPanel.Children.Count; i++)
        {
            if (VarPanel.Children[i] is not Button b) continue;
            if (i == _vi) b.SetResourceReference(BackgroundProperty, "SelBrush");
            else b.ClearValue(BackgroundProperty);
        }
    }

    private void ShowVariant()
    {
        _loading = true;
        LabelBox.Text = _vars[_vi].Label;
        CmdBox.Text = _vars[_vi].Command;
        _loading = false;
        PaintChips();
    }

    private void SelectVariant(int i)
    {
        if (i < 0 || i >= _vars.Count) return;
        _vi = i;
        if (_current is { } id) GitUsage.SetVariant(id, i);
        ShowVariant();
        UpdateStatus();
    }

    private void Field_Changed(object sender, TextChangedEventArgs e)
    {
        if (_loading) return;
        if (ReferenceEquals(sender, CmdBox)) _vars[_vi].Command = CmdBox.Text;
        else if (ReferenceEquals(sender, LabelBox)) _vars[_vi].Label = LabelBox.Text;
        if ((ReferenceEquals(sender, CmdBox) || ReferenceEquals(sender, LabelBox)) &&
            _vi < VarPanel.Children.Count && VarPanel.Children[_vi] is Button chip)
            chip.Content = ChipText(_vi);
        _dirty = true;
        UpdateStatus();
    }

    private void UpdateStatus()
    {
        var n = _repo.VisibleGitCommands.Count();
        var state = _current is null
            ? (_dirty ? "● новая, не сохранена" : "")
            : (_dirty ? "● изменено" : "");
        if (_vars.Count > 1) state = (state.Length > 0 ? state + " · " : "") + $"вариант {_vi + 1}/{_vars.Count}";
        Status.Text = (state.Length > 0 ? state + " · " : "") +
            $"{n} шт. · Enter — выполнить · Shift+Enter — вставить" +
            (_vars.Count > 1 ? " · Alt+←/→ — вариант" : "") + " · Ctrl+S — сохранить";
    }

    /// <summary>Имя по умолчанию: имя файла из последней ссылки
    /// (…/raw/server-init.sh → server-init.sh), иначе начало команды.</summary>
    public static string DeriveName(string cmd)
    {
        foreach (Match m in UrlRx.Matches(cmd).Reverse())
        {
            var u = m.Value.Split('?', '#')[0].TrimEnd('/');
            var seg = u[(u.LastIndexOf('/') + 1)..];
            if (seg.Length > 0 && !seg.Equals("raw", StringComparison.OrdinalIgnoreCase) &&
                !seg.Contains(':'))
                return Uri.UnescapeDataString(seg);
        }
        var first = FirstLine(cmd);
        return first.Length > 40 ? first[..40] + "…" : first;
    }

    private static string Normalize(string s) => s.Replace("\r\n", "\n").Replace('\r', '\n');

    private static string CleanCmd(string s) => Normalize(s).Trim('\n', ' ', '\t');

    /// <summary>Метки без пустых и без повторов (curl, curl-2…).</summary>
    private static void FixLabels(List<GitVariant> vars, IEnumerable<string>? taken = null)
    {
        var used = new HashSet<string>(taken ?? Array.Empty<string>(), StringComparer.OrdinalIgnoreCase);
        foreach (var v in vars)
        {
            var baseLabel = v.Label.Trim().Length > 0 ? v.Label.Trim() : GitVariant.DeriveLabel(v.Command);
            var label = baseLabel;
            for (int k = 2; used.Contains(label); k++) label = $"{baseLabel}-{k}";
            v.Label = label;
            used.Add(label);
        }
    }

    /// <summary>Добавить варианты в существующую запись (одинаковые команды не дублируются).
    /// Возвращает индекс первого добавленного (или -1, если все уже были).</summary>
    private int MergeInto(GitCommand dst, List<GitVariant> add, string note)
    {
        var all = dst.AllVariants();
        var fresh = add.Where(v => all.All(x => CleanCmd(x.Command) != CleanCmd(v.Command)))
                       .Select(v => new GitVariant { Label = v.Label, Command = CleanCmd(v.Command) })
                       .ToList();
        FixLabels(fresh, all.Select(x => x.Label));
        var first = fresh.Count > 0 ? all.Count : -1;
        all.AddRange(fresh);
        dst.Command = all[0].Command;
        dst.Variants = all.Count > 1 ? all : dst.Variants;
        if (note.Length > 0 && !dst.Note.Contains(note, StringComparison.Ordinal))
            dst.Note = dst.Note.Length > 0 ? dst.Note.TrimEnd() + "\n" + note : note;
        _repo.SaveGitCommand(dst); // updatedAt = сейчас → синк
        return first;
    }

    /// <summary>Сохранить текущую запись. Новая с таким же именем, как существующая, —
    /// предложить добавить вариантом. false — нечего сохранять / отменили.</summary>
    private bool SaveCore(bool allowCancel)
    {
        var vars = _vars.Select(v => new GitVariant { Label = v.Label.Trim(), Command = CleanCmd(v.Command) })
                        .Where(v => v.Command.Length > 0).ToList();
        if (vars.Count == 0)
        {
            Status.Text = "Пустая команда — нечего сохранять";
            CmdBox.Focus();
            return false;
        }
        FixLabels(vars);
        var name = NameBox.Text.Trim();
        if (name.Length == 0) name = DeriveName(vars[0].Command);
        var note = Normalize(NoteBox.Text).TrimEnd();

        if (_current is null &&
            _repo.VisibleGitCommands.FirstOrDefault(x => string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase)) is { } same)
        {
            var r = MessageBox.Show(this,
                $"Запись «{same.Name}» уже есть.\n\nДа — добавить эту команду в неё вариантом\nНет — сохранить отдельной записью",
                "Команды Git", allowCancel ? MessageBoxButton.YesNoCancel : MessageBoxButton.YesNo,
                MessageBoxImage.Question);
            if (r == MessageBoxResult.Cancel) return false;
            if (r == MessageBoxResult.Yes)
            {
                var added = MergeInto(same, vars, note);
                _dirty = false;
                ShowEntry(same, added >= 0 ? added : 0);
                if (_current is { } sid) GitUsage.SetVariant(sid, _vi);
                Status.Text = added >= 0 ? $"Добавлено вариантом в «{same.Name}»" : $"Такая команда в «{same.Name}» уже есть";
                return true;
            }
        }

        var g = (_current is { } id ? _repo.GitCommandById(id) : null) ?? new GitCommand();
        g.Name = name;
        g.Command = vars[0].Command;
        // один вариант со своей меткой тоже храним списком — иначе метка потеряется
        g.Variants = vars.Count > 1 || vars[0].Label != GitVariant.DeriveLabel(vars[0].Command) ? vars : null;
        g.Note = note;
        _repo.SaveGitCommand(g);

        var keep = Math.Clamp(_vi, 0, vars.Count - 1);
        _dirty = false;
        ShowEntry(g, keep);
        GitUsage.SetVariant(g.Id, _vi);
        return true;
    }

    /// <summary>Переход на другую запись / новая — несохранённое сохраняем сами
    /// (список обновляется сразу, без переоткрытия окна). true — было что сохранить.</summary>
    private bool AutoSave()
    {
        if (!_dirty) return false;
        if (_vars.All(v => CleanCmd(v.Command).Length == 0)) { _dirty = false; return false; } // пустое — нечего
        var ok = SaveCore(allowCancel: false);
        _dirty = false;
        return ok;
    }

    // ── Кнопки ──

    private void New_Click(object sender, RoutedEventArgs e) => NewEntry();

    private static string ClipCommand()
    {
        string clip = "";
        try { if (Clipboard.ContainsText()) clip = Clipboard.GetText(); } catch { }
        clip = Normalize(clip).Trim();
        return clip.Length is > 0 and <= 4000 && UrlRx.IsMatch(clip) ? clip : "";
    }

    private void NewEntry()
    {
        AutoSave();
        _loading = true;
        List.SelectedItem = null;
        _loading = false;
        Blank();
        RebuildList(null, pickFirst: false); // только что сохранённое — видно сразу

        // Скопировал команду со ссылкой из гиста — подставляем сразу
        var clip = ClipCommand();
        if (clip.Length > 0)
        {
            CmdBox.Text = clip;          // → Field_Changed → dirty
            NameBox.Text = DeriveName(clip);
            NoteBox.Focus();
            if (_repo.VisibleGitCommands.FirstOrDefault(x =>
                    string.Equals(x.Name, NameBox.Text.Trim(), StringComparison.OrdinalIgnoreCase)) is { } same)
            {
                Status.Text = $"«{same.Name}» уже есть — при сохранении предложу добавить вариантом";
                return;
            }
        }
        else NameBox.Focus();
        UpdateStatus();
    }

    private void AddVariant_Click(object sender, RoutedEventArgs e)
    {
        var clip = ClipCommand();
        if (clip.Length > 0 && _vars.Any(v => CleanCmd(v.Command) == clip)) clip = ""; // такая уже есть
        // пустой последний вариант переиспользуем
        if (_vars.Count > 0 && CleanCmd(_vars[^1].Command).Length == 0)
            _vars[^1].Command = clip;
        else
            _vars.Add(new GitVariant { Command = clip });
        _vi = _vars.Count - 1;
        BuildChips();
        ShowVariant();
        _dirty = true;
        UpdateStatus();
        if (clip.Length > 0) LabelBox.Focus(); else CmdBox.Focus();
    }

    private void DelVariant_Click(object sender, RoutedEventArgs e)
    {
        if (_vars.Count <= 1)
        {
            Status.Text = "Это единственный вариант — удаляй запись целиком";
            return;
        }
        _vars.RemoveAt(_vi);
        _vi = Math.Min(_vi, _vars.Count - 1);
        BuildChips();
        ShowVariant();
        _dirty = true;
        UpdateStatus();
    }

    private void Save_Click(object sender, RoutedEventArgs e) => DoSave();

    private void DoSave()
    {
        if (!SaveCore(allowCancel: true)) return;
        RebuildList(_current);
        var msg = Status.Text.StartsWith("Добавлено", StringComparison.Ordinal) ||
                  Status.Text.StartsWith("Такая", StringComparison.Ordinal) ? Status.Text : "Сохранено";
        UpdateStatus();
        Status.Text = msg + " · " + Status.Text;
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (_current is not { } id)
        {
            Blank();
            Refresh(null);
            return;
        }
        var name = _repo.GitCommandById(id)?.Name ?? "";
        if (MessageBox.Show(this, $"Удалить «{name}» со всеми вариантами? Удаление уедет на все устройства.",
                "Команды Git", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;
        _repo.DeleteGitCommand(id);
        _current = null;
        _dirty = false;
        Refresh(null);
        if (_current is null) Blank();
    }

    // Контекстное меню списка: объединить записи
    private void List_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        var menu = List.ContextMenu!;
        menu.Items.Clear();
        if (List.SelectedItem is not Row row) { e.Handled = true; return; }
        var others = _repo.VisibleGitCommands.Where(g => g.Id != row.Id).ToList();
        var join = new MenuItem { Header = "Присоединить вариантом к", IsEnabled = others.Count > 0 };
        foreach (var o in others)
        {
            var dst = o.Id;
            var mi = new MenuItem { Header = o.Name.Replace("_", "__") };
            mi.Click += (s, a) => JoinEntries(row.Id, dst);
            join.Items.Add(mi);
        }
        menu.Items.Add(join);
        menu.Items.Add(new Separator());
        var del = new MenuItem { Header = "Удалить" };
        del.Click += (s, a) => Delete_Click(this, new RoutedEventArgs());
        menu.Items.Add(del);
    }

    /// <summary>Запись src целиком становится вариантами dst (src удаляется).</summary>
    private void JoinEntries(Guid srcId, Guid dstId)
    {
        AutoSave();
        var src = _repo.GitCommandById(srcId);
        var dst = _repo.GitCommandById(dstId);
        if (src is null || dst is null) return;
        var srcVars = src.AllVariants();
        var added = MergeInto(dst, srcVars, src.Note);
        _repo.DeleteGitCommand(src.Id);
        _current = null;
        _dirty = false;
        RebuildList(dst.Id);
        ShowEntry(dst, added >= 0 ? added : 0);
        Status.Text = $"«{src.Name}» присоединена к «{dst.Name}»";
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        var cmd = CleanCmd(_vars[_vi].Command);
        if (cmd.Length == 0) return;
        try
        {
            Clipboard.SetText(cmd);
            Status.Text = "Скопировано в буфер";
        }
        catch (Exception ex) { Status.Text = "Буфер занят: " + ex.Message; }
    }

    private void Run_Click(object sender, RoutedEventArgs e) => Run(execute: true);
    private void Insert_Click(object sender, RoutedEventArgs e) => Run(execute: false);

    private void Run(bool execute)
    {
        if (CleanCmd(_vars[_vi].Command).Length == 0) return;
        if (_dirty && !SaveCore(allowCancel: true)) return; // правки не теряем
        var cmd = Normalize(_vars[_vi].Command).Trim('\n');
        if (cmd.Trim().Length == 0) return;
        if (_current is { } id) GitUsage.Touch(id, _vi);
        ResultText = cmd;
        ResultExecute = execute;
        DialogResult = true;
    }

    // ── Клавиатура ──

    private void OnKeys(object sender, KeyEventArgs e)
    {
        var mods = Keyboard.Modifiers;
        var inQuick = SearchBox.IsKeyboardFocused || List.IsKeyboardFocusWithin;
        var key = e.Key == Key.System ? e.SystemKey : e.Key; // с Alt WPF отдаёт Key.System

        switch (key)
        {
            case Key.Escape:
                e.Handled = true;
                Close();
                return;
            case Key.S when mods == ModifierKeys.Control:
                e.Handled = true;
                DoSave();
                return;
            case Key.N when mods == ModifierKeys.Control:
                e.Handled = true;
                NewEntry();
                return;
            case >= Key.D1 and <= Key.D9 when mods == ModifierKeys.Control:
                e.Handled = true;
                SelectVariant(key - Key.D1);
                return;
            case Key.Enter when mods == ModifierKeys.Control:
                e.Handled = true;
                Run(execute: true);
                return;
            case Key.Enter when inQuick && (mods == ModifierKeys.None || mods == ModifierKeys.Shift):
                e.Handled = true;
                Run(execute: mods == ModifierKeys.None);
                return;
            case Key.Enter when (NameBox.IsKeyboardFocused || LabelBox.IsKeyboardFocused) && mods == ModifierKeys.None:
                e.Handled = true;
                DoSave();
                return;
            case Key.Down or Key.Up when SearchBox.IsKeyboardFocused && List.Items.Count > 0:
                e.Handled = true;
                var i = List.SelectedIndex + (key == Key.Down ? 1 : -1);
                List.SelectedIndex = Math.Clamp(i, 0, List.Items.Count - 1);
                List.ScrollIntoView(List.SelectedItem);
                return;
            case Key.Left or Key.Right when inQuick && mods == ModifierKeys.Alt && _vars.Count > 1:
                e.Handled = true;
                SelectVariant((_vi + (key == Key.Right ? 1 : _vars.Count - 1)) % _vars.Count);
                return;
            case Key.Delete when List.IsKeyboardFocusWithin && mods == ModifierKeys.None:
                e.Handled = true;
                Delete_Click(this, new RoutedEventArgs());
                return;
        }
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        if (DialogResult == true || !_dirty) return;
        if (_vars.All(v => CleanCmd(v.Command).Length == 0)) return; // пустая новая — не спрашиваем
        var what = NameBox.Text.Trim().Length > 0 ? $"«{NameBox.Text.Trim()}»" : "новую команду";
        var r = MessageBox.Show(this, $"Сохранить {what}?", "Команды Git",
            MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (r == MessageBoxResult.Cancel) e.Cancel = true;
        else if (r == MessageBoxResult.Yes && !SaveCore(allowCancel: true)) e.Cancel = true;
    }
}
