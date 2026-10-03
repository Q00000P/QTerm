using System.Windows;
using System.Windows.Controls;
using QTermWin.Xui;

namespace QTermWin.UI;

/// <summary>Адрес + токен ноды (подключение / ревизия / сохранение токена).</summary>
public partial class XuiConnectDialog : Window
{
    public string Url { get; private set; } = "";
    public string Token { get; private set; } = "";
    public bool VerifyTls { get; private set; } = true;
    public string? NodeName { get; private set; }
    public bool AttachOthers { get; private set; }
    public bool SaveToken { get; private set; } = true;

    public XuiConnectDialog(List<XuiPanel> saved, string? url = null, string? name = null, bool tokenOnly = false)
    {
        InitializeComponent();
        SavedBox.ItemsSource = saved;
        SavedPanel.Visibility = saved.Count > 0 && !tokenOnly ? Visibility.Visible : Visibility.Collapsed;
        if (url is not null) UrlBox.Text = url;
        if (name is not null) NameBox.Text = name;
        if (tokenOnly)
        {
            Title = "Токен ноды " + name;
            NamePanel.Visibility = Visibility.Collapsed;
            ExtraPanel.Visibility = Visibility.Collapsed;
            OkButton.Content = "Проверить и сохранить";
        }
        Loaded += (_, _) => { if (UrlBox.Text.Length == 0) UrlBox.Focus(); else TokenBox.Focus(); };
    }

    private void Saved_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (SavedBox.SelectedItem is not XuiPanel p) return;
        UrlBox.Text = p.Url;
        TokenBox.Password = p.Token;
        NameBox.Text = p.Name;
        TlsBox.SelectedIndex = p.VerifyTls ? 0 : 1;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            PanelUrl.Parse(UrlBox.Text);
        }
        catch (XuiException ex)
        {
            ErrorText.Text = ex.Message;
            ErrorText.Visibility = Visibility.Visible;
            return;
        }
        if (TokenBox.Password.Trim().Length == 0)
        {
            ErrorText.Text = "Нужен API-токен ноды";
            ErrorText.Visibility = Visibility.Visible;
            return;
        }
        Url = UrlBox.Text.Trim();
        Token = TokenBox.Password.Trim();
        VerifyTls = TlsBox.SelectedIndex == 0;
        NodeName = string.IsNullOrWhiteSpace(NameBox.Text) ? null : NameBox.Text.Trim();
        AttachOthers = OthersBox.SelectedIndex == 0;
        SaveToken = SaveBox.SelectedIndex == 0;
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
