using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using QTermWin.Sync;

namespace QTermWin.UI;

public partial class SyncWindow : Window
{
    private readonly SyncEngine _engine;
    private SyncConfig _cfg;

    /// <summary>Сводка по разделам вейлта: что уедет на другие устройства.</summary>
    private static string Contents(Vault.VaultRepo repo)
    {
        var d = repo.Data;
        var xui = new Xui.XuiStore(repo);
        var panels = xui.Panels();
        var names = xui.Names();
        return string.Join("\n", new[]
        {
            $"Ноды SSH: {repo.VisibleSessions.Count()} · ключи: {d.SshKeys?.Count(k => k.Deleted != true) ?? 0} · сниппеты: {d.Snippets?.Count(s => s.Deleted != true) ?? 0} · команды Git: {repo.VisibleGitCommands.Count()}",
            $"Журнал команд и словарь",
            $"Ноды 3x-ui: панелей {panels.Count} (главных {panels.Count(p => p.IsMaster)}) — адреса и API-токены; список имён клиентов ({names.Lines.Count})",
            "Не синхронизируются: бэкапы баз 3x-ui (%APPDATA%\\QTerm\\xui-backup), настройки окна и горячие клавиши",
        });
    }

    public SyncWindow(SyncEngine engine)
    {
        InitializeComponent();
        _engine = engine;
        _cfg = engine.Config;

        BackendCombo.SelectedIndex = _cfg.IsGDrive || _cfg.Backend is null ? 0 : 1;
        if (_cfg.Backend is null) BackendCombo.SelectedIndex = _cfg.GdConnected ? 0 : 1;
        GdFolderBox.Text = string.IsNullOrEmpty(_cfg.GdFolder) ? "QTerm" : _cfg.GdFolder;
        UrlBox.Text = _cfg.Url;
        LoginBox.Text = _cfg.Login;
        DavPwBox.Password = _cfg.WebdavPassword;
        EncPwBox.Password = _cfg.EncPassword;
        EnabledBox.IsChecked = _cfg.Enabled;
        UpdatePanels();
        UpdateGdStatus();
        ContentsText.Text = Contents(engine.Repo);

        _engine.Status += OnStatus;
        Closed += (_, _) => _engine.Status -= OnStatus;
    }

    private void OnStatus(string text, bool err) => Dispatcher.Invoke(() =>
    {
        StatusLabel.Text = text;
        StatusLabel.Foreground = err ? Brushes.IndianRed : Brushes.LimeGreen;
    });

    private void Backend_Changed(object sender, SelectionChangedEventArgs e) => UpdatePanels();

    private void UpdatePanels()
    {
        if (GDrivePanel is null) return;
        var gd = BackendCombo.SelectedIndex == 0;
        GDrivePanel.Visibility = gd ? Visibility.Visible : Visibility.Collapsed;
        WebDavPanel.Visibility = gd ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdateGdStatus()
    {
        GdStatus.Text = _cfg.GdConnected ? "Подключён ✓" : "Не подключён";
        GdStatus.Foreground = _cfg.GdConnected ? Brushes.LimeGreen : Brushes.IndianRed;
        GoogleButton.Content = _cfg.GdConnected ? "Выйти" : "Войти в Google";
    }

    private async void Google_Click(object sender, RoutedEventArgs e)
    {
        if (_cfg.GdConnected)
        {
            _cfg.GdRefreshToken = null;
            UpdateGdStatus();
            return;
        }
        GoogleButton.IsEnabled = false;
        StatusLabel.Text = "Жду подтверждения в браузере…";
        StatusLabel.Foreground = Brushes.Gray;
        try
        {
            _cfg.GdRefreshToken = await GoogleOAuth.SignInAsync();
            StatusLabel.Text = "Google подключён";
            StatusLabel.Foreground = Brushes.LimeGreen;
        }
        catch (Exception ex)
        {
            StatusLabel.Text = "Вход в Google: " + ex.Message;
            StatusLabel.Foreground = Brushes.IndianRed;
        }
        finally
        {
            GoogleButton.IsEnabled = true;
            UpdateGdStatus();
        }
    }

    private SyncConfig Collect()
    {
        _cfg.Backend = BackendCombo.SelectedIndex == 0 ? "gdrive" : "webdav";
        _cfg.GdFolder = GdFolderBox.Text.Trim();
        _cfg.Url = UrlBox.Text.Trim();
        _cfg.Login = LoginBox.Text.Trim();
        _cfg.WebdavPassword = DavPwBox.Password;
        _cfg.EncPassword = EncPwBox.Password;
        _cfg.Enabled = EnabledBox.IsChecked == true;
        return _cfg;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        _engine.Config = Collect();
        if (_cfg.Enabled) _engine.SchedulePush();
        Close();
    }

    private void SyncNow_Click(object sender, RoutedEventArgs e)
    {
        _engine.Config = Collect();
        _ = Task.Run(_engine.SyncNowAsync);
    }
}
