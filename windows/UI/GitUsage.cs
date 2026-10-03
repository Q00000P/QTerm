using QTermWin.Security;

namespace QTermWin.UI;

/// <summary>
/// Локальная статистика команд Git (settings.json, не синкается): когда и сколько
/// раз запускали, какой вариант выбирали последним. Нужна быстрому вызову —
/// частое сверху, F1 → Enter повторяет последнее.
/// </summary>
public static class GitUsage
{
    private static Dictionary<string, GitUse>? _map;

    private static Dictionary<string, GitUse> Map =>
        _map ??= AppSettings.Load().GitUsage is { } m
            ? new Dictionary<string, GitUse>(m)
            : new Dictionary<string, GitUse>();

    public static GitUse? Get(Guid id) => Map.GetValueOrDefault(id.ToString("N"));

    public static int Variant(Guid id) => Get(id)?.Variant ?? 0;

    public static void SetVariant(Guid id, int variant)
    {
        var k = id.ToString("N");
        if (Map.TryGetValue(k, out var u))
        {
            if (u.Variant == variant) return;
            u.Variant = variant;
        }
        else Map[k] = new GitUse { Variant = variant };
        Save();
    }

    /// <summary>Команду запустили/вставили: наверх списка, вариант запомнить.</summary>
    public static void Touch(Guid id, int variant)
    {
        var k = id.ToString("N");
        if (!Map.TryGetValue(k, out var u)) Map[k] = u = new GitUse();
        u.Count++;
        u.Variant = variant;
        u.LastUsed = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        Save();
    }

    private static void Save()
    {
        try
        {
            var st = AppSettings.Load();
            st.GitUsage = new Dictionary<string, GitUse>(Map);
            st.Save();
        }
        catch { /* статистика — не критично */ }
    }
}
