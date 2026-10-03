using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text.Json;

namespace QTermWin.Sync;

/// <summary>OAuth-петля десктопа (канон мака): loopback 127.0.0.1 на
/// эфемерном порту → браузер → code → обмен на refresh token.</summary>
public static class GoogleOAuth
{
    public static async Task<string> SignInAsync()
    {
        // нет секрета в сборке — сказать сразу, а не после похода в браузер
        var secret = SyncConfig.GoogleClientSecret;
        // Свободный порт (HttpListener не умеет :0)
        int port;
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();

        var redirect = $"http://127.0.0.1:{port}/";
        var state = Guid.NewGuid().ToString();

        using var listener = new HttpListener();
        listener.Prefixes.Add(redirect);
        listener.Start();

        var authUrl = "https://accounts.google.com/o/oauth2/v2/auth" +
            "?client_id=" + Uri.EscapeDataString(SyncConfig.GoogleClientId) +
            "&redirect_uri=" + Uri.EscapeDataString(redirect) +
            "&response_type=code" +
            "&scope=" + Uri.EscapeDataString("https://www.googleapis.com/auth/drive.file") +
            "&access_type=offline&prompt=consent" +
            "&state=" + state;
        Process.Start(new ProcessStartInfo(authUrl) { UseShellExecute = true });

        var ctx = await listener.GetContextAsync().WaitAsync(TimeSpan.FromMinutes(5));
        var q = ctx.Request.QueryString;
        var html = "<html><meta charset='utf-8'><body style='font-family:sans-serif'>"
            + "QTerm: можно закрыть вкладку и вернуться в приложение.</body></html>";
        var buf = System.Text.Encoding.UTF8.GetBytes(html);
        ctx.Response.ContentType = "text/html; charset=utf-8";
        await ctx.Response.OutputStream.WriteAsync(buf);
        ctx.Response.Close();

        if (q["error"] is not null) throw new Exception("Доступ не выдан (отменено в браузере)");
        if (q["state"] != state || q["code"] is not { } code)
            throw new Exception("OAuth: нет кода / чужой state");

        using var http = new HttpClient();
        var body = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["code"] = code,
            ["client_id"] = SyncConfig.GoogleClientId,
            ["client_secret"] = secret,
            ["redirect_uri"] = redirect,
            ["grant_type"] = "authorization_code",
        });
        using var resp = await http.PostAsync("https://oauth2.googleapis.com/token", body);
        var obj = JsonDocument.Parse(await resp.Content.ReadAsStringAsync()).RootElement;
        if (!resp.IsSuccessStatusCode || !obj.TryGetProperty("refresh_token", out var rt))
        {
            var detail = obj.TryGetProperty("error", out var e) ? e.GetString() : $"HTTP {(int)resp.StatusCode}";
            throw new Exception("OAuth: " + detail);
        }
        return rt.GetString()!;
    }
}
