using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>План изменений с галками: смотришь, снимаешь лишнее, копируешь, применяешь.</summary>
public partial class XuiPlanWindow : Window
{
    private readonly List<PlanItem> _items;

    public XuiPlanWindow(string title, string summary, string footer, List<PlanItem> items, bool forceApply = false,
        string resultHeader = "Станет", string fromHeader = "Сейчас")
    {
        InitializeComponent();
        ResultCol.Header = resultHeader;
        FromCol.Header = fromHeader;
        Title = title;
        Summary.Text = summary;
        Footer.Text = footer;
        _items = items;
        List.ItemsSource = items;
        foreach (var i in items) i.PropertyChanged += OnItemChanged;
        _forceApply = forceApply;
        UpdateCounter();
    }

    private readonly bool _forceApply;   // новая нода: регистрация будет и без отмеченных пунктов

    private void OnItemChanged(object? sender, PropertyChangedEventArgs e) => UpdateCounter();

    private void UpdateCounter()
    {
        var sel = _items.Count(i => i.Selectable);
        var on = _items.Count(i => i.Selectable && i.Apply);
        Counter.Text = $"отмечено {on} из {sel}" + (_items.Count > sel ? $" · ещё {_items.Count - sel} без действий" : "");
        ApplyBtn.IsEnabled = on > 0 || _forceApply;
    }

    private bool Visible(PlanItem i)
    {
        var f = FilterBox.Text.Trim();
        if (f.Length == 0) return true;
        return f.Split(' ', StringSplitOptions.RemoveEmptyEntries).All(w =>
            i.Scope.Contains(w, StringComparison.OrdinalIgnoreCase) || i.Result.Contains(w, StringComparison.OrdinalIgnoreCase) ||
            i.From.Contains(w, StringComparison.OrdinalIgnoreCase) || i.KindText.Contains(w, StringComparison.OrdinalIgnoreCase) ||
            i.Note.Contains(w, StringComparison.OrdinalIgnoreCase));
    }

    private void Filter_Changed(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        System.Windows.Data.CollectionViewSource.GetDefaultView(List.ItemsSource).Filter = o => o is PlanItem i && Visible(i);
    }

    private void All_Click(object sender, RoutedEventArgs e)
    {
        foreach (var i in _items.Where(i => i.Selectable && Visible(i))) i.Apply = true;
    }

    private void None_Click(object sender, RoutedEventArgs e)
    {
        foreach (var i in _items.Where(i => i.Selectable && Visible(i))) i.Apply = false;
    }

    private string Text(IEnumerable<PlanItem> rows) =>
        Summary.Text + "\n\n" + string.Join("\n", rows.Select(r => r.AsText));

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        try { Clipboard.SetText(Text(_items)); Counter.Text = "✓ план скопирован"; }
        catch { /* буфер занят */ }
    }

    private void List_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.OriginalSource is System.Windows.Controls.TextBox) return; // в поле — обычное копирование/ввод
        var rows = List.SelectedItems.OfType<PlanItem>().ToList();
        if (e.Key == Key.C && Keyboard.Modifiers.HasFlag(ModifierKeys.Control) && rows.Count > 0)
        {
            try { Clipboard.SetText(string.Join("\n", rows.Select(r => r.AsText))); } catch { }
            e.Handled = true;
        }
        else if (e.Key == Key.Space && rows.Count > 0)
        {
            var target = !rows.All(r => r.Apply);
            foreach (var r in rows.Where(r => r.Selectable)) r.Apply = target;
            e.Handled = true;
        }
    }

    private void Apply_Click(object sender, RoutedEventArgs e) => DialogResult = true;
    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}

