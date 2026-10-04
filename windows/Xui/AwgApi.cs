using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace QTermWin.Xui;

public sealed class AwgClient
{
    public string Panel = "";       // имя AWG-панели (ноды) в QTerm
    public Guid PanelId;
    public string Id = "";
    public string Name = "";
    public string InterfaceId = "";
    public string Address = "";
    public bool Enabled = true;
    public string? ExpiresAt;
    public DateTime? Handshake;
    public long Rx, Tx;
}

public sealed class AwgInterface
{
    public string Name = "";
    public int Port;
    public bool Enabled = true;
    public bool IsAwg31;
    public string Label => $"{Name} · AWG {(IsAwg31 ? "3.1" : "2.0")}";
}

/// <summary>Общий интерфейс AWG-панелей: новая awg-panel (wg-easy v15) и старая amnezia-wg-easy (v14).</summary>
public interface IAwgApi : IDisposable
{
    string Label { get; }
    Task<List<AwgInterface>> InterfacesAsync();
    Task<List<AwgClient>> ClientsAsync(XuiPanel p);
    Task CreateAsync(string name, string? interfaceId);
    Task DeleteAsync(string id);
    Task EnableAsync(string id, bool on);
    Task<string> ConfigAsync(string id);
}

/// <summary>REST API awg-panel (wg-easy v15): Basic-авторизация логином/паролем админа.
/// С включённой 2FA Basic не пускает — это ограничение самой панели.</summary>
public sealed class AwgApi : IAwgApi
{
    private static readonly JsonSerializerOptions BodyJson = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly HttpClient _http;
    public string Label { get; }
    public string Base { get; }

    public AwgApi(string label, string url, string login, string password, bool verifyTls = true)
    {
        Label = label;
        var u = PanelUrl.Parse(url);
        Base = u.Base;
        var h = new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All, UseCookies = false };
        if (!verifyTls) h.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
        _http = new HttpClient(h) { Timeout = TimeSpan.FromSeconds(30) };
        _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic",
            Convert.ToBase64String(Encoding.UTF8.GetBytes(login + ":" + password)));
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    /// <summary>Клиент API под роль панели: «awg» — awg-panel, «awg1» — старая amnezia-wg-easy.</summary>
    public static IAwgApi For(XuiPanel p) => p.IsAwgLegacy
        ? new AwgLegacyApi(p.Name, p.Url, p.Token, p.VerifyTls)
        : new AwgApi(p.Name, p.Url, p.Login, p.Token, p.VerifyTls);

    public void Dispose() => _http.Dispose();

    /// <summary>Пароль админа awg-panel (логин не меняется; от 12 символов).</summary>
    public Task ChangePasswordAsync(string current, string newPass) =>
        SendAsync(HttpMethod.Post, "/me/password", new { currentPassword = current, newPassword = newPass, confirmPassword = newPass });

    private async Task<string> SendAsync(HttpMethod m, string path, object? body = null)
    {
        using var req = new HttpRequestMessage(m, Base + "/api" + path);
        if (body is not null)
            req.Content = new StringContent(JsonSerializer.Serialize(body, BodyJson), Encoding.UTF8, "application/json");
        HttpResponseMessage resp;
        try { resp = await _http.SendAsync(req); }
        catch (HttpRequestException ex) when (ex.InnerException is AuthenticationException)
        { throw new XuiException($"{Label}: сертификат не прошёл проверку ({ex.InnerException.Message})"); }
        catch (HttpRequestException ex)
        { throw new XuiException($"{Label}: нет связи ({ex.InnerException?.Message ?? ex.Message})"); }
        catch (TaskCanceledException)
        { throw new XuiException($"{Label}: таймаут"); }
        using (resp)
        {
            var text = await resp.Content.ReadAsStringAsync();
            var code = (int)resp.StatusCode;
            if (code is 401) throw new XuiException($"{Label}: логин/пароль не подошли (401). С включённой 2FA вход по API невозможен");
            if (code is 403) throw new XuiException($"{Label}: 403 — {Msg(text) ?? "доступ запрещён"}");
            if (code is 404) throw new XuiException($"{Label}: 404 на {path} — это точно адрес awg-panel?");
            if (code >= 400) throw new XuiException($"{Label}: HTTP {code} {Msg(text)}");
            return text;
        }
    }

    private static string? Msg(string body)
    {
        try { return JsonNode.Parse(body)?["message"]?.GetValue<string>(); } catch { return null; }
    }

    private static DateTime? Date(JsonNode? n)
    {
        if (n is JsonValue v && v.TryGetValue<string>(out var s) && DateTime.TryParse(s, null,
                System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var d))
            return d;
        return null;
    }

    public async Task<List<AwgInterface>> InterfacesAsync()
    {
        var arr = JsonNode.Parse(await SendAsync(HttpMethod.Get, "/interfaces")) as JsonArray ?? new JsonArray();
        return arr.OfType<JsonObject>().Select(o => new AwgInterface
        {
            Name = J.Str(o, "name"), Port = J.Int(o, "port"),
            Enabled = J.Bool(o, "enabled", true), IsAwg31 = J.Bool(o, "isAwg31"),
        }).ToList();
    }

    public async Task<List<AwgClient>> ClientsAsync(XuiPanel p)
    {
        var arr = JsonNode.Parse(await SendAsync(HttpMethod.Get, "/client")) as JsonArray ?? new JsonArray();
        return arr.OfType<JsonObject>().Select(o => new AwgClient
        {
            Panel = p.Name, PanelId = p.Id,
            Id = J.Str(o, "id"),
            Name = J.Str(o, "name"),
            InterfaceId = J.Str(o, "interfaceId", "wg0"),
            Address = J.Str(o, "ipv4Address"),
            Enabled = J.Bool(o, "enabled", true),
            ExpiresAt = o["expiresAt"] is JsonValue ev && ev.TryGetValue<string>(out var es) ? es : null,
            Handshake = Date(o["latestHandshakeAt"]),
            Rx = J.Long(o, "transferRx"),
            Tx = J.Long(o, "transferTx"),
        }).ToList();
    }

    public Task CreateAsync(string name, string? interfaceId) =>
        SendAsync(HttpMethod.Post, "/client", interfaceId is null
            ? (object)new { name, expiresAt = (string?)null }
            : new { name, expiresAt = (string?)null, interfaceId });

    public Task DeleteAsync(string id) => SendAsync(HttpMethod.Delete, "/client/" + Uri.EscapeDataString(id));
    public Task EnableAsync(string id, bool on) =>
        SendAsync(HttpMethod.Post, "/client/" + Uri.EscapeDataString(id) + (on ? "/enable" : "/disable"));
    public Task<string> ConfigAsync(string id) =>
        SendAsync(HttpMethod.Get, "/client/" + Uri.EscapeDataString(id) + "/configuration");

    public Task InfoAsync() => SendAsync(HttpMethod.Get, "/information");
}

