using System.Windows;
using System.Windows.Controls;
using QTermWin.QDash;

namespace QTermWin.UI;

/// <summary>Заведение QTerm в хабе: ссылка qdash://enroll?… из портала или адрес+код+отпечаток.
/// Сам claim делается здесь же (кнопка «Завести»): результат — хаб и ключ, сохранённые в вейлт.</summary>
public partial class QDashAddDialog : Window
{
    private readonly QDashStore _store;
    public QDashHub? Hub { get; private set; }

    public QDashAddDialog(QDashStore store, QDashHub? reenroll = null)
    {
        InitializeComponent();
        _store = store;
        if (reenroll is not null)
        {
            Title = $"Хаб «{reenroll.Display}» — перезавести ключ";
            UrlBox.Text = reenroll.Url;
            FpBox.Text = reenroll.Fp;
            Hub = reenroll;
        }
        Loaded += (_, _) => LinkBox.Focus();
    }

    private void Link_Changed(object sender, TextChangedEventArgs e)
    {
        if (!QDashClient.TryParseEnrollLink(LinkBox.Text, out var url, out var code, out var fp, out var name)) return;
        UrlBox.Text = url;
        CodeBox.Text = code;
        FpBox.Text = fp;
        if (name.Length > 0) NameBox.Text = name;
        ResultText.Text = "Ссылка разобрана — проверь и нажми «Завести»";
    }

    private async void Ok_Click(object sender, RoutedEventArgs e)
    {
        var url = UrlBox.Text.Trim().TrimEnd('/');
        var code = CodeBox.Text.Trim();
        var fp = QDashClient.Norm(FpBox.Text);
        var name = NameBox.Text.Trim();
        if (url.Length == 0 || code.Length == 0) { ResultText.Text = "Нужны адрес хаба и код (или ссылка из портала)"; return; }
        if (!url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            url = "https://" + url;
        if (url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) && fp.Length == 0)
        {
            // без пина свой серт хаба не пройдёт проверку цепочки — скажем сразу, а не «не завелось»
            ResultText.Text = "Для HTTPS нужен отпечаток серта хаба (в ссылке из портала он есть; иначе — портал → API → отпечаток)";
            return;
        }
        if (name.Length == 0) name = Environment.MachineName + " (QTerm)";
        OkBtn.IsEnabled = false;
        ResultText.Text = "Заводим…";
        try
        {
            var (key, host, version) = await Task.Run(() => QDashClient.ClaimAsync(url, fp, code, name));
            var hub = Hub ?? _store.HubByUrlHost(url) ?? new QDashHub();
            hub.Url = url;
            hub.Fp = fp;
            if (host.Length > 0) hub.Host = host;
            if (hub.Name.Length == 0) hub.Name = host.Length > 0 ? host : new Uri(url).Host;
            _store.SaveHub(hub);
            _store.SaveKey(hub.Id, key);
            QDashCenter.Drop(hub.Id);
            Hub = hub;
            ResultText.Text = $"Завелось: {key.Name} · роль {key.RoleName} · хаб {host} (qdash {version})";
            await Task.Delay(400);
            DialogResult = true;
        }
        catch (Exception ex)
        {
            ResultText.Text = "✗ " + ex.Message;
            OkBtn.IsEnabled = true;
        }
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;
}
