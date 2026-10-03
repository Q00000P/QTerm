using System.Windows;

namespace QTermWin.UI;

public partial class PasswordDialog : Window
{
    private PasswordDialog(string caption, bool withSave)
    {
        InitializeComponent();
        Caption.Text = caption.EndsWith(':') ? caption : caption + ":";
        if (withSave) SaveBox.Visibility = Visibility.Visible;
        Loaded += (_, _) => Box.Focus();
    }

    public static string? Ask(Window owner, string fileName) =>
        AskEx(owner, $"Пароль для «{fileName}»", withSave: false).Password;

    /// <summary>Диалог с опцией «Сохранить в вейлт». Save валиден при непустом Password.</summary>
    public static (string? Password, bool Save) AskEx(Window owner, string caption, bool withSave)
    {
        var d = new PasswordDialog(caption, withSave) { Owner = owner };
        return d.ShowDialog() == true
            ? (d.Box.Password, withSave && d.SaveBox.IsChecked == true)
            : (null, false);
    }

    private void Ok_Click(object sender, RoutedEventArgs e) => DialogResult = true;
    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
