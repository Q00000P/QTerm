using System.IO;
using System.Windows;

namespace QTermWin.UI;

public partial class AboutWindow : Window
{
    public AboutWindow()
    {
        InitializeComponent();
        var mtime = "";
        try
        {
            if (Environment.ProcessPath is { } p)
                mtime = " · сборка " + File.GetLastWriteTime(p).ToString("dd.MM.yyyy HH:mm");
        }
        catch { }
        VerText.Text = $"Версия {WaveMarker.Version} (линейка 3.0: mac · Android · Windows){mtime}";
    }

    private void Close_Click(object sender, RoutedEventArgs e) => Close();
}
