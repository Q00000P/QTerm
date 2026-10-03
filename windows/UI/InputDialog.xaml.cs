using System.Windows;

namespace QTermWin.UI;

public partial class InputDialog : Window
{
    private InputDialog(string caption, string initial)
    {
        InitializeComponent();
        Caption.Text = caption;
        Box.Text = initial;
        Loaded += (_, _) => { Box.Focus(); Box.SelectAll(); };
    }

    public static string? Ask(Window owner, string caption, string initial = "")
    {
        var d = new InputDialog(caption, initial) { Owner = owner };
        return d.ShowDialog() == true && !string.IsNullOrWhiteSpace(d.Box.Text)
            ? d.Box.Text.Trim() : null;
    }

    private void Ok_Click(object sender, RoutedEventArgs e) => DialogResult = true;
    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
