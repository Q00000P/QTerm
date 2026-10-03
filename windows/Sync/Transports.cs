using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace QTermWin.Sync;

public interface ISyncTransport
{
    /// <summary>null = файла ещё нет (первый пуш).</summary>
    Task<byte[]?> GetAsync();
    Task PutAsync(byte[] data);
}

/// <summary>WebDAV GET/PUT + Basic; Яндекс = webdav.yandex.ru (пароль приложения).
/// На PUT 409/404 — MKCOL родительской папки и повтор (Яндекс-канон).</summary>
public sealed class WebDavTransport : ISyncTransport
{
    private readonly HttpClient _http;
    private readonly Uri _url;

    public WebDavTransport(string url, string login, string password)
    {
        _url = new Uri(url);
        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(25) };
        _http.DefaultRequestHeaders.Authorization = new(
            "Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{login}:{password}")));
    }

    private static Exception Http(int code) => new Exception(code switch
    {
        401 => "WebDAV: неверный логин/пароль (401)",
        403 => "WebDAV: доступ запрещён (403)",
        _ => $"WebDAV: HTTP {code}",
    });

    public async Task<byte[]?> GetAsync()
    {
        using var resp = await _http.GetAsync(_url);
        if (resp.StatusCode == HttpStatusCode.NotFound) return null;
        if (!resp.IsSuccessStatusCode) throw Http((int)resp.StatusCode);
        return await resp.Content.ReadAsByteArrayAsync();
    }

    public async Task PutAsync(byte[] data)
    {
        if (await TryPut(data) is { } code)
        {
            if (code is 409 or 404)
            {
                await Mkcol();
                if (await TryPut(data) is { } code2) throw Http(code2);
            }
            else throw Http(code);
        }
    }

    private async Task<int?> TryPut(byte[] data)
    {
        using var content = new ByteArrayContent(data);
        content.Headers.ContentType = new("application/octet-stream");
        using var resp = await _http.PutAsync(_url, content);
        return resp.IsSuccessStatusCode ? null : (int)resp.StatusCode;
    }

    private async Task Mkcol()
    {
        var parent = new Uri(_url, "."); // папка файла
        using var req = new HttpRequestMessage(new HttpMethod("MKCOL"), parent);
        using var resp = await _http.SendAsync(req); // 405 = уже есть, ок
    }
}

/// <summary>Google Drive — контракт мак/андроид: scope drive.file, папка по
/// имени (дефолт QTerm), файл vault.qtsync, refresh на каждый цикл,
/// создание POST metadata → PATCH uploadType=media, download alt=media.</summary>
public sealed class GDriveTransport : ISyncTransport
{
    private const string FileName = "vault.qtsync";
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly string _refreshToken;
    private readonly string _folderName;

    public GDriveTransport(string refreshToken, string folderName)
    {
        _refreshToken = refreshToken;
        _folderName = string.IsNullOrWhiteSpace(folderName) ? "QTerm" : folderName;
    }

    private static JsonElement Parse(string s) => JsonDocument.Parse(s).RootElement.Clone();

    private async Task<string> AccessToken()
    {
        var body = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = SyncConfig.GoogleClientId,
            ["client_secret"] = SyncConfig.GoogleClientSecret,
            ["refresh_token"] = _refreshToken,
            ["grant_type"] = "refresh_token",
        });
        using var resp = await _http.PostAsync("https://oauth2.googleapis.com/token", body);
        var obj = Parse(await resp.Content.ReadAsStringAsync());
        if (!resp.IsSuccessStatusCode || !obj.TryGetProperty("access_token", out var tok))
        {
            var detail = obj.TryGetProperty("error", out var err) ? err.GetString() : $"HTTP {(int)resp.StatusCode}";
            throw new Exception($"Google: не обновился токен ({detail}) — «Войти в Google» заново");
        }
        return tok.GetString()!;
    }

    private async Task<JsonElement> Run(HttpRequestMessage req, string ctx)
    {
        using var resp = await _http.SendAsync(req);
        var text = await resp.Content.ReadAsStringAsync();
        if (!resp.IsSuccessStatusCode && resp.StatusCode != HttpStatusCode.NotFound)
            throw new Exception($"Google Drive: HTTP {(int)resp.StatusCode} ({ctx})");
        return text.Length > 0 && text.TrimStart().StartsWith('{') ? Parse(text) : default;
    }

    private HttpRequestMessage Req(string url, HttpMethod method, string token,
        HttpContent? content = null)
    {
        var r = new HttpRequestMessage(method, url) { Content = content };
        r.Headers.Authorization = new("Bearer", token);
        return r;
    }

    private async Task<string?> QueryId(string token, string q, string ctx)
    {
        var url = "https://www.googleapis.com/drive/v3/files?q=" + Uri.EscapeDataString(q)
            + "&fields=" + Uri.EscapeDataString("files(id,name)") + "&spaces=drive";
        var obj = await Run(Req(url, HttpMethod.Get, token), ctx);
        if (obj.ValueKind != JsonValueKind.Object) return null;
        var files = obj.GetProperty("files");
        return files.GetArrayLength() > 0 ? files[0].GetProperty("id").GetString() : null;
    }

    private async Task<string?> FolderId(string token, bool createIfMissing)
    {
        var name = _folderName.Replace("'", "\\'");
        var id = await QueryId(token,
            $"name = '{name}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
            "поиск папки");
        if (id is not null || !createIfMissing) return id;
        var meta = new StringContent(
            JsonSerializer.Serialize(new { name = _folderName, mimeType = "application/vnd.google-apps.folder" }),
            Encoding.UTF8, "application/json");
        var obj = await Run(Req("https://www.googleapis.com/drive/v3/files?fields=id",
            HttpMethod.Post, token, meta), "создание папки");
        return obj.GetProperty("id").GetString();
    }

    private Task<string?> FileId(string token, string folder) =>
        QueryId(token, $"name = '{FileName}' and '{folder}' in parents and trashed = false", "поиск файла");

    public async Task<byte[]?> GetAsync()
    {
        var token = await AccessToken();
        var folder = await FolderId(token, createIfMissing: false);
        if (folder is null) return null;
        var file = await FileId(token, folder);
        if (file is null) return null;
        using var resp = await _http.SendAsync(Req(
            $"https://www.googleapis.com/drive/v3/files/{file}?alt=media", HttpMethod.Get, token));
        if (resp.StatusCode == HttpStatusCode.NotFound) return null;
        if (!resp.IsSuccessStatusCode)
            throw new Exception($"Google Drive: HTTP {(int)resp.StatusCode} (скачивание)");
        return await resp.Content.ReadAsByteArrayAsync();
    }

    public async Task PutAsync(byte[] data)
    {
        var token = await AccessToken();
        var folder = await FolderId(token, createIfMissing: true)
            ?? throw new Exception("Google Drive: не создалась папка");
        var file = await FileId(token, folder);
        if (file is null)
        {
            var meta = new StringContent(
                JsonSerializer.Serialize(new { name = FileName, parents = new[] { folder } }),
                Encoding.UTF8, "application/json");
            var obj = await Run(Req("https://www.googleapis.com/drive/v3/files?fields=id",
                HttpMethod.Post, token, meta), "создание файла");
            file = obj.GetProperty("id").GetString();
        }
        var content = new ByteArrayContent(data);
        content.Headers.ContentType = new("application/octet-stream");
        await Run(Req($"https://www.googleapis.com/upload/drive/v3/files/{file}?uploadType=media",
            HttpMethod.Patch, token!, content), "заливка");
    }
}