/// <summary>Тёмные диалоги вместо белого MessageBox: текст выделяется и копируется.</summary>
public static class XuiDialog
{
    /// <returns>индекс нажатой кнопки или -1 (закрыто крестиком / Esc)</returns>
    public static int Show(Window owner, string text, string title, params string[] buttons)
    {
        int result = -1;
        var w = new Window
        {
            Title = title, Owner = owner, Width = 520, SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ShowInTaskbar = false,
        };
        w.SetResourceReference(Window.BackgroundProperty, "BgBrush");
        w.SetResourceReference(Window.ForegroundProperty, "FgBrush");
        var root = new System.Windows.Controls.StackPanel { Margin = new Thickness(18) };
        var box = new System.Windows.Controls.TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, FontSize = 14.5,
            BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent,
            MaxHeight = 420, VerticalScrollBarVisibility = System.Windows.Controls.ScrollBarVisibility.Auto,
        };
        box.SetResourceReference(System.Windows.Controls.Control.ForegroundProperty, "FgBrush");
        root.Children.Add(box);
        var row = new System.Windows.Controls.StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0),
        };
        if (buttons.Length == 0) buttons = new[] { "OK" };
        for (int i = 0; i < buttons.Length; i++)
        {
            var idx = i;
            var b = new System.Windows.Controls.Button
            {
                Content = buttons[i], MinWidth = 100, Margin = new Thickness(8, 0, 0, 0),
                IsDefault = i == 0, IsCancel = i == buttons.Length - 1 && buttons.Length > 1,
            };
            b.Click += (_, _) => { result = idx; w.Close(); };
            row.Children.Add(b);
        }
        root.Children.Add(row);
        w.Content = root;
        w.ShowDialog();
        return result;
    }

    public static void Info(Window owner, string text, string title = "Ноды 3x-ui") => Show(owner, text, title, "OK");

    public static bool Confirm(Window owner, string text, string title, string yes = "Да") =>
        Show(owner, text, title, yes, "Отмена") == 0;

    /// <summary>Выбор строки из списка (версии ядра/панели). Можно вписать свою. null — отмена.</summary>
    public static string? Pick(Window owner, string text, string title, IList<string> items, string? selected = null, string ok = "Выбрать")
    {
        string? result = null;
        var w = new Window
        {
            Title = title, Owner = owner, Width = 460, Height = 520, MinHeight = 320,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        w.SetResourceReference(Window.BackgroundProperty, "BgBrush");
        w.SetResourceReference(Window.ForegroundProperty, "FgBrush");
        var root = new System.Windows.Controls.DockPanel { Margin = new Thickness(16) };
        var caption = new System.Windows.Controls.TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent, Margin = new Thickness(0, 0, 0, 8),
        };
        caption.SetResourceReference(System.Windows.Controls.Control.ForegroundProperty, "FgBrush");
        System.Windows.Controls.DockPanel.SetDock(caption, System.Windows.Controls.Dock.Top);
        root.Children.Add(caption);
        var input = new System.Windows.Controls.TextBox { Padding = new Thickness(6), Margin = new Thickness(0, 0, 0, 8), Text = selected ?? "" };
        System.Windows.Controls.DockPanel.SetDock(input, System.Windows.Controls.Dock.Top);
        root.Children.Add(input);
        var row = new System.Windows.Controls.StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0),
        };
        System.Windows.Controls.DockPanel.SetDock(row, System.Windows.Controls.Dock.Bottom);
        var okBtn = new System.Windows.Controls.Button { Content = ok, MinWidth = 100, IsDefault = true };
        var cancel = new System.Windows.Controls.Button { Content = "Отмена", MinWidth = 100, Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        okBtn.Click += (_, _) => { if (input.Text.Trim().Length > 0) { result = input.Text.Trim(); w.Close(); } };
        cancel.Click += (_, _) => w.Close();
        row.Children.Add(okBtn);
        row.Children.Add(cancel);
        root.Children.Add(row);
        var list = new System.Windows.Controls.ListBox { ItemsSource = items };
        list.SetResourceReference(System.Windows.Controls.Control.BackgroundProperty, "PanelBrush");
        list.SetResourceReference(System.Windows.Controls.Control.ForegroundProperty, "FgBrush");
        if (selected is not null && items.Contains(selected)) list.SelectedItem = selected;
        list.SelectionChanged += (_, _) => { if (list.SelectedItem is string s) input.Text = s; };
        list.MouseDoubleClick += (_, _) => { if (list.SelectedItem is string s) { result = s; w.Close(); } };
        root.Children.Add(list);
        w.Content = root;
        w.ShowDialog();
        return result;
    }
}
