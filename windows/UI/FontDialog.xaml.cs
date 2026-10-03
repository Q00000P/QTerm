using System.Windows;
using System.Windows.Media;
using QTermWin.Security;

namespace QTermWin.UI;

/// <summary>Шрифт под себя, с ЖИВЫМ применением: крутишь — видишь сразу
/// (устал я угадывать вкус итерациями поставок).</summary>
public partial class FontDialog : Window
{
    private readonly Action<int> _applyTermSize;
    private readonly Action<int> _applyScrollback;
    private bool _ready;

    public FontDialog(Action<int> applyTermSize, Action<int> applyScrollback)
    {
        InitializeComponent();
        _applyTermSize = applyTermSize;
        _applyScrollback = applyScrollback;
        ScrollbackBox.Text = (AppSettings.Load().ScrollbackLines ?? 20000).ToString();

        var st = AppSettings.Load();
        var fams = Fonts.SystemFontFamilies
            .Select(f => f.Source)
            .OrderBy(n => n, StringComparer.OrdinalIgnoreCase)
            .ToList();
        FamilyBox.ItemsSource = fams;
        FamilyBox.SelectedItem =
            fams.Contains(st.UiFontFamily ?? "") ? st.UiFontFamily :
            fams.Contains("Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI";

        var sizes = new[] { 12.0, 12.5, 13, 13.5, 14, 14.5, 15, 16, 17, 18 };
        SizeBox.ItemsSource = sizes;
        SizeBox.SelectedItem = sizes.Contains(st.UiFontSize ?? 14) ? st.UiFontSize ?? 14 : 14.0;

        var tsizes = Enumerable.Range(11, 10).ToArray(); // 11..20
        TermSizeBox.ItemsSource = tsizes;
        TermSizeBox.SelectedItem = st.TermFontSize is { } t && tsizes.Contains(t) ? t : 14;

        _ready = true;
    }

    private void Live_Changed(object sender, RoutedEventArgs e)
    {
        if (!_ready) return;
        var fam = FamilyBox.SelectedItem as string ?? "Segoe UI";
        var size = SizeBox.SelectedItem is double d ? d : 14;
        var ff = new FontFamily(fam + ", Segoe UI");
        Preview.FontFamily = ff;
        Preview.FontSize = size;
        // Живьём на все открытые окна
        foreach (Window w in Application.Current.Windows)
        {
            w.FontFamily = ff;
            w.FontSize = size;
        }
        if (TermSizeBox.SelectedItem is int ts) _applyTermSize(ts);
    }

    private void Reset_Click(object sender, RoutedEventArgs e)
    {
        _ready = false;
        FamilyBox.SelectedItem = (FamilyBox.ItemsSource as List<string>)!
            .Contains("Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI";
        SizeBox.SelectedItem = 14.0;
        TermSizeBox.SelectedItem = 14;
        _ready = true;
        Live_Changed(sender, e);
    }

    public static int ClampScrollback(int n) => Math.Clamp(n, 50, 1_000_000);

    private void Scrollback_Apply(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(ScrollbackBox.Text.Trim().Replace(" ", ""), out var n))
        {
            Preview.Text = "Строк истории — целое число";
            return;
        }
        n = ClampScrollback(n);
        ScrollbackBox.Text = n.ToString();
        var st = AppSettings.Load();
        st.ScrollbackLines = n;
        st.Save();
        _applyScrollback(n);
        Preview.Text = $"История: {n:N0} строк (применено ко всем терминалам)";
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        var st = AppSettings.Load();
        st.UiFontFamily = FamilyBox.SelectedItem as string;
        st.UiFontSize = SizeBox.SelectedItem as double?;
        st.TermFontSize = TermSizeBox.SelectedItem as int?;
        st.Save();
        Close();
    }
}
