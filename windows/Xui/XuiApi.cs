using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Authentication;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace QTermWin.Xui;

public sealed class XuiException : Exception
{
    public XuiException(string message) : base(message) { }
}

/// <summary>Адрес панели как в браузере → схема/хост/порт/базовый путь (без /panel/…).</summary>
public sealed record PanelUrl(string Scheme, string Host, int Port, string BasePath)
{
    public string HostForUrl => Host.Contains(':') ? $"[{Host}]" : Host;
    public string Base => $"{Scheme}://{HostForUrl}:{Port}{BasePath}";
    public string BasePathOrSlash => BasePath.Length == 0 ? "/" : BasePath + "/";

    public static PanelUrl Parse(string url)
    {
        url = (url ?? "").Trim();
        if (url.Length == 0) throw new XuiException("пустой адрес панели");
        if (!url.Contains("://")) url = "https://" + url;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || string.IsNullOrEmpty(u.Host))
            throw new XuiException("не разобрал адрес панели: " + url);
        var scheme = u.Scheme.ToLowerInvariant();
        var port = u.IsDefaultPort ? (scheme == "https" ? 443 : 80) : u.Port;
        var path = u.AbsolutePath ?? "/";
        path = Regex.Split(path, "/panel(/|$)")[0];
        path = "/" + path.Trim('/');
        var host = u.Host.Trim('[', ']');
        return new PanelUrl(scheme, host, port, path == "/" ? "" : path);
    }

    public bool SameAs(string address, int port, string? basePath) =>
        string.Equals(address, Host, StringComparison.OrdinalIgnoreCase) && port == Port &&
        (basePath ?? "/").Trim('/') == BasePath.Trim('/');
}

// ── DTO ──

public sealed class XClient
{
    public int Id;
    public string Email = "";
    public string SubId = "";
    public string Uuid = "";
    public string Auth = "";
    public string Password = "";
    public string Flow = "";
    public bool Enable = true;
    public long TotalBytes;
    public long ExpiryTime;
    public long Up, Down;
    public string Comment = "";
    public List<int> InboundIds = new();
    public JsonObject Raw = new();
}

public sealed class XInbound
{
    public int Id;
    public string Remark = "";
    public string Tag = "";
    public string Protocol = "";
    public int Port;
    public int? NodeId;
    public bool Enable = true;
    public List<string> ClientEmails = new();

    public bool MultiUser => Protocol is "vless" or "vmess" or "trojan" or "shadowsocks" or "hysteria" or "tuic";
    public bool IsHys => Protocol == "hysteria";
}

public sealed class XNode
{
    public int Id;
    public string Name = "";
    public string Scheme = "https";
    public string Address = "";
    public int Port;
    public string BasePath = "/";
    public bool Enable = true;
    public string Status = "unknown";
    public int LatencyMs;
    public double CpuPct, MemPct;
    public long UptimeSecs;
    public long NetUp, NetDown;
    public string XrayVersion = "", PanelVersion = "", XrayState = "", LastError = "";
    public int InboundCount, ClientCount, OnlineCount;
}

/// <summary>REST API 3x-ui v3 (Bearer-токен). Без webDomain-плясок: снаружи Host = домен из адреса.</summary>
public sealed class XuiApi : IDisposable
{
    private static readonly JsonSerializerOptions BodyJson = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly HttpClient _http;
    private string _token;
    /// <summary>Перевыпуск токена при 401 (сохранённые логин/пароль админа). Один раз на объект API.</summary>
    public Func<Task<string?>>? Reauth { get; set; }
    private Task<string?>? _reauthTask;
    private readonly object _reauthLock = new();
    public string Label { get; }
    public PanelUrl Url { get; }
    public bool VerifyTls { get; }

    public XuiApi(string label, string url, string token, bool verifyTls = true)
    {
        Label = label;
        Url = PanelUrl.Parse(url);
        VerifyTls = verifyTls;
        var h = new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All };
        if (!verifyTls) h.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
        _http = new HttpClient(h) { Timeout = TimeSpan.FromSeconds(40) };
        _token = token.Trim();
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    public static XuiApi For(XuiPanel p)
    {
        var api = new XuiApi(p.Name, p.Url, p.Token, p.VerifyTls);
        if (p.IsXui && p.Login.Length > 0 && !string.IsNullOrEmpty(p.Pass))
        {
            var id = p.Id;
            api.Reauth = () => XuiReauth.ReissueAsync(id);
        }
        return api;
    }

