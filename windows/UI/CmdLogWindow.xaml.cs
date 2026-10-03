using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using QTermWin.Vault;

namespace QTermWin.UI;

/// <summary>Журнал команд + раздел «Словарь» (мак-канон wave4: словарь виден,
/// встроенные серые «скрыть», свои голубые «удалить»).</summary>
public partial class CmdLogWindow : Window
{
    private readonly VaultRepo _repo;
    private bool _dictMode;
    private sealed record Row(string Cmd, string Count, string Last);

    public CmdLogWindow(VaultRepo repo)
    {
        InitializeComponent();
        _repo = repo;
        SetMode(false);
    }

    private void SetMode(bool dict)
    {
        _dictMode = dict;
        var sel = (Brush)FindResource("SelBrush");
        var pan = (Brush)FindResource("Panel2Brush");
        SegLog.Background = dict ? pan : sel;
        SegDict.Background = dict ? sel : pan;
        LogBar.Visibility = dict ? Visibility.Collapsed : Visibility.Visible;
        DictBar.Visibility = dict ? Visibility.Visible : Visibility.Collapsed;
        ColCount.Header = dict ? "Тип" : "×";
        ColLast.Header = dict ? "" : "Последняя";
        Refresh();
    }

    private void Refresh()
    {
        var filter = SearchBox.Text.Trim();
        List<Row> rows;
        if (_dictMode)
        {
            rows = _repo.EffectiveDict()
                .Where(d => filter.Length == 0 || d.Cmd.Contains(filter, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(d => d.Own).ThenBy(d => d.Cmd, StringComparer.Ordinal)
                .Select(d => new Row(d.Cmd, d.Own ? "★ свой" : "встроенный", ""))
                .ToList();
            CountLabel.Text = "";
        }
        else
        {
            rows = _repo.VisibleCmdHistory
                .Where(kv => filter.Length == 0 || kv.Key.Contains(filter, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(kv => kv.Value.LastUsed ?? "", StringComparer.Ordinal)
                .Select(kv => new Row(kv.Key, kv.Value.Count.ToString(),
                    kv.Value.LastUsed is { Length: >= 16 } lu ? lu[..16].Replace("T", " ") : ""))
                .ToList();
            CountLabel.Text = $"Команд: {rows.Count}";
        }
        LogList.ItemsSource = rows;
    }

    private void SegLog_Click(object sender, RoutedEventArgs e) => SetMode(false);
    private void SegDict_Click(object sender, RoutedEventArgs e) => SetMode(true);
    private void Search_Changed(object sender, TextChangedEventArgs e) => Refresh();

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (LogList.SelectedItem is not Row row) return;
        _repo.DeleteCommand(row.Cmd);
        Refresh();
    }

    private void ToDict_Click(object sender, RoutedEventArgs e)
    {
        if (LogList.SelectedItem is not Row row) return;
        _repo.AddDictEntry(row.Cmd);
        SetMode(true); // мгновенный фидбек — показать раздел «Словарь»
    }

    private void Sanitize_Click(object sender, RoutedEventArgs e)
    {
        var n = _repo.SanitizeJournals();
        if (n > 0) _repo.Persist();
        Refresh();
        CountLabel.Text = n > 0 ? $"Вычищено записей: {n}" : "Мусора не найдено";
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "Очистить весь журнал команд? Очистка уедет на мак/андроид.",
                "QTerm", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                MessageBoxResult.No) != MessageBoxResult.Yes) return;
        _repo.ClearCmdHistory();
        Refresh();
    }

    private void DictAdd_Click(object sender, RoutedEventArgs e)
    {
        var cmd = NewDictBox.Text.Trim();
        if (cmd.Length < 2) return;
        _repo.AddDictEntry(cmd);
        NewDictBox.Text = "";
        Refresh();
    }

    private void DictRemove_Click(object sender, RoutedEventArgs e)
    {
        if (LogList.SelectedItem is not Row row) return;
        _repo.RemoveDictEntry(row.Cmd);
        Refresh();
    }
}
