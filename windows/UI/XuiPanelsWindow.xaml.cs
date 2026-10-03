using System.Windows;
using System.Windows.Controls;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>Сохранённые панели 3x-ui (главные и ноды) с токенами — в вейлте QTerm.</summary>
public partial class XuiPanelsWindow : Window
{
    private readonly XuiStore _store;
    private XuiPanel? _cur;   // null = новая
    private bool _loading;

    private sealed record SshItem(string? Id, string Name);

    public XuiPanelsWindow(XuiStore store)
    {
        InitializeComponent();
        _store = store;
        SshBox.ItemsSource = new[] { new SshItem(null, "Авто (по адресу / IP)") }
            .Concat(store.Sessions().Select(x => new SshItem(x.Id.ToString(), $"{x.Name}  ·  {x.Username}@{x.Host}"))).ToList();
        Reload(null);
        if (List.Items.Count == 0) Blank();
    }

    private void Reload(Guid? select)
    {
        var panels = _store.Panels();
        _loading = true;
        List.ItemsSource = panels;
        List.SelectedItem = panels.FirstOrDefault(p => p.Id == select) ?? panels.FirstOrDefault();
        _loading = false;
        ShowPanel(List.SelectedItem as XuiPanel);
    }

    private void Blank()
    {
        _cur = null;
        NameBox.Text = "";
        RoleBox.SelectedIndex = _store.Panels().Any(p => p.IsMaster) ? 1 : 0;
        LoginBox.Text = "";
        UrlBox.Text = "";
        TokenBox.Password = "";
        PassBox.Password = "";
        TwoFaBox.Text = "";
        TlsBox.SelectedIndex = 0;
        SshBox.SelectedIndex = 0;
        ResultText.Text = "Новая панель";
        NameBox.Focus();
    }

    private void ShowPanel(XuiPanel? p)
    {
        if (p is null) { Blank(); return; }
        _cur = p;
        NameBox.Text = p.Name;
        RoleBox.SelectedIndex = RoleIndex(p.Role);
        LoginBox.Text = p.Login;
        UrlBox.Text = p.Url;
        TokenBox.Password = "";
        PassBox.Password = "";
        TwoFaBox.Text = "";
        TlsBox.SelectedIndex = p.VerifyTls ? 0 : 1;
        SshBox.SelectedItem = SshBox.Items.OfType<SshItem>().FirstOrDefault(i => i.Id is not null &&
            string.Equals(i.Id, p.Ssh, StringComparison.OrdinalIgnoreCase)) ?? SshBox.Items[0];
        ResultText.Text = p.Token.Length > 0 ? (p.IsAwg ? "Пароль сохранён" : "Токен сохранён") : "Не задано";
        if (p.IsXui && !string.IsNullOrEmpty(p.Pass)) ResultText.Text += " · пароль админа сохранён — токен перевыпускается сам";
    }

    private static int RoleIndex(string role) => role switch { "master" => 0, "awg" => 2, "awg1" => 3, _ => 1 };
    private static string RoleOf(int i) => i switch { 0 => "master", 2 => "awg", 3 => "awg1", _ => "node" };