/// <summary>Старая amnezia-wg-easy (форк wg-easy v14, установщик awg-v2): только пароль.
/// Вход — POST {base}/api/session {password} → cookie сессии; клиенты — /api/wireguard/client.
/// Интерфейс один (wg0, AWG 2.0).</summary>
public sealed class AwgLegacyApi : IAwgApi
{
    private static readonly JsonSerializerOptions BodyJson = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly HttpClient _http;
    private readonly string _password;
    private bool _authed;
    public string Label { get; }
    public string Base { get; }

    public AwgLegacyApi(string label, string url, string password, bool verifyTls = true)
    {
        Label = label;
        Base = PanelUrl.Parse(url).Base;
        _password = password;
        var h = new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            UseCookies = true,
            CookieContainer = new CookieContainer(),
        };
        if (!verifyTls) h.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
        _http = new HttpClient(h) { Timeout = TimeSpan.FromSeconds(30) };
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    public void Dispose() => _http.Dispose();

    private async Task<(int Code, string Text)> RawAsync(HttpMethod m, string path, object? body = null)
    {
        using var req = new HttpRequestMessage(m, Base + "/api" + path);
        if (body is not null)
            req.Content = new StringContent(JsonSerializer.Serialize(body, BodyJson), Encoding.UTF8, "application/json");
        try
        {
            using var resp = await _http.SendAsync(req);
            return ((int)resp.StatusCode, await resp.Content.ReadAsStringAsync());
        }
        catch (HttpRequestException ex) when (ex.InnerException is AuthenticationException)
        { throw new XuiException($"{Label}: сертификат не прошёл проверку ({ex.InnerException.Message})"); }
        catch (HttpRequestException ex)
        { throw new XuiException($"{Label}: нет связи ({ex.InnerException?.Message ?? ex.Message})"); }
        catch (TaskCanceledException)
        { throw new XuiException($"{Label}: таймаут"); }
    }

    private static string? Msg(string body)
    {
        try
        {
            var n = JsonNode.Parse(body);
            return n?["message"]?.GetValue<string>() ?? n?["error"]?.GetValue<string>();
        }
        catch { return null; }
    }

