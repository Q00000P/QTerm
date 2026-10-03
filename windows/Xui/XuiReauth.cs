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

    public sealed record Issued(string? Token, string Message, bool NeedTwoFactor = false);

    /// <summary>Войти логином/паролем, выпустить admin-токен, сохранить его вместе с логином и паролем.</summary>
    public static async Task<Issued> IssueAndSaveAsync(Guid id, string login, string pass, string? twoFa = null)
    {
        var store = Store;
        if (store is null) return new(null, "хранилище панелей недоступно");
        var p = await OnUi(() => store.Panels().FirstOrDefault(x => x.Id == id));
        if (p is null) return new(null, "панель не найдена");
        try
        {
            var res = await XuiLogin.IssueTokenAsync(p.Url, login, pass, twoFa, p.VerifyTls, $"qterm-{DateTime.Now:yyMMdd-HHmmss}");
            if (string.IsNullOrEmpty(res.Token))
                return new(null, res.NeedTwoFactor ? "включена 2FA — нужен код" : res.Message, res.NeedTwoFactor);
            p.Login = login;
            p.Pass = pass;
            p.Token = res.Token;
            await OnUi(() => { store.SavePanel(p); return true; });
            lock (Recent) Recent[id] = (DateTime.UtcNow, true);
            return new(res.Token, "новый токен выпущен и сохранён");
        }
        catch (Exception ex) { return new(null, ex.Message); }
    }

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
            (DateTime At, bool Ok) last;
            bool has;
            lock (Recent) has = Recent.TryGetValue(id, out last);
            if (has && DateTime.UtcNow - last.At < TimeSpan.FromSeconds(60))
                return last.Ok ? p.Token : null;
            lock (Recent) Recent[id] = (DateTime.UtcNow, false);
            Say($"  ↻ «{p.Name}»: панель не приняла токен — выпускаю новый по сохранённому паролю", LogKind.Warn);
            var r = await IssueAndSaveAsync(id, p.Login, p.Pass!);
            Say($"  {(r.Token is null ? "✗" : "✓")} «{p.Name}»: {r.Message}", r.Token is null ? LogKind.Err : LogKind.Ok);
            return r.Token;
        }
        finally { Gate.Release(); }
    }
}
