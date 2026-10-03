using System.Text.Json;
using System.Text.Json.Serialization;
using QTermWin.Models;
using QTermWin.Vault;

namespace QTermWin.Xui;

/// <summary>Панель 3x-ui (главная или нода): адрес как в браузере + API-токен.
/// Живёт в secrets вейлта ("xui.panel:&lt;ID&gt;") — DPAPI локально, QTS1 в облаке;
/// мак/андроид словарь секретов не режут, так что запись переживает их пуш.</summary>
public sealed class XuiPanel
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    /// <summary>master | node | awg (awg-panel, wg-easy v15) | awg1 (старая amnezia-wg-easy, только пароль)</summary>
    [JsonPropertyName("role")] public string Role { get; set; } = "node";
    [JsonPropertyName("url")] public string Url { get; set; } = "";
    /// <summary>3x-ui — API-токен; awg-panel — пароль админа (логин в Login); старая amnezia-wg-easy — пароль панели.</summary>
    [JsonPropertyName("token")] public string Token { get; set; } = "";
    [JsonPropertyName("login")] public string Login { get; set; } = "";
    /// <summary>3x-ui: пароль админа панели (из итога установки) — чтобы перевыпустить токен без похода в панель.</summary>
    [JsonPropertyName("pass")] public string? Pass { get; set; }
    /// <summary>AWG: имена клиентов на момент последнего обновления — после переустановки пересоздать их на новой панели.</summary>
    [JsonPropertyName("clients")] public List<string>? Clients { get; set; }
    /// <summary>SSH-сессия QTerm этого сервера (id) — для установки/отката версии панели в терминале.</summary>
    [JsonPropertyName("ssh")] public string? Ssh { get; set; }
    [JsonPropertyName("verifyTls")] public bool VerifyTls { get; set; } = true;
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }

    [JsonIgnore] public bool IsMaster => Role == "master";
    [JsonIgnore] public bool IsAwg => Role is "awg" or "awg1";
    [JsonIgnore] public bool IsAwgLegacy => Role == "awg1";
    [JsonIgnore] public bool IsXuiNode => Role == "node";
    [JsonIgnore] public bool IsXui => Role is "master" or "node";
    [JsonIgnore] public string RoleText => Role switch { "master" => "3x-ui · главная", "awg" => "AWG-панель", "awg1" => "AWG-панель (старая)", _ => "3x-ui · нода" };
    [JsonIgnore] public string Display => $"{Name}  ·  {RoleText}";
    public override string ToString() => Name;
}

/// <summary>Канонические имена клиентов + синонимы + суффикс для имён не из списка.</summary>
public sealed class XuiNamesConfig
{
    /// <summary>Базовые имена. Индекс протокола ставится сам: PC — VLESS, PC-HYS — Hysteria, PC-SYNC — оба.</summary>
    public static readonly string[] DefaultNames =
    {
        "PC", "OP12", "S26", "OP9", "Lap", "LT", "MAMA",
        "VI", "MAC", "NC", "GIGA", "PEAK", "GIANT", "ULTRA",
    };

    /// <summary>Строки: «ИМЯ» или «СИНОНИМ = ИМЯ»; # — комментарий.</summary>
    [JsonPropertyName("lines")] public List<string> Lines { get; set; } = DefaultNames.ToList();
    /// <summary>Суффикс для клиентов не из списка (NEWGUY → NEWGUY-HYS). Пусто — имя не трогаем.</summary>
    [JsonPropertyName("suffix")] public string Suffix { get; set; } = "";
    /// <summary>2 — суффикс по умолчанию пустой (в v1 был «-HYS» и уродовал чужие имена).</summary>
    [JsonPropertyName("v")] public int V { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
}

public sealed class XuiStore
{
    private const string PanelPrefix = "xui.panel:";
    private const string NamesKey = "xui.names";

    private static readonly JsonSerializerOptions Json = QtJson.Options;

    private readonly VaultRepo _repo;

    public XuiStore(VaultRepo repo)
    {
        _repo = repo;
        XuiReauth.Store = this;
    }

    private Dictionary<string, string> Secrets => _repo.Data.Secrets ??= new();

