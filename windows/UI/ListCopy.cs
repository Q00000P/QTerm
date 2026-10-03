using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;

namespace QTermWin.UI;

/// <summary>
/// Строки любых таблиц (ListView/GridView) копируются: Ctrl+C и «Копировать» в контекстном меню —
/// выделенные строки, колонки через табуляцию (вставляются в таблицу/текст как есть).
/// </summary>
public static class ListCopy
{
    private static bool _registered;

    public static void Register()
    {
        if (_registered) return;
        _registered = true;
        CommandManager.RegisterClassCommandBinding(typeof(ListView),
            new CommandBinding(ApplicationCommands.Copy, OnCopy, OnCanCopy));
        EventManager.RegisterClassHandler(typeof(ListView), FrameworkElement.LoadedEvent, new RoutedEventHandler(OnLoaded));
    }

    private static void OnCanCopy(object sender, CanExecuteRoutedEventArgs e)
    {
        e.CanExecute = sender is ListView lv && lv.SelectedItems.Count > 0;
        e.Handled = true;
    }

    private static void OnCopy(object sender, ExecutedRoutedEventArgs e)
    {
        if (sender is not ListView lv) return;
        e.Handled = true;
        var text = Text(lv);
        if (text.Length == 0) return;
        try { Clipboard.SetText(text); } catch { /* буфер занят другим процессом */ }
    }

    private static void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (sender is not ListView lv) return;
        lv.ContextMenu ??= new ContextMenu();
        var menu = lv.ContextMenu;
        if (menu.Items.OfType<MenuItem>().Any(m => m.Command == ApplicationCommands.Copy)) return;
        if (menu.Items.Count > 0) menu.Items.Insert(0, new Separator());
        menu.Items.Insert(0, new MenuItem
        {
            Header = "Копировать",
            Command = ApplicationCommands.Copy,
            CommandTarget = lv,
            InputGestureText = "Ctrl+C",
        });
    }

    public static string Text(ListView lv)
    {
        var rows = new List<string>();
        foreach (var item in lv.Items)
            if (lv.SelectedItems.Contains(item)) rows.Add(Row(lv, item));
        return string.Join("\r\n", rows);
    }

    private static string Row(ListView lv, object item)
    {
        if (lv.View is not GridView gv) return Clean(item?.ToString());
        var container = lv.ItemContainerGenerator.ContainerFromItem(item) as ListViewItem;
        var presenter = container is null ? null : Find<GridViewRowPresenter>(container);
        var cells = new List<string>();
        for (var i = 0; i < gv.Columns.Count; i++)
        {
            var col = gv.Columns[i];
            if (col.Header is string h && h.Trim().Length == 0) continue;   // колонка-индикатор «●»
            string? v = null;
            if (col.DisplayMemberBinding is Binding b && b.Path?.Path is { Length: > 0 } path)
                v = Eval(item, path, b);
            else if (presenter is not null && i < VisualTreeHelper.GetChildrenCount(presenter))
                v = Texts(VisualTreeHelper.GetChild(presenter, i));
            cells.Add(Clean(v));
        }
        return string.Join("\t", cells);
    }

    private static string? Eval(object? item, string path, Binding b)
    {
        object? cur = item;
        foreach (var part in path.Split('.'))
        {
            if (cur is null) return null;
            cur = cur.GetType().GetProperty(part)?.GetValue(cur);
        }
        if (b.Converter is not null)
            cur = b.Converter.Convert(cur, typeof(string), b.ConverterParameter, System.Globalization.CultureInfo.CurrentCulture);
        if (!string.IsNullOrEmpty(b.StringFormat) && cur is not null)
            return string.Format(b.StringFormat.Contains('{') ? b.StringFormat : "{0:" + b.StringFormat + "}", cur);
        return cur?.ToString();
    }

    private static string Texts(DependencyObject root)
    {
        var parts = new List<string>();
        void Walk(DependencyObject d)
        {
            switch (d)
            {
                case TextBlock tb when tb.Text.Length > 0: parts.Add(tb.Text); return;
                case TextBox tx when tx.Text.Length > 0: parts.Add(tx.Text); return;
            }
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(d); i++) Walk(VisualTreeHelper.GetChild(d, i));
        }
        Walk(root);
        return string.Join(" ", parts);
    }

    private static T? Find<T>(DependencyObject d) where T : DependencyObject
    {
        if (d is T t) return t;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(d); i++)
            if (Find<T>(VisualTreeHelper.GetChild(d, i)) is { } r) return r;
        return null;
    }

    private static string Clean(string? s) => (s ?? "").Replace('\t', ' ').Replace("\r", "").Replace('\n', ' ');
}
