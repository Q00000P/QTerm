using System.Windows;
using QTermWin.Files;

namespace QTermWin.UI;

/// <summary>Свойства файла (мак-канон chmod-шита): инфо + правка прав октально.</summary>
public partial class FilePropsDialog : Window
{
    private readonly FileService _svc;
    private readonly string _remote;

    /// <summary>true = права меняли (перечитать листинг).</summary>
    public bool Changed { get; private set; }

    public FilePropsDialog(FileService svc, RemoteEntry en, string remote)
    {
        InitializeComponent();
        _svc = svc;
        _remote = remote;
        NameT.Text = en.Name;
        PathT.Text = remote;
        TypeT.Text = en.IsDir ? "Папка" : "Файл";
        SizeT.Text = en.IsDir ? "—" : $"{en.Size:N0} байт";
        ModT.Text = en.Modified;
        OwnerT.Text = en.Perms.Length > 0 ? en.Owner : "—";
        PermsT.Text = en.Perms.Length > 0 ? en.Perms : "(неизвестны)";
        OctalBox.Text = en.Perms.Length == 9 ? ToOctal(en.Perms) : "";
    }

    private static string ToOctal(string p)
    {
        int Trio(int i) => (p[i] != '-' ? 4 : 0) | (p[i + 1] != '-' ? 2 : 0)
            | (p[i + 2] is 'x' or 's' or 't' ? 1 : 0);
        return $"{Trio(0)}{Trio(3)}{Trio(6)}";
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();

    private void Apply_Click(object sender, RoutedEventArgs e)
    {
        var mode = OctalBox.Text.Trim();
        if (!System.Text.RegularExpressions.Regex.IsMatch(mode, "^[0-7]{3,4}$"))
        {
            MessageBox.Show(this, "Права — 3-4 октальные цифры (например 644).", "QTerm",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        ApplyBtn.IsEnabled = false;
        Task.Run(() =>
        {
            try
            {
                _svc.ChmodL(_remote, mode);
                Dispatcher.Invoke(() => { Changed = true; Close(); });
            }
            catch (Exception ex)
            {
                Dispatcher.Invoke(() =>
                {
                    ApplyBtn.IsEnabled = true;
                    MessageBox.Show(this, "chmod: " + ex.Message, "QTerm",
                        MessageBoxButton.OK, MessageBoxImage.Error);
                });
            }
        });
    }
}
