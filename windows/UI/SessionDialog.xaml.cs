using System.Windows;
using System.Windows.Controls;
using QTermWin.Models;
using QTermWin.Vault;
using Session = QTermWin.Models.Session;

namespace QTermWin.UI;

/// <summary>
/// Создание/правка ноды. Канон синка соблюдён: updatedAt = NowIso() при
/// сохранении — мак/андроид получат правку через merge, не потеряв свою.
/// </summary>
public partial class SessionDialog : Window
{
    private readonly VaultRepo _repo;
    private readonly Session? _existing;
    private readonly List<SSHKey> _keys;

    private SessionDialog(VaultRepo repo, Session? existing)
    {
        InitializeComponent();
        _repo = repo;
        _existing = existing;
        _keys = repo.Data.SshKeys?.Where(k => k.Deleted != true)
            .OrderBy(k => k.Name, StringComparer.OrdinalIgnoreCase).ToList() ?? new();

        KeyCombo.Items.Add(new ComboBoxItem { Content = "(не назначен)" });
        foreach (var k in _keys)
            KeyCombo.Items.Add(new ComboBoxItem { Content = k.Name, Tag = k.Id });
        // последний пункт — вставить ключ текстом из буфера (сохранится в вейлт)
        KeyCombo.Items.Add(new ComboBoxItem { Content = "＋ Вставить ключ из буфера…", Tag = PasteTag, FontStyle = FontStyles.Italic });
        KeyCombo.SelectedIndex = 0; // ничего не назначаем сами

        if (existing is null)
        {
            Title = "Новая нода";
            AuthCombo.SelectedIndex = 0;
        }
        else
        {
            Title = "Нода: " + existing.Name;
            NameBox.Text = existing.Name;
            HostBox.Text = existing.Host;
            PortBox.Text = existing.Port.ToString();
            UserBox.Text = existing.Username;
            TermPathBox.Text = existing.Extra.GetValueOrDefault("termPath", "");
            SftpPathBox.Text = existing.Extra.GetValueOrDefault("sftpPath", "");
            AuthCombo.SelectedIndex = existing.AuthMethod switch
            {
                AuthMethod.privateKey => 1,
                AuthMethod.agent => 2,
                _ => 0,
            };
            if (existing.KeyID is { } kid)
            {
                var idx = _keys.FindIndex(k => k.Id == kid);
                if (idx >= 0) KeyCombo.SelectedIndex = idx + 1; // +1: «(не назначен)»
            }
        }
        UpdateAuthVisibility();
    }

    private void AuthCombo_Changed(object sender, SelectionChangedEventArgs e) => UpdateAuthVisibility();

    private const string PasteTag = "paste";
    private int _lastKeyIndex;

    /// <summary>«＋ Вставить ключ из буфера…» → окно «имя + ключ», новый ключ сразу выбран.</summary>
    private void KeyCombo_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (KeyCombo.SelectedItem is not ComboBoxItem { Tag: PasteTag })
        {
            _lastKeyIndex = KeyCombo.SelectedIndex;
            return;
        }
        var back = _lastKeyIndex;
        var nodeName = NameBox.Text.Trim();
        var key = KeyPasteDialog.Show(this, _repo, nodeName.Length > 0 ? nodeName + "-key" : "");
        if (key is null)
        {
            KeyCombo.SelectedIndex = back;
            return;
        }
        var idx = _keys.FindIndex(k => k.Id == key.Id);
        if (idx < 0)
        {
            _keys.Add(key);
            idx = _keys.Count - 1;
            KeyCombo.Items.Insert(idx + 1, new ComboBoxItem { Content = key.Name, Tag = key.Id }); // перед «＋ Вставить…»
        }
        KeyCombo.SelectedIndex = idx + 1;
    }

    private void UpdateAuthVisibility()
    {
        if (KeyCombo is null) return; // до InitializeComponent-достройки
        var isKey = AuthCombo.SelectedIndex == 1;
        var isPw = AuthCombo.SelectedIndex == 0;
        KeyLabel.Visibility = KeyCombo.Visibility = isKey ? Visibility.Visible : Visibility.Collapsed;
        PwLabel.Visibility = PwBox.Visibility = isPw ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>true = сохранено.</summary>
    public static bool Edit(Window owner, VaultRepo repo, Session? existing)
    {
        var d = new SessionDialog(repo, existing) { Owner = owner };
        return d.ShowDialog() == true;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        var name = NameBox.Text.Trim();
        var host = HostBox.Text.Trim();
        var user = UserBox.Text.Trim();
        if (name.Length == 0 || host.Length == 0 || user.Length == 0)
        {
            MessageBox.Show(this, "Имя, хост и пользователь обязательны.", "QTerm",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (!int.TryParse(PortBox.Text.Trim(), out var port) || port is < 1 or > 65535)
        {
            MessageBox.Show(this, "Порт — число 1–65535.", "QTerm",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        var auth = AuthCombo.SelectedIndex switch
        {
            1 => AuthMethod.privateKey,
            2 => AuthMethod.agent,
            _ => AuthMethod.password,
        };
        Guid? keyId = auth == AuthMethod.privateKey && KeyCombo.SelectedItem is ComboBoxItem { Tag: Guid g }
            ? g : null;
        // Ключ не назначен — допустимо: при коннекте нода уйдёт на пароль

        var s = _existing ?? new Session();
        s.Name = name;
        s.Host = host;
        s.Port = port;
        s.Username = user;
        s.AuthMethod = auth;
        s.KeyID = auth == AuthMethod.privateKey ? keyId : null; // комбо — истина
        var tp = TermPathBox.Text.Trim();
        if (tp.Length > 0) s.Extra["termPath"] = tp;
        else s.Extra.Remove("termPath");
        var sp = SftpPathBox.Text.Trim();
        if (sp.Length > 0) s.Extra["sftpPath"] = sp;
        else s.Extra.Remove("sftpPath");
        s.UpdatedAt = QtJson.NowIso();

        if (_existing is null) _repo.Data.Sessions.Add(s);

        if (auth == AuthMethod.password && PwBox.Password.Length > 0)
        {
            _repo.Data.Secrets ??= new();
            _repo.Data.Secrets[$"{s.Id.ToString("D").ToUpperInvariant()}.password"] = PwBox.Password;
        }

        _repo.Persist();
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