    private void Role_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (LoginPanel is null) return;
        var i = RoleBox.SelectedIndex;
        LoginPanel.Visibility = i <= 2 ? Visibility.Visible : Visibility.Collapsed;
        XuiAuthPanel.Visibility = i <= 1 ? Visibility.Visible : Visibility.Collapsed;
        LoginCap.Text = i == 2
            ? "Логин админа awg-panel (2FA должна быть выключена — иначе панель не пускает по API)"
            : "Логин админа 3x-ui (для выпуска и автоперевыпуска токена)";
        TokenCap.Text = i switch
        {
            2 => "Пароль админа awg-panel. Пусто — оставить сохранённый",
            3 => "Пароль панели (Password из итога установки). Пусто — оставить сохранённый",
            _ => "API-токен (Настройки панели → Учетная запись → API-токены). Пусто — оставить сохранённый",
        };
    }

    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading) ShowPanel(List.SelectedItem as XuiPanel);
    }

    private void FromSelection_Click(object sender, RoutedEventArgs e)
    {
        var text = "";
        try { text = Clipboard.GetText(); } catch { }
        var dlg = new NodeAddWindow(_store, text) { Owner = this };
        dlg.ShowDialog();
        if (dlg.Saved.Count == 0) return;
        try
        {
            var clip = Clipboard.GetText();
            if (dlg.Passwords.Any(pw => clip.Contains(pw, StringComparison.Ordinal))) Clipboard.Clear();
        }
        catch { }
        Reload(dlg.Saved[^1].Id);
    }

    private void New_Click(object sender, RoutedEventArgs e)
    {
        List.SelectedItem = null;
        Blank();
    }

    private XuiPanel? FromForm(bool requireToken = true)
    {
        try { PanelUrl.Parse(UrlBox.Text); }
        catch (XuiException ex) { ResultText.Text = ex.Message; return null; }
        var token = TokenBox.Password.Trim();
        if (token.Length == 0) token = _cur?.Token ?? "";
        var role = RoleOf(RoleBox.SelectedIndex);
        var awg = role == "awg";
        if (token.Length == 0 && requireToken)
        {
            ResultText.Text = role is "awg" or "awg1" ? "Нужен пароль" : "Нужен API-токен — или логин и пароль → «Выпустить токен по паролю»";
            return null;
        }
        if (awg && LoginBox.Text.Trim().Length == 0) { ResultText.Text = "Нужен логин"; return null; }
        var name = NameBox.Text.Trim();
        if (name.Length == 0) name = PanelUrl.Parse(UrlBox.Text).Host.Split('.')[0].ToUpperInvariant();
        return new XuiPanel
        {
            Id = _cur?.Id ?? Guid.NewGuid(),
            Name = name,
            Role = role,
            Login = role == "awg1" ? "" : LoginBox.Text.Trim(),
            Url = UrlBox.Text.Trim(),
            Token = token,
            VerifyTls = TlsBox.SelectedIndex == 0,
            // то, чего нет в форме, — не терять
            Pass = role is "master" or "node" ? (PassBox.Password.Length > 0 ? PassBox.Password : _cur?.Pass) : null,
            Clients = _cur?.Clients,
            Ssh = (SshBox.SelectedItem as SshItem)?.Id,
        };
    }

    private async void Test_Click(object sender, RoutedEventArgs e)
    {
        if (FromForm() is not { } p) return;
        ResultText.Text = "проверяю…";
        try
        {
            if (p.IsAwg)
            {
                // вид AWG-панели определяется сам — роль в форме подправим под ответ
                var msg = await AwgProbe.TestAsync(p);
                RoleBox.SelectedIndex = RoleIndex(p.Role);
                ResultText.Text = msg;
                return;
            }
            using var api = XuiApi.For(p);
            var st = await api.StatusAsync();
            var ver = st?["panelVersion"]?.GetValue<string>() ?? "?";
            var nodes = p.IsMaster ? $", узлов: {(await api.NodesAsync()).Count}" : "";
            ResultText.Text = $"✓ отвечает, 3x-ui {ver}{nodes}";
        }
        catch (XuiException ex) { ResultText.Text = "✗ " + ex.Message; }
        catch (Exception ex) { ResultText.Text = "✗ " + ex.Message; }
    }

    private async void Issue_Click(object sender, RoutedEventArgs e)
    {
        if (FromForm(requireToken: false) is not { } p) return;
        if (p.Login.Length == 0 || string.IsNullOrEmpty(p.Pass)) { ResultText.Text = "✗ Нужны логин и пароль админа"; return; }
        ResultText.Text = "вхожу в панель…";
        try
        {
            var name = $"qterm-{DateTime.Now:yyMMdd-HHmmss}";
            var code = TwoFaBox.Text.Trim();
            var r = await XuiLogin.IssueTokenAsync(p.Url, p.Login, p.Pass!, code.Length > 0 ? code : null, p.VerifyTls, name);
            if (string.IsNullOrEmpty(r.Token))
            {
                ResultText.Text = "✗ " + r.Message;
                if (r.NeedTwoFactor) TwoFaBox.Focus();
                return;
            }
            p.Token = r.Token;
            _store.SavePanel(p);
            Reload(p.Id);
            ResultText.Text = $"✓ токен «{name}» выпущен и сохранён вместе с паролем";
        }
        catch (Exception ex) { ResultText.Text = "✗ " + ex.Message; }
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (FromForm() is not { } p) return;
        _store.SavePanel(p);
        Reload(p.Id);
        ResultText.Text = "✓ сохранено (DPAPI; синком — в зашифрованном виде)";
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (_cur is null) return;
        if (!XuiDialog.Confirm(this, $"Удалить «{_cur.Name}» из QTerm? На самой панели ничего не меняется.",
                "Панели", "Удалить")) return;
        _store.DeletePanel(_cur.Id);
        Reload(null);
    }
}