    /// <summary>401: токен в QTerm панели неизвестен (удалён/выключен/истёк или панель переустановлена).</summary>
    public static XuiException Unauthorized(string label) => new(
        $"{label}: панель не принимает токен (401) — его удалили, выключили, он истёк или панель переустановлена. " +
        "«Панели и токены…» → панель → логин и пароль админа → «Выпустить токен» (с сохранённым паролем QTerm дальше перевыпускает сам)");

    private AuthenticationHeaderValue Bearer()
    {
        lock (_reauthLock) return new AuthenticationHeaderValue("Bearer", _token);
    }

    /// <summary>Новый токен (один перевыпуск на объект; параллельные запросы ждут тот же).</summary>
    private async Task<bool> RenewTokenAsync()
    {
        if (Reauth is null) return false;
        Task<string?> task;
        lock (_reauthLock) task = _reauthTask ??= Reauth();
        var t = await task;
        if (string.IsNullOrEmpty(t)) return false;
        lock (_reauthLock) _token = t;
        return true;
    }

    public void Dispose() => _http.Dispose();

    private async Task<(int Code, byte[] Body)> RawAsync(HttpMethod method, string path, object? body)
    {
        var r = await RawOnceAsync(method, path, body);
        if (r.Code == 401 && await RenewTokenAsync()) r = await RawOnceAsync(method, path, body);
        return r;
    }

    private async Task<(int Code, byte[] Body)> RawOnceAsync(HttpMethod method, string path, object? body)
    {
        using var req = new HttpRequestMessage(method, Url.Base + "/panel/api" + path);
        req.Headers.Authorization = Bearer();
        if (body is not null)
            req.Content = new StringContent(JsonSerializer.Serialize(body, BodyJson), Encoding.UTF8, "application/json");
        try
        {
            using var resp = await _http.SendAsync(req);
            return ((int)resp.StatusCode, await resp.Content.ReadAsByteArrayAsync());
        }
        catch (HttpRequestException ex) when (ex.InnerException is AuthenticationException)
        {
            throw new XuiException($"{Label}: сертификат не прошёл проверку ({ex.InnerException.Message})");
        }
        catch (HttpRequestException ex)
        {
            throw new XuiException($"{Label}: нет связи ({ex.InnerException?.Message ?? ex.Message})");
        }
        catch (TaskCanceledException)
        {
            throw new XuiException($"{Label}: таймаут");
        }
    }

    public async Task<JsonNode?> CallAsync(HttpMethod method, string path, object? body = null)
    {
        var (code, raw) = await RawAsync(method, path, body);
        switch (code)
        {
            case 401: throw Unauthorized(Label);
            case 403: throw new XuiException($"{Label}: 403 — токену не хватает прав или адрес не совпадает с доменом панели (webDomain)");
            case 404: throw new XuiException($"{Label}: 404 на {path} — проверь базовый путь панели");
        }
        JsonNode? js;
        try { js = JsonNode.Parse(raw); }
        catch { throw new XuiException($"{Label}: ответ не JSON (HTTP {code})"); }
        if (js?["success"]?.GetValue<bool>() != true)
        {
            var msg = js?["msg"]?.GetValue<string>();
            throw new XuiException($"{Label}: {path}: {(string.IsNullOrWhiteSpace(msg) ? "ошибка" : msg)}");
        }
        return js["obj"];
    }

    public Task<JsonNode?> GetAsync(string path) => CallAsync(HttpMethod.Get, path);
    public Task<JsonNode?> PostAsync(string path, object? body = null) => CallAsync(HttpMethod.Post, path, body ?? new { });

    public static string Q(string email) => Uri.EscapeDataString(email);

    // ── чтение ──

    public Task<JsonNode?> StatusAsync() => GetAsync("/server/status");

    public async Task<JsonObject> SettingsAsync() =>
        (await PostAsync("/setting/all")) as JsonObject ?? new JsonObject();

