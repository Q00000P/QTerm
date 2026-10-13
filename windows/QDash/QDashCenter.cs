using System.Collections.Concurrent;

namespace QTermWin.QDash;

/// <summary>Один клиент на хаб на всё приложение: окно QDash, вкладки задач и (дальше) «Ноды 3x-ui»/«Каскад»
/// ходят одним и тем же соединением, с одним выбранным путём (локалка/канал) и одним окном 2FA.</summary>
public static class QDashCenter
{
    private static readonly ConcurrentDictionary<Guid, QDashClient> Clients = new();

    /// <summary>Спросить код 2FA у пользователя (ставит главное окно: диалог на UI-потоке).</summary>
    public static Func<string, string, Task<string?>>? AskCode { get; set; }

    public static QDashStore? Store { get; set; }

    /// <summary>Клиент хаба по записи вейлта; пересоздаётся, если адреса/ключ изменились.</summary>
    public static QDashClient Client(QDashHub hub, QDashKey? key)
    {
        var sig = Sig(hub, key);
        if (Clients.TryGetValue(hub.Id, out var c) && c.Hub.UpdatedAt == hub.UpdatedAt && Sig(c.Hub, c.Key) == sig)
            return c;
        var n = new QDashClient(hub, key) { AskCode = (w, t) => AskCode?.Invoke(w, t) ?? Task.FromResult<string?>(null) };
        Clients.AddOrUpdate(hub.Id, n, (_, old) => { old.Dispose(); return n; });
        return n;
    }

    public static QDashClient? Client(Guid hubId)
    {
        if (Store is null) return null;
        var hub = Store.HubById(hubId);
        if (hub is null) return null;
        return Client(hub, Store.Key(hubId));
    }

    public static void Drop(Guid hubId)
    {
        if (Clients.TryRemove(hubId, out var c)) c.Dispose();
    }

    private static string Sig(QDashHub h, QDashKey? k) =>
        string.Join("|", h.Url, h.Fp, h.LanFp ?? "", string.Join(",", h.Lan ?? new()), k?.Dev ?? "", k?.Pub ?? "");
}
