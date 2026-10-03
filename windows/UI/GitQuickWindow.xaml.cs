using System.ComponentModel;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QTermWin.Models;
using QTermWin.Vault;

namespace QTermWin.UI;

/// <summary>
/// Быстрый вызов команд Git — палитра в духе VS Code: хоткей → набрал пару букв →
/// Enter. Строка = запись, справа её варианты (curl / wget), активный подсвечен.
/// Частые и недавние сверху (F1 → Enter повторяет последнее). Слово из метки
/// в поиске сразу выбирает вариант («self wget»). Редактирование — F2 (полное окно).
/// </summary>
public partial class GitQuickWindow : Window
{
    public enum QuickAction { None, Run, Insert, Edit, New }

    public sealed class ChipVM : INotifyPropertyChanged
    {
        public int Index { get; init; }
        public string Label { get; init; } = "";
        public string Command { get; init; } = "";
        public ItemVM Owner { get; init; } = null!;
        private bool _active;
        public bool IsActive
        {
            get => _active;
            set
            {
                if (_active == value) return;
                _active = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsActive)));
            }
        }
        public event PropertyChangedEventHandler? PropertyChanged;
    }

    public sealed class ItemVM : INotifyPropertyChanged
    {
        public GitCommand Cmd { get; }
        public List<GitVariant> Vars { get; }
        public List<ChipVM> Chips { get; }
        public string Name => Cmd.Name;
        public string Num { get; set; } = "";
        public string Tip { get; }
        public Visibility ChipsVisibility => Vars.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        public int Score { get; set; }
        private int _active;

        public ItemVM(GitCommand cmd, int active)
        {
            Cmd = cmd;
            Vars = cmd.AllVariants();
            Chips = Vars.Select((v, i) => new ChipVM { Index = i, Label = v.Label, Command = v.Command, Owner = this }).ToList();
            var tip = string.Join("\n", Vars.Select(v => (Vars.Count > 1 ? v.Label + ": " : "") + v.Command));
            if (!string.IsNullOrWhiteSpace(cmd.Note)) tip += "\n\n" + cmd.Note;
            Tip = tip;
            Active = active;
        }

        public int Active
        {
            get => _active;
            set
            {
                _active = Math.Clamp(value, 0, Vars.Count - 1);
                foreach (var c in Chips) c.IsActive = c.Index == _active;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Sub)));
            }
        }

        public string Command => Vars[_active].Command;

        /// <summary>Под именем: заметка, а без неё — сжатая команда (ссылки → …/файл).</summary>
        public string Sub
        {
            get
            {
                var note = FirstLine(Cmd.Note);
                return note.Length > 0 ? note : Compact(Command);
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }

    private static readonly Regex UrlRx = new(@"https?://[^\s'""<>|;&]+", RegexOptions.Compiled);

    private static string FirstLine(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return "";
        return (s.Replace("\r", "").Split('\n').FirstOrDefault(l => l.Trim().Length > 0) ?? "").Trim();
    }

    private static string Compact(string cmd)
    {
        var s = UrlRx.Replace(cmd, m =>
        {
            var u = m.Value.Split('?', '#')[0].TrimEnd('/');
            var seg = u[(u.LastIndexOf('/') + 1)..];
            return seg.Length > 0 ? "…/" + seg : m.Value;
        });
        return Regex.Replace(s.Replace("\r", "").Replace("\n", " ⏎ "), @"\s+", " ").Trim();
    }

    private static string Normalize(string s) => s.Replace("\r\n", "\n").Replace('\r', '\n');

    private readonly List<ItemVM> _all;
    private readonly Gesture? _toggle;
    private bool _closing;

    public QuickAction Chosen { get; private set; }
    public string? Text { get; private set; }
    public Guid? EntryId { get; private set; }

    public GitQuickWindow(VaultRepo repo, Gesture? toggle)
    {
        InitializeComponent();
        _toggle = toggle;
        _all = repo.VisibleGitCommands.Select(g => new ItemVM(g, GitUsage.Variant(g.Id))).ToList();
        Refilter();
        Loaded += (s, e) => { SearchBox.Focus(); Keyboard.Focus(SearchBox); };
        PreviewKeyDown += OnKeys;
        Deactivated += (s, e) => { if (!_closing) { _closing = true; Close(); } };
        Closing += (s, e) => _closing = true;
    }

    // ── Поиск и порядок ──

    private static string Recency(ItemVM i) => GitUsage.Get(i.Cmd.Id)?.LastUsed ?? "";
    private static int Uses(ItemVM i) => GitUsage.Get(i.Cmd.Id)?.Count ?? 0;

    private static bool WordStart(string s, string t)
    {
        for (int i = s.IndexOf(t, StringComparison.OrdinalIgnoreCase); i >= 0;
             i = s.IndexOf(t, i + 1, StringComparison.OrdinalIgnoreCase))
            if (i == 0 || !char.IsLetterOrDigit(s[i - 1])) return true;
        return false;
    }

    /// <summary>Очки одного слова запроса; variant — вариант, который это слово назвало.</summary>
    private static int TermScore(ItemVM it, string t, out int? variant)
    {
        variant = null;
        int name = it.Name.StartsWith(t, StringComparison.OrdinalIgnoreCase) ? 100
                 : WordStart(it.Name, t) ? 70
                 : it.Name.Contains(t, StringComparison.OrdinalIgnoreCase) ? 50 : 0;
        int label = 0, cmd = 0;
        for (int i = 0; i < it.Vars.Count; i++)
        {
            var v = it.Vars[i];
            var ls = v.Label.Equals(t, StringComparison.OrdinalIgnoreCase) ? 60
                   : v.Label.StartsWith(t, StringComparison.OrdinalIgnoreCase) ? 40 : 0;
            if (ls > label) { label = ls; if (name == 0) variant = i; }
            if (cmd == 0 && v.Command.Contains(t, StringComparison.OrdinalIgnoreCase))
            {
                cmd = 10;
                if (name == 0 && label == 0) variant = i;
            }
        }
        int note = it.Cmd.Note.Contains(t, StringComparison.OrdinalIgnoreCase) ? 15 : 0;
        return Math.Max(Math.Max(name, label), Math.Max(note, cmd));
    }

    private void Refilter()
    {
        var terms = SearchBox.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        Placeholder.Visibility = SearchBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        List<ItemVM> rows;
        if (terms.Length == 0)
        {
            rows = _all.OrderByDescending(Recency, StringComparer.Ordinal)
                       .ThenByDescending(Uses)
                       .ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase)
                       .ToList();
        }
        else
        {
            rows = new List<ItemVM>();
            foreach (var it in _all)
            {
                int total = 0;
                int? pick = null;
                bool ok = true;
                foreach (var t in terms)
                {
                    var s = TermScore(it, t, out var v);
                    if (s == 0) { ok = false; break; }
                    total += s;
                    if (v is not null) pick = v;
                }
                if (!ok) continue;
                it.Score = total;
                if (pick is { } p) it.Active = p; // «self wget» — сразу вариант wget
                rows.Add(it);
            }
            rows = rows.OrderByDescending(i => i.Score)
                       .ThenByDescending(Recency, StringComparer.Ordinal)
                       .ThenByDescending(Uses)
                       .ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase)
                       .ToList();
        }
        for (int i = 0; i < rows.Count; i++) rows[i].Num = i < 9 ? (i + 1).ToString() : "";

        List.ItemsSource = null; // Num не уведомляет — пересобираем строки
        List.ItemsSource = rows;
        if (rows.Count > 0) List.SelectedIndex = 0;

        if (_all.Count == 0)
        {
            Empty.Text = "Команд пока нет. Скопируй команду со ссылкой (например из гиста) и нажми Ctrl+N — имя возьмётся из файла.";
            Empty.Visibility = Visibility.Visible;
        }
        else if (rows.Count == 0)
        {
            Empty.Text = "Ничего не найдено. Ctrl+N — новая команда, F2 — редактор.";
            Empty.Visibility = Visibility.Visible;
        }
        else Empty.Visibility = Visibility.Collapsed;
        List.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdatePreview();
    }

    private void Search_Changed(object sender, TextChangedEventArgs e) => Refilter();

    private ItemVM? Current => List.SelectedItem as ItemVM;

    private void UpdatePreview()
    {
        if (Current is { } it)
        {
            Preview.Text = (it.Vars.Count > 1 ? $"[{it.Vars[it.Active].Label}]  " : "") + Normalize(it.Command).Trim('\n');
            PreviewBox.Visibility = Visibility.Visible;
        }
        else PreviewBox.Visibility = Visibility.Collapsed;
    }

    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdatePreview();
        if (Current is { } it) List.ScrollIntoView(it);
        // печатать можно всегда — фокус держим в поиске
        if (!SearchBox.IsKeyboardFocused) Dispatcher.InvokeAsync(() => SearchBox.Focus());
    }

    private void List_DoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && ItemsControl.ContainerFromElement(List, d) is ListBoxItem)
            Finish(QuickAction.Run);
    }

    private void Chip_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not ChipVM c) return;
        e.Handled = true;
        c.Owner.Active = c.Index;
        List.SelectedItem = c.Owner;
        // клик по варианту = сразу выполнить (Shift — только вставить)
        Finish(Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? QuickAction.Insert : QuickAction.Run);
    }

    // ── Действия ──

    private void Move(int delta)
    {
        if (List.Items.Count == 0) return;
        List.SelectedIndex = Math.Clamp(List.SelectedIndex + delta, 0, List.Items.Count - 1);
    }

    private void Variant(int delta)
    {
        if (Current is not { } it || it.Vars.Count <= 1) return;
        it.Active = (it.Active + delta + it.Vars.Count) % it.Vars.Count;
        UpdatePreview();
    }

    private void Finish(QuickAction action)
    {
        if (action is QuickAction.Run or QuickAction.Insert)
        {
            if (Current is not { } it) { if (_all.Count == 0) Finish(QuickAction.New); return; }
            var text = Normalize(it.Command).Trim('\n');
            if (text.Trim().Length == 0) return;
            Text = text;
            EntryId = it.Cmd.Id;
            GitUsage.Touch(it.Cmd.Id, it.Active);
        }
        else if (action == QuickAction.Edit) EntryId = Current?.Cmd.Id;
        Chosen = action;
        _closing = true;
        DialogResult = true;
    }

    private void CopyAndClose()
    {
        if (Current is not { } it) return;
        try
        {
            Clipboard.SetText(Normalize(it.Command).Trim('\n'));
            GitUsage.Touch(it.Cmd.Id, it.Active);
        }
        catch { }
        _closing = true;
        Close();
    }

    private void OnKeys(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key; // с Alt WPF отдаёт Key.System
        var m = Keyboard.Modifiers;
        bool none = m == ModifierKeys.None;

        // тот же хоткей ещё раз — закрыть
        if (_toggle is { } g && Hotkeys.CodeOf(key) is { } code && g.Code == code &&
            g.Ctrl == m.HasFlag(ModifierKeys.Control) && g.Shift == m.HasFlag(ModifierKeys.Shift) &&
            g.Alt == m.HasFlag(ModifierKeys.Alt))
        {
            e.Handled = true;
            _closing = true;
            Close();
            return;
        }

        switch (key)
        {
            case Key.Escape:
                _closing = true;
                Close();
                break;
            case Key.Down: Move(1); break;
            case Key.Up: Move(-1); break;
            case Key.PageDown: Move(5); break;
            case Key.PageUp: Move(-5); break;
            case Key.Tab when none || m == ModifierKeys.Shift:
                Variant(m == ModifierKeys.Shift ? -1 : 1);
                break;
            case Key.Right when none && SearchBox.Text.Length == 0:
                Variant(1);
                break;
            case Key.Left when none && SearchBox.Text.Length == 0:
                Variant(-1);
                break;
            case Key.Enter when none:
                Finish(QuickAction.Run);
                break;
            case Key.Enter when m == ModifierKeys.Shift:
                Finish(QuickAction.Insert);
                break;
            case Key.Enter when m == ModifierKeys.Control:
                CopyAndClose();
                break;
            case Key.C when m == ModifierKeys.Control && SearchBox.SelectionLength == 0:
                CopyAndClose();
                break;
            case Key.F2 when none:
            case Key.E when m == ModifierKeys.Control:
                Finish(QuickAction.Edit);
                break;
            case Key.N when m == ModifierKeys.Control:
                Finish(QuickAction.New);
                break;
            case >= Key.D1 and <= Key.D9 when m == ModifierKeys.Alt || (none && SearchBox.Text.Length == 0):
                PickAndRun(key - Key.D1);
                break;
            case >= Key.NumPad1 and <= Key.NumPad9 when m == ModifierKeys.Alt || (none && SearchBox.Text.Length == 0):
                PickAndRun(key - Key.NumPad1);
                break;
            default:
                return; // остальное — в поиск
        }
        e.Handled = true;
    }

    private void PickAndRun(int index)
    {
        if (index < 0 || index >= List.Items.Count) return;
        List.SelectedIndex = index;
        Finish(QuickAction.Run);
    }
}
