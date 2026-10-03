using System.Windows;

namespace QTermWin.Xui;

/// <summary>Перевыпуск токена 3x-ui по сохранённым логину/паролю, когда панель отвечает 401.</summary>
public static class XuiReauth
{
    /// <summary>Хранилище панелей (ставит XuiStore при создании).</summary>
    public static XuiStore? Store { get; set; }

    /// <summary>Строка для лога окна «Ноды 3x-ui».</summary>
    public static event Action<string, LogKind>? Notice;

    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly Dictionary<Guid, (DateTime At, bool Ok)> Recent = new();

    private static Task<T> OnUi<T>(Func<T> f)
    {
        var d = Application.Current?.Dispatcher;
        return d is null || d.CheckAccess() ? Task.FromResult(f()) : d.InvokeAsync(f).Task;
    }

    private static void Say(string s, LogKind k) => Notice?.Invoke(s, k);

    public static async Task<string?> ReissueAsync(Guid id)
    {
        var store = Store;
        if (store is null) return null;
        await Gate.WaitAsync();
        try
        {
            var p = await OnUi(() => store.Panels().FirstOrDefault(x => x.Id == id));
            if (p is null || !p.IsXui || p.Login.Length == 0 || string.IsNullOrEmpty(p.Pass)) return null;
            // только что перевыпущен — у окна ещё копии со старым токеном; пароль не подошёл — не долбить вход
            if (Recent.TryGetValue(id, out var r) && DateTime.UtcNow - r.At < TimeSpan.FromSeconds(60))
                return r.Ok ? p.Token : null;
            Recent[id] = (DateTime.UtcNow, false);
            Say($"  ↻ «{p.Name}»: панель не приняла токен — выпускаю новый по сохранённому паролю", LogKind.Warn);
            try
            {
                var res = await XuiLogin.IssueTokenAsync(p.Url, p.Login, p.Pass!, null, p.VerifyTls,
                    $"qterm-{DateTime.Now:yyMMdd-HHmmss}");
                if (string.IsNullOrEmpty(res.Token))
                {
                    Say($"  ✗ «{p.Name}»: " + (res.NeedTwoFactor ? "включена 2FA — выпусти токен вручную в «Панели и токены…»" : res.Message), LogKind.Err);
                    return null;
                }
                p.Token = res.Token;
                await OnUi(() => { store.SavePanel(p); return true; });
                Recent[id] = (DateTime.UtcNow, true);
                Say($"  ✓ «{p.Name}»: новый токен выпущен и сохранён", LogKind.Ok);
                return res.Token;
            }
            catch (Exception ex)
            {
                Say($"  ✗ «{p.Name}»: {ex.Message}", LogKind.Err);
                return null;
            }
        }
        finally { Gate.Release(); }
    }
}