    private async Task LoginAsync()
    {
        var (code, text) = await RawAsync(HttpMethod.Post, "/session", new { password = _password });
        if (code == 401)
        {
            // панель без пароля (PASSWORD не задан) — API открыт и так
            var (c2, t2) = await RawAsync(HttpMethod.Get, "/session");
            bool open = false;
            try { open = c2 == 200 && JsonNode.Parse(t2)?["requiresPassword"]?.GetValue<bool>() == false; } catch { }
            if (open) { _authed = true; return; }
            throw new XuiException($"{Label}: пароль не подошёл (401)");
        }
        if (code == 404) throw new XuiException($"{Label}: 404 на /api/session — проверь адрес панели (с секретным путём в конце)");
        if (code >= 400) throw new XuiException($"{Label}: вход — HTTP {code} {Msg(text)}");
        _authed = true;
    }

    private async Task<string> SendAsync(HttpMethod m, string path, object? body = null)
    {
        if (!_authed) await LoginAsync();
        var (code, text) = await RawAsync(m, path, body);
        if (code == 401)
        {
            // сессия протухла (контейнер перезапускали — секрет сессий новый) — один перелогин
            _authed = false;
            await LoginAsync();
            (code, text) = await RawAsync(m, path, body);
        }
        if (code == 401) throw new XuiException($"{Label}: панель не пускает (401) — пароль сменился?");
        if (code == 404) throw new XuiException($"{Label}: 404 на {path} — это точно старая amnezia-wg-easy?");
        if (code >= 400) throw new XuiException($"{Label}: HTTP {code} {Msg(text)}");
        return text;
    }

    private static DateTime? Date(JsonNode? n)
    {
        if (n is JsonValue v && v.TryGetValue<string>(out var s) && DateTime.TryParse(s, null,
                System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var d))
            return d;
        return null;
    }

    public Task<List<AwgInterface>> InterfacesAsync() =>
        Task.FromResult(new List<AwgInterface> { new() { Name = "wg0", Enabled = true, IsAwg31 = false } });

    public async Task<List<AwgClient>> ClientsAsync(XuiPanel p)
    {
        var text = await SendAsync(HttpMethod.Get, "/wireguard/client");
        JsonArray arr;
        try { arr = JsonNode.Parse(text) as JsonArray ?? new JsonArray(); }
        catch { throw new XuiException($"{Label}: вместо списка клиентов пришёл не JSON — адрес панели без секретного пути?"); }
        return arr.OfType<JsonObject>().Select(o => new AwgClient
        {
            Panel = p.Name, PanelId = p.Id,
            Id = J.Str(o, "id"),
            Name = J.Str(o, "name"),
            InterfaceId = "wg0",
            Address = J.Str(o, "address"),
            Enabled = J.Bool(o, "enabled", true),
            Handshake = Date(o["latestHandshakeAt"]),
            Rx = J.Long(o, "transferRx"),
            Tx = J.Long(o, "transferTx"),
        }).ToList();
    }

    public Task CreateAsync(string name, string? interfaceId) =>
        SendAsync(HttpMethod.Post, "/wireguard/client", new { name });

    public Task DeleteAsync(string id) => SendAsync(HttpMethod.Delete, "/wireguard/client/" + Uri.EscapeDataString(id));
    public Task EnableAsync(string id, bool on) =>
        SendAsync(HttpMethod.Post, "/wireguard/client/" + Uri.EscapeDataString(id) + (on ? "/enable" : "/disable"));
    public Task<string> ConfigAsync(string id) =>
        SendAsync(HttpMethod.Get, "/wireguard/client/" + Uri.EscapeDataString(id) + "/configuration");
}

/// <summary>Проверка AWG-панели: вид определяется сам (правит p.Role), вход, чтение клиентов.</summary>
public static class AwgProbe
{
    public static async Task<string> TestAsync(XuiPanel p)
    {
        var kind = await PanelProbe.DetectAsync(p.Url, p.VerifyTls);
        if (kind == PanelProbe.Xui) throw new XuiException("по этому адресу 3x-ui, а не AWG");
        kind ??= p.Login.Length > 0 ? PanelProbe.Awg : PanelProbe.AwgOld;
        p.Role = kind;
        if (kind == PanelProbe.Awg && p.Login.Length == 0)
            throw new XuiException("это новая awg-panel — нужен логин админа");
        if (kind == PanelProbe.AwgOld) p.Login = "";
        using var api = AwgApi.For(p);
        var ifs = await api.InterfacesAsync();
        var cl = await api.ClientsAsync(p);
        return $"✓ {PanelProbe.Text(kind)}: {string.Join(", ", ifs.Select(i => i.Label))}; клиентов {cl.Count}";
    }
}