    public List<XuiPanel> Panels()
    {
        var list = new List<XuiPanel>();
        foreach (var (k, v) in Secrets)
        {
            if (!k.StartsWith(PanelPrefix, StringComparison.Ordinal)) continue;
            try
            {
                var p = JsonSerializer.Deserialize<XuiPanel>(v, Json);
                if (p is not null && p.Deleted != true) list.Add(p);
            }
            catch { /* битая запись — пропускаем */ }
        }
        return list.OrderBy(p => p.IsMaster ? 0 : p.IsXuiNode ? 1 : 2)
                   .ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public XuiPanel? PanelById(Guid id) => Panels().FirstOrDefault(p => p.Id == id);

    public void SavePanel(XuiPanel p)
    {
        p.UpdatedAt = QtJson.NowIso();
        p.Deleted = null;
        Secrets[PanelPrefix + p.Id.ToString("D").ToUpperInvariant()] = JsonSerializer.Serialize(p, Json);
        _repo.Persist();
    }

    /// <summary>Удаление = tombstone без токена (иначе вернётся с другого устройства).</summary>
    public void DeletePanel(Guid id)
    {
        var key = PanelPrefix + id.ToString("D").ToUpperInvariant();
        var stub = new XuiPanel { Id = id, Deleted = true, UpdatedAt = QtJson.NowIso() };
        Secrets[key] = JsonSerializer.Serialize(stub, Json);
        _repo.Persist();
    }

    /// <summary>Ноды QTerm (SSH-сессии) — для привязки панели к серверу.</summary>
    public List<Session> Sessions() =>
        _repo.Data.Sessions.Where(x => x.Deleted != true)
             .OrderBy(x => x.Name, StringComparer.OrdinalIgnoreCase).ToList();

    /// <summary>SSH-сессия сервера панели: явно привязанная → тот же хост → тот же IP.</summary>
    public Session? SessionFor(XuiPanel p)
    {
        var all = Sessions();
        if (Guid.TryParse(p.Ssh, out var id) && all.FirstOrDefault(x => x.Id == id) is { } s) return s;
        string host;
        try { host = PanelUrl.Parse(p.Url).Host; } catch { return null; }
        var byHost = all.FirstOrDefault(x => string.Equals(x.Host.Trim(), host, StringComparison.OrdinalIgnoreCase));
        if (byHost is not null) return byHost;
        try
        {
            var ips = System.Net.Dns.GetHostAddresses(host).Select(a => a.ToString()).ToHashSet();
            return all.FirstOrDefault(x => ips.Contains(x.Host.Trim()));
        }
        catch { return null; }
    }

    public XuiNamesConfig Names()
    {
        if (Secrets.TryGetValue(NamesKey, out var v))
        {
            try
            {
                var cfg = JsonSerializer.Deserialize<XuiNamesConfig>(v, Json);
                if (cfg is not null)
                {
                    if (cfg.V < 2 && cfg.Suffix == "-HYS") cfg.Suffix = "";
                    cfg.V = 2;
                    return cfg;
                }
            }
            catch { }
        }
        return new XuiNamesConfig();
    }

    public void SaveNames(XuiNamesConfig cfg)
    {
        cfg.UpdatedAt = QtJson.NowIso();
        cfg.V = 2;
        Secrets[NamesKey] = JsonSerializer.Serialize(cfg, Json);
        _repo.Persist();
    }

    // ── синк: записи xui.* — LWW по встроенному updatedAt (остальные секреты — локальный приоритет) ──

    public static bool IsLww(string key) => key.StartsWith("xui.", StringComparison.Ordinal);

    private static string? UpdatedAtOf(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.TryGetProperty("updatedAt", out var u) && u.ValueKind == JsonValueKind.String
                ? u.GetString() : null;
        }
        catch { return null; }
    }

    /// <summary>true — брать удалённую версию (строго новее; ничья = локальная).</summary>
    public static bool RemoteNewer(string localJson, string remoteJson)
    {
        var l = UpdatedAtOf(localJson);
        var r = UpdatedAtOf(remoteJson);
        if (r is null) return false;
        if (l is null) return true;
        return string.CompareOrdinal(r, l) > 0;
    }
}
