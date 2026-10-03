using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace QTermWin.UI;

/// <summary>Настройка горячих клавиш всех функций QTerm (локально на устройстве).</summary>
public partial class HotkeysWindow : Window
{
    private readonly Dictionary<string, Gesture?> _map;
    private readonly Dictionary<string, Button> _btns = new();
    private string? _capturing;

    public HotkeysWindow()
    {
        InitializeComponent();
        _map = Hotkeys.Load();
        BuildRows();
        PreviewKeyDown += OnKeys;
    }

    private void BuildRows()
    {
        Rows.Children.Clear();
        _btns.Clear();
        foreach (var a in Hotkeys.Actions)
        {
            var row = new Grid { Margin = new Thickness(4, 2, 4, 2) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var title = new TextBlock { Text = a.Title, VerticalAlignment = VerticalAlignment.Center };
            title.SetResourceReference(TextBlock.ForegroundProperty, "FgBrush");
            row.Children.Add(title);

            var id = a.Id;
            var btn = new Button { Padding = new Thickness(10, 4, 10, 4), Focusable = false };
            btn.Click += (s, e) => StartCapture(id);
            Grid.SetColumn(btn, 1);
            row.Children.Add(btn);
            _btns[id] = btn;

            var def = new Button
            {
                Content = "↺", Margin = new Thickness(6, 0, 0, 0), MinWidth = 32, Focusable = false,
                ToolTip = "По умолчанию: " + (Gesture.Parse(a.Default)?.Display ?? "не назначено"),
            };
            def.Click += (s, e) => { StopCapture(); Assign(id, Gesture.Parse(Hotkeys.Actions.First(x => x.Id == id).Default)); };
            Grid.SetColumn(def, 2);
            row.Children.Add(def);

            var clr = new Button
            {
                Content = "✕", Margin = new Thickness(4, 0, 0, 0), MinWidth = 32, Focusable = false,
                ToolTip = "Снять сочетание",
            };
            clr.Click += (s, e) => { StopCapture(); Assign(id, null); };
            Grid.SetColumn(clr, 3);
            row.Children.Add(clr);

            Rows.Children.Add(row);
        }
        RefreshButtons();
    }

    private void RefreshButtons()
    {
        foreach (var (id, btn) in _btns)
        {
            if (id == _capturing)
            {
                btn.Content = "Нажми сочетание…";
                btn.SetResourceReference(BackgroundProperty, "SelBrush");
            }
            else
            {
                btn.Content = _map.GetValueOrDefault(id)?.Display ?? "—";
                btn.ClearValue(BackgroundProperty);
            }
        }
    }

    private void StartCapture(string id)
    {
        _capturing = _capturing == id ? null : id;
        Status.Text = _capturing is null ? "" : $"«{Hotkeys.Title(id)}»: нажми сочетание (Esc — отмена, Backspace — снять)";
        RefreshButtons();
        Keyboard.Focus(this);
    }

    private void StopCapture()
    {
        _capturing = null;
        RefreshButtons();
    }

    /// <summary>Назначить; то же сочетание у другой функции — снимаем там (без дублей).</summary>
    private void Assign(string id, Gesture? g)
    {
        var msg = "";
        if (g is not null)
        {
            foreach (var other in _map.Where(kv => kv.Key != id && kv.Value == g).Select(kv => kv.Key).ToList())
            {
                _map[other] = null;
                msg += $"Снято с «{Hotkeys.Title(other)}». ";
            }
            if (Hotkeys.StealsFromTerminal(g))
                msg += $"Внимание: {g.Display} больше не дойдёт до шелла/редактора в терминале.";
        }
        _map[id] = g;
        Status.Text = msg.Length > 0 ? msg : $"«{Hotkeys.Title(id)}»: {g?.Display ?? "не назначено"}";
        RefreshButtons();
    }

    private void OnKeys(object sender, KeyEventArgs e)
    {
        if (_capturing is not { } id) return;
        e.Handled = true; // в режиме записи клавиши окну не отдаём

        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift
            or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin or Key.ImeProcessed
            or Key.DeadCharProcessed)
            return; // ждём основную клавишу

        var m = Keyboard.Modifiers;
        bool ctrl = m.HasFlag(ModifierKeys.Control), shift = m.HasFlag(ModifierKeys.Shift),
             alt = m.HasFlag(ModifierKeys.Alt);

        if (!ctrl && !alt && !shift && key == Key.Escape)
        {
            StopCapture();
            Status.Text = "Отменено";
            return;
        }
        if (!ctrl && !alt && !shift && key is Key.Back or Key.Delete)
        {
            StopCapture();
            Assign(id, null);
            return;
        }
        if (Hotkeys.CodeOf(key) is not { } code)
        {
            Status.Text = "Эту клавишу назначить нельзя — выбери другую";
            return;
        }
        var g = new Gesture(ctrl, shift, alt, code);
        if (!ctrl && !alt && !g.IsFKey)
        {
            Status.Text = "Нужен Ctrl или Alt (без них клавиша уйдёт в терминал), либо F1…F24";
            return;
        }
        StopCapture();
        Assign(id, g);
    }

    private void Defaults_Click(object sender, RoutedEventArgs e)
    {
        StopCapture();
        foreach (var a in Hotkeys.Actions) _map[a.Id] = Gesture.Parse(a.Default);
        Status.Text = "Всё сброшено к умолчаниям (применится после «Сохранить»)";
        RefreshButtons();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        Hotkeys.Save(_map);
        DialogResult = true;
    }
}
