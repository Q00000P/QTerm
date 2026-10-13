using System.Text.Json;
using System.Text.Json.Serialization;
using QTermWin.Models;
using QTermWin.Vault;

namespace QTermWin.QDash;

/// <summary>Хаб QDash, к которому подключён QTerm: адреса и отпечатки сертов.
/// Живёт в secrets вейлта ("qdash.hub:&lt;ID&gt;") и ЕДЕТ синком (LWW по updatedAt):
/// на другом устройстве хаб виден сразу, а ключ устройства — свой (см. <see cref="QDashKey"/>).</summary>
public sealed class QDashHub
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    /// <summary>Адрес, с которого хаб заведён (из ссылки qdash://enroll — снаружи это канал через VPS).</summary>
    [JsonPropertyName("url")] public string Url { get; set; } = "";
    /// <summary>sha256 серта этого адреса, hex строчными (без «sha256:»); пусто — http/без пина.</summary>
    [JsonPropertyName("fp")] public string Fp { get; set; } = "";
    /// <summary>Адреса портала в локалке (из /api/dev → lan): https://ip:port…, пробуются первыми.</summary>
    [JsonPropertyName("lan")] public List<string>? Lan { get; set; }
    /// <summary>Отпечаток серта портала (у локального и внешнего сокетов серты разные).</summary>
    [JsonPropertyName("lanFp")] public string? LanFp { get; set; }
    /// <summary>Имя хоста хаба (из whoami/claim) — для подписи в списке.</summary>
    [JsonPropertyName("host")] public string? Host { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }

    [JsonIgnore] public string Display => Name.Length > 0 ? Name : Url;
    public override string ToString() => Display;

    /// <summary>Хост адреса (для дедупа: тот же хаб, заведённый дважды).</summary>
    [JsonIgnore] public string UrlHost
    {
        get { try { return new Uri(Url).Host.ToLowerInvariant(); } catch { return Url; } }
    }
}

/// <summary>Ключ ЭТОГО устройства к хабу: пара ed25519 и что хаб о ней знает.
/// Ключ секрета — "sync.qdash:&lt;ID хаба&gt;": всё с префиксом "sync." режется из облачной копии
/// на всех платформах, так что приватная половина никуда с устройства не уходит (как и у qdcli).
/// Отзыв одного устройства в портале не трогает остальные — ровно потому, что пары у них свои.</summary>
public sealed class QDashKey
{
    /// <summary>id устройства в хабе (16 hex).</summary>
    [JsonPropertyName("dev")] public string Dev { get; set; } = "";
    /// <summary>Публичная половина, 32 байта base64.</summary>
    [JsonPropertyName("pub")] public string Pub { get; set; } = "";
    /// <summary>Приватная половина (seed ed25519, 32 байта base64). Только здесь.</summary>
    [JsonPropertyName("priv")] public string Priv { get; set; } = "";
    [JsonPropertyName("role")] public string Role { get; set; } = "";
    [JsonPropertyName("roleName")] public string RoleName { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("claimedAt")] public string? ClaimedAt { get; set; }
}

/// <summary>Хранилище хабов и ключей поверх secrets вейлта (как XuiStore).</summary>
public sealed class QDashStore
{
    public const string HubPrefix = "qdash.hub:";
    public const string KeyPrefix = "sync.qdash:";

    private static readonly JsonSerializerOptions Json = QtJson.Options;
    private readonly VaultRepo _repo;

    public QDashStore(VaultRepo repo) { _repo = repo; }

    public VaultRepo Repo => _repo;

    private Dictionary<string, string> Secrets => _repo.Data.Secrets ??= new();

    private static string K(Guid id) => id.ToString("D").ToUpperInvariant();

    public List<QDashHub> Hubs()
    {
        var list = new List<QDashHub>();
        foreach (var (k, v) in Secrets)
        {
            if (!k.StartsWith(HubPrefix, StringComparison.Ordinal)) continue;
            try
            {
                var h = JsonSerializer.Deserialize<QDashHub>(v, Json);
                if (h is not null && h.Deleted != true) list.Add(h);
            }
            catch { /* битая запись — пропускаем */ }
        }
        return list.OrderBy(h => h.Display, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public QDashHub? HubById(Guid id) => Hubs().FirstOrDefault(h => h.Id == id);

    /// <summary>Тот же хаб по хосту адреса (ссылку из портала вставили второй раз).</summary>
    public QDashHub? HubByUrlHost(string url)
    {
        string host;
        try { host = new Uri(url).Host.ToLowerInvariant(); } catch { return null; }
        return Hubs().FirstOrDefault(h => h.UrlHost == host);
    }

    public void SaveHub(QDashHub h)
    {
        h.UpdatedAt = QtJson.NowIso();
        h.Deleted = null;
        Secrets[HubPrefix + K(h.Id)] = JsonSerializer.Serialize(h, Json);
        _repo.Persist();
    }

    /// <summary>Удаление = tombstone (доедет синком), ключ устройства — просто стирается.</summary>
    public void DeleteHub(Guid id)
    {
        var stub = new QDashHub { Id = id, Deleted = true, UpdatedAt = QtJson.NowIso() };
        Secrets[HubPrefix + K(id)] = JsonSerializer.Serialize(stub, Json);
        Secrets.Remove(KeyPrefix + K(id));
        _repo.Persist();
    }

    public QDashKey? Key(Guid hubId)
    {
        if (!Secrets.TryGetValue(KeyPrefix + K(hubId), out var v)) return null;
        try { return JsonSerializer.Deserialize<QDashKey>(v, Json); }
        catch { return null; }
    }

    public void SaveKey(Guid hubId, QDashKey key)
    {
        Secrets[KeyPrefix + K(hubId)] = JsonSerializer.Serialize(key, Json);
        _repo.Persist(sync: false); // ключ — локальный, пуш не дёргаем; хаб сам уже запушен
    }

    public void ForgetKey(Guid hubId)
    {
        if (Secrets.Remove(KeyPrefix + K(hubId))) _repo.Persist(sync: false);
    }

    /// <summary>Синк: записи qdash.* — LWW по встроенному updatedAt (как xui.*).</summary>
    public static bool IsLww(string key) => key.StartsWith("qdash.", StringComparison.Ordinal);
}