    public async Task<List<XClient>> ClientsAsync()
    {
        var arr = await GetAsync("/clients/list") as JsonArray ?? new JsonArray();
        var list = new List<XClient>();
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            var c = new XClient
            {
                Raw = o,
                Id = J.Int(o, "id"),
                Email = J.Str(o, "email"),
                SubId = J.Str(o, "subId"),
                Uuid = J.Str(o, "uuid"),
                Auth = J.Str(o, "auth"),
                Password = J.Str(o, "password"),
                Flow = J.Str(o, "flow"),
                Enable = J.Bool(o, "enable", true),
                TotalBytes = J.Long(o, "totalGB"),
                ExpiryTime = J.Long(o, "expiryTime"),
                Comment = J.Str(o, "comment"),
            };
            if (o["inboundIds"] is JsonArray ids)
                foreach (var i in ids) if (i is not null) c.InboundIds.Add(i.GetValue<int>());
            if (o["traffic"] is JsonObject t)
            {
                c.Up = J.Long(t, "up");
                c.Down = J.Long(t, "down");
            }
            list.Add(c);
        }
        return list;
    }

    public async Task<List<XInbound>> InboundsAsync()
    {
        var arr = await GetAsync("/inbounds/list") as JsonArray ?? new JsonArray();
        var list = new List<XInbound>();
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            var ib = new XInbound
            {
                Id = J.Int(o, "id"),
                Remark = J.Str(o, "remark"),
                Tag = J.Str(o, "tag"),
                Protocol = J.Str(o, "protocol"),
                Port = J.Int(o, "port"),
                Enable = J.Bool(o, "enable", true),
                NodeId = o["nodeId"] is JsonValue nv && nv.TryGetValue<int>(out var nid) ? nid : null,
            };
            JsonNode? settings = o["settings"];
            if (settings is JsonValue sv && sv.TryGetValue<string>(out var s) && s.Length > 0)
            {
                try { settings = JsonNode.Parse(s); } catch { settings = null; }
            }
            if (settings?["clients"] is JsonArray cl)
                foreach (var c in cl)
                    if (c?["email"] is JsonValue ev && ev.TryGetValue<string>(out var em)) ib.ClientEmails.Add(em);
            list.Add(ib);
        }
        return list;
    }

    public async Task<List<XNode>> NodesAsync()
    {
        var arr = await GetAsync("/nodes/list") as JsonArray ?? new JsonArray();
        var list = new List<XNode>();
        foreach (var n in arr)
        {
            if (n is not JsonObject o) continue;
            list.Add(new XNode
            {
                Id = J.Int(o, "id"),
                Name = J.Str(o, "name"),
                Scheme = J.Str(o, "scheme", "https"),
                Address = J.Str(o, "address"),
                Port = J.Int(o, "port"),
                BasePath = J.Str(o, "basePath", "/"),
                Enable = J.Bool(o, "enable", true),
                Status = J.Str(o, "status", "unknown"),
                LatencyMs = J.Int(o, "latencyMs"),
                CpuPct = J.Dbl(o, "cpuPct"),
                MemPct = J.Dbl(o, "memPct"),
                UptimeSecs = J.Long(o, "uptimeSecs"),
                NetUp = J.Long(o, "netUp"),
                NetDown = J.Long(o, "netDown"),
                XrayVersion = J.Str(o, "xrayVersion"),
                PanelVersion = J.Str(o, "panelVersion"),
                XrayState = J.Str(o, "xrayState"),
                LastError = J.Str(o, "lastError"),
                InboundCount = J.Int(o, "inboundCount"),
                ClientCount = J.Int(o, "clientCount"),
                OnlineCount = J.Int(o, "onlineCount"),
            });
        }
        return list;
    }

    public async Task<HashSet<string>> OnlinesAsync()
    {
        var set = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            if (await PostAsync("/clients/onlines") is JsonArray arr)
                foreach (var e in arr)
                    if (e is JsonValue v && v.TryGetValue<string>(out var s)) set.Add(s);
        }
        catch (XuiException) { /* старые панели / нет прав — не критично */ }
        return set;
    }

    public async Task<byte[]> GetDbAsync()
    {
        var (code, raw) = await RawAsync(HttpMethod.Get, "/server/getDb", null);
        if (code == 401) throw Unauthorized(Label);
        if (code == 403) throw new XuiException($"{Label}: токену не хватает прав на скачивание базы (403) — нужен токен с правами admin");
        if (code != 200 || raw.Length < 16 || Encoding.ASCII.GetString(raw, 0, 15) != "SQLite format 3")
            throw new XuiException($"{Label}: не удалось скачать базу (HTTP {code})");
        return raw;
    }

    // ── клиенты ──

    /// <summary>ClientRecord из /clients/list → тело /clients/update (model.Client).</summary>
    public static JsonObject ClientPayload(XClient c, string? email = null,
        IReadOnlyDictionary<string, string>? creds = null, bool? enable = null, string? subId = null)
    {
        var r = c.Raw;
        var o = new JsonObject
        {
            ["id"] = J.Str(r, "uuid"),
            ["security"] = J.Str(r, "security"),
            ["password"] = J.Str(r, "password"),
            ["flow"] = J.Str(r, "flow"),
            ["auth"] = J.Str(r, "auth"),
            ["email"] = email ?? c.Email,
            ["limitIp"] = J.Long(r, "limitIp"),
            ["totalGB"] = J.Long(r, "totalGB"),
            ["expiryTime"] = J.Long(r, "expiryTime"),
            ["enable"] = enable ?? J.Bool(r, "enable", true),
            ["tgId"] = J.Long(r, "tgId"),
            ["subId"] = subId ?? J.Str(r, "subId"),
            ["group"] = J.Str(r, "group"),
            ["comment"] = J.Str(r, "comment"),
            ["reset"] = J.Long(r, "reset"),
            ["resetDay"] = J.Long(r, "resetDay"),
            ["resetWeekday"] = J.Long(r, "resetWeekday"),
            ["resetMax"] = J.Long(r, "resetMax"),
            ["trafficReset"] = J.Str(r, "trafficReset", "never"),
            ["trafficResetDay"] = Math.Max(1, J.Long(r, "trafficResetDay")),
            ["limitHwid"] = J.Long(r, "limitHwid"),
        };
        if (creds is not null)
            foreach (var (k, v) in creds) o[k] = v;
        return o;
    }

    public Task UpdateClientAsync(string email, JsonObject body) => PostAsync($"/clients/update/{Q(email)}", body);
    public Task DeleteClientAsync(string email) => PostAsync($"/clients/del/{Q(email)}");
    public Task AttachAsync(string email, IEnumerable<int> ids) =>
        PostAsync($"/clients/{Q(email)}/attach", new { inboundIds = ids.ToArray() });
    public Task DetachAsync(string email, IEnumerable<int> ids) =>
        PostAsync($"/clients/{Q(email)}/detach", new { inboundIds = ids.ToArray() });
    public Task AddClientAsync(string email, IEnumerable<int> ids) =>
        PostAsync("/clients/add", new { client = new { email, enable = true }, inboundIds = ids.ToArray() });

    // ── узлы ──

    public Task<JsonNode?> AddNodeAsync(object body) => PostAsync("/nodes/add", body);
    public Task SetNodeEnableAsync(int id, bool enable) => PostAsync($"/nodes/setEnable/{id}", new { enable });
    public Task ProbeNodeAsync(int id) => PostAsync($"/nodes/probe/{id}");

    public async Task<string?> CreateTokenAsync(string name, string scope)
    {
        var o = await PostAsync("/setting/apiTokens/create", new { name, scope, expiresAt = 0 });
        return o?["token"]?.GetValue<string>();
    }

    // ── обновления панели / ядро Xray / база ──

    /// <summary>Текущая и последняя версия панели (панель сама спрашивает GitHub). null — не достучалась.</summary>
    public async Task<JsonObject?> UpdateInfoAsync()
    {
        try { return await GetAsync("/server/getPanelUpdateInfo") as JsonObject; }
        catch (XuiException) { return null; }
    }

    /// <summary>Самообновление панели (update.sh в отдельном юните systemd). Возвращает runId для опроса статуса.</summary>
    public async Task<string?> StartUpdateAsync() =>
        (await PostAsync("/server/updatePanel"))?["runId"]?.GetValue<string>();

    /// <summary>{runId, state: pending|success|failed, exitCode, finishedAt} последнего самообновления.</summary>
    public async Task<JsonObject?> UpdateStatusAsync() => await GetAsync("/server/getUpdateStatus") as JsonObject;

    /// <summary>Версии Xray-core, доступные для установки (панель берёт их с GitHub).</summary>
    public async Task<List<string>> XrayVersionsAsync()
    {
        var arr = await GetAsync("/server/getXrayVersion") as JsonArray ?? new JsonArray();
        return arr.Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "").Where(s => s.Length > 0).ToList();
    }

    public Task InstallXrayAsync(string version) => PostAsync("/server/installXray/" + Q(version));
    public Task UpdateGeoAsync() => PostAsync("/server/updateGeofile");

    /// <summary>Загрузить базу в панель (её настройки адресов/сертификатов/узла сохраняются). Панель перезапустится.</summary>
    public async Task ImportDbAsync(byte[] db)
    {
        async Task<HttpResponseMessage> SendAsync()
        {
            var content = new MultipartFormDataContent();
            var file = new ByteArrayContent(db);
            file.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
            content.Add(file, "db", "x-ui.db");
            using var req = new HttpRequestMessage(HttpMethod.Post, Url.Base + "/panel/api/server/importDB") { Content = content };
            req.Headers.Authorization = Bearer();
            try { return await _http.SendAsync(req); }
            catch (HttpRequestException ex) { throw new XuiException($"{Label}: нет связи ({ex.InnerException?.Message ?? ex.Message})"); }
            catch (TaskCanceledException) { throw new XuiException($"{Label}: таймаут"); }
        }
        var resp = await SendAsync();
        if ((int)resp.StatusCode == 401 && await RenewTokenAsync())
        {
            resp.Dispose();
            resp = await SendAsync();
        }
        using (resp)
        {
            var text = await resp.Content.ReadAsStringAsync();
            if ((int)resp.StatusCode == 401) throw Unauthorized(Label);
            if ((int)resp.StatusCode == 403) throw new XuiException($"{Label}: токену не хватает прав на загрузку базы (403) — нужен токен с правами admin");
            JsonNode? js = null;
            try { js = JsonNode.Parse(text); } catch { }
            if (js?["success"]?.GetValue<bool>() != true)
                throw new XuiException($"{Label}: база не загрузилась: {js?["msg"]?.GetValue<string>() ?? "HTTP " + (int)resp.StatusCode}");
        }
    }

    /// <summary>Ссылка подписки по настройкам панели (subURI → иначе схема/домен/порт/путь).</summary>
    public static string? SubLink(JsonObject st, PanelUrl panel, string subId, bool clash = false)
    {
        if (!J.Bool(st, clash ? "subClashEnable" : "subEnable", !clash)) return null;
        var uri = J.Str(st, clash ? "subClashURI" : "subURI");
        if (uri.Length > 0) return uri.TrimEnd('/') + "/" + subId;
        var https = J.Str(st, "subCertFile").Length > 0 || J.Str(st, "subKeyFile").Length > 0;
        var host = J.Str(st, "subDomain");
        if (host.Length == 0) host = panel.HostForUrl;
        var port = J.Int(st, "subPort");
        var path = J.Str(st, clash ? "subClashPath" : "subPath", "/sub/");
        if (!path.StartsWith('/')) path = "/" + path;
        if (!path.EndsWith('/')) path += "/";
        var scheme = https ? "https" : "http";
        var portPart = (https && port == 443) || (!https && port == 80) || port == 0 ? "" : ":" + port;
        return $"{scheme}://{host}{portPart}{path}{subId}";
    }
}

/// <summary>Терпимые геттеры JsonNode: строки/числа/булевы могут прийти чем угодно.</summary>
internal static class J
{
    public static string Str(JsonObject o, string k, string def = "")
    {
        var n = o[k];
        if (n is JsonValue v)
        {
            if (v.TryGetValue<string>(out var s)) return s ?? def;
            return v.ToJsonString().Trim('"');
        }
        return def;
    }

    public static long Long(JsonObject o, string k)
    {
        if (o[k] is JsonValue v)
        {
            if (v.TryGetValue<long>(out var l)) return l;
            if (v.TryGetValue<double>(out var d)) return (long)d;
            if (v.TryGetValue<string>(out var s) && long.TryParse(s, out var p)) return p;
        }
        return 0;
    }

    public static int Int(JsonObject o, string k) => (int)Long(o, k);

    public static double Dbl(JsonObject o, string k)
    {
        if (o[k] is JsonValue v)
        {
            if (v.TryGetValue<double>(out var d)) return d;
            if (v.TryGetValue<long>(out var l)) return l;
        }
        return 0;
    }

    public static bool Bool(JsonObject o, string k, bool def = false)
    {
        if (o[k] is JsonValue v && v.TryGetValue<bool>(out var b)) return b;
        return def;
    }
}
