using System.Net;
using System.Net.Http;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Org.BouncyCastle.Math.EC.Rfc8032;

namespace QTermWin.QDash;

/// <summary>Ошибка хаба с кодом и телом (JSON хаба разобран, если был).</summary>
public sealed class QDashError : Exception
{
    public int Status { get; }
    public JsonObject? Body { get; }
    /// <summary>401 с login:true — подпись/время/номер/отозванный ключ: ходить дальше бессмысленно.</summary>
    public bool Login => Body?["login"]?.GetValue<bool>() == true;
    public QDashError(int status, string message, JsonObject? body) : base(message) { Status = status; Body = body; }
}

/// <summary>
/// Клиент хаба QDash по ключу устройства — зеркало tools/qdcli.js хаба:
/// каждый запрос подписывается ed25519 (QDASH1 \n МЕТОД \n путь?параметры \n время \n разовый номер \n sha256(тело)),
/// серт хаба пинится по отпечатку (как host key в SSH), а не по цепочке. Опасное действие хаб может закрыть кодом 2FA
/// (403 + X-QDash-Need: totp) — тогда спрашиваем код (<see cref="AskCode"/>), открываем окно (/api/sec/unlock) и повторяем.
/// Пути: сначала локалка (/api/dev → lan), потом внешний адрес; который ответил — тот и держим.
/// </summary>
public sealed class QDashClient : IDisposable
{
    public sealed record Route(string Url, string Fp);

    public QDashHub Hub { get; }
    public QDashKey? Key { get; private set; }
    public IReadOnlyList<Route> Routes => _routes;
    /// <summary>Путь, которым сейчас ходим (после первого удачного запроса).</summary>
    public Route? Active { get; private set; }

    /// <summary>Спросить код 2FA (what — что за действие, tierName — тир). null — отмена.</summary>
    public Func<string, string, Task<string?>>? AskCode { get; set; }

    private readonly List<Route> _routes;
    private readonly Dictionary<string, HttpClient> _http = new();
    private readonly object _lock = new();
    private readonly byte[]? _priv;

    public QDashClient(QDashHub hub, QDashKey? key)
    {
        Hub = hub;
        Key = key;
        _routes = BuildRoutes(hub);
        if (key is not null && key.Priv.Length > 0) _priv = Convert.FromBase64String(key.Priv);
    }

    private static List<Route> BuildRoutes(QDashHub hub)
    {
        var list = new List<Route>();
        foreach (var u in hub.Lan ?? new())
            if (u.Length > 0) list.Add(new Route(u.TrimEnd('/'), Norm(hub.LanFp ?? "")));
        if (hub.Url.Length > 0) list.Add(new Route(hub.Url.TrimEnd('/'), Norm(hub.Fp)));
        return list;
    }

    /// <summary>Отпечаток к виду hex строчными без «sha256:» и двоеточий.</summary>
    public static string Norm(string fp)
    {
        fp = fp.Trim();
        if (fp.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) fp = fp[7..];
        return fp.Replace(":", "").ToLowerInvariant();
    }

    public void Dispose()
    {
        lock (_lock)
        {
            foreach (var c in _http.Values) c.Dispose();
            _http.Clear();
        }
    }

    // ── ключи ──

    /// <summary>Новая пара ed25519: seed 32 байта (приватная половина) + публичный ключ.</summary>
    public static (byte[] Priv, byte[] Pub) NewKeyPair()
    {
        var sk = RandomNumberGenerator.GetBytes(Ed25519.SecretKeySize);
        var pk = new byte[Ed25519.PublicKeySize];
        Ed25519.GeneratePublicKey(sk, 0, pk, 0);
        return (sk, pk);
    }

    private static byte[] Sign(byte[] priv, byte[] msg)
    {
        var sig = new byte[Ed25519.SignatureSize];
        Ed25519.Sign(priv, 0, msg, 0, msg.Length, sig, 0);
        return sig;
    }

    private static string Nonce()
    {
        var b = RandomNumberGenerator.GetBytes(12);
        return Convert.ToHexString(b).ToLowerInvariant(); // 24 знака [0-9a-f]
    }

    // ── транспорт ──

    private HttpClient HttpFor(Route r)
    {
        lock (_lock)
        {
            if (_http.TryGetValue(r.Url, out var c)) return c;
            var isHttps = r.Url.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
            if (!isHttps && r.Fp.Length > 0)
                throw new InvalidOperationException($"адрес {r.Url} без HTTPS, а отпечаток серта задан — так ходить нельзя");
            var h = new SocketsHttpHandler
            {
                ConnectTimeout = TimeSpan.FromSeconds(6),
                PooledConnectionLifetime = TimeSpan.FromMinutes(10),
                AutomaticDecompression = DecompressionMethods.None,
                UseCookies = false,
                AllowAutoRedirect = false,
            };
            if (isHttps)
            {
                var want = r.Fp;
                h.SslOptions = new SslClientAuthenticationOptions
                {
                    // свой серт хаба: доверяем по отпечатку, имя хоста (CN=qdash) не проверяем
                    RemoteCertificateValidationCallback = (_, cert, _, errors) =>
                    {
                        if (cert is null) return false;
                        if (want.Length == 0) return errors == SslPolicyErrors.None;
                        var got = Convert.ToHexString(SHA256.HashData(cert.GetRawCertData())).ToLowerInvariant();
                        return string.Equals(got, want, StringComparison.Ordinal);
                    },
                };
            }
            c = new HttpClient(h) { Timeout = TimeSpan.FromSeconds(70) }; // /api/jobs/out ждёт до 2 с; задачи — дольше
            c.DefaultRequestHeaders.UserAgent.ParseAdd("QTerm-qdash/" + WaveMarker.Version);
            _http[r.Url] = c;
            return c;
        }
    }

    public sealed record Reply(int Status, string Body, string Need)
    {
        public JsonObject? Json
        {
            get
            {
                try { return JsonNode.Parse(Body) as JsonObject; } catch { return null; }
            }
        }
    }

    /// <summary>Один HTTP-запрос по конкретному пути (без ретраев по маршрутам).</summary>
    private async Task<Reply> SendAsync(Route r, string method, string uri, string? body, bool signed, CancellationToken ct)
    {
        var http = HttpFor(r);
        using var req = new HttpRequestMessage(new HttpMethod(method), r.Url + uri);
        if (body is not null)
            req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        if (signed)
        {
            if (_priv is null || Key is null) throw new QDashError(401, "ключ устройства не заведён", null);
            var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
            var nonce = Nonce();
            var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(body ?? ""))).ToLowerInvariant();
            var basis = string.Join("\n", "QDASH1", method.ToUpperInvariant(), uri, ts, nonce, hash);
            req.Headers.TryAddWithoutValidation("X-QD-Device", Key.Dev);
            req.Headers.TryAddWithoutValidation("X-QD-Time", ts);
            req.Headers.TryAddWithoutValidation("X-QD-Nonce", nonce);
            req.Headers.TryAddWithoutValidation("X-QD-Sig", Convert.ToBase64String(Sign(_priv, Encoding.UTF8.GetBytes(basis))));
        }
        using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct).ConfigureAwait(false);
        var text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        var need = resp.Headers.TryGetValues("X-QDash-Need", out var nv) ? (nv.FirstOrDefault() ?? "") : "";
        return new Reply((int)resp.StatusCode, text, need);
    }

    /// <summary>Запрос с перебором путей: локалка → внешний; ответивший путь запоминается.
    /// Сетевые ошибки (не дотянулись) переключают путь, ответ хаба (любой код) — нет.</summary>
    private async Task<Reply> SendAnyAsync(string method, string uri, string? body, bool signed, CancellationToken ct)
    {
        if (_routes.Count == 0) throw new QDashError(0, "у хаба нет адреса", null);
        var order = new List<Route>();
        if (Active is not null) order.Add(Active);
        foreach (var r in _routes) if (!order.Contains(r)) order.Add(r);
        Exception? last = null;
        foreach (var r in order)
        {
            try
            {
                var rep = await SendAsync(r, method, uri, body, signed, ct).ConfigureAwait(false);
                Active = r;
                return rep;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (HttpRequestException ex) { last = ex; }
            catch (TaskCanceledException ex) { last = ex; } // таймаут соединения
            catch (InvalidOperationException ex) { last = ex; } // http без пина
            if (Active == r) Active = null;
        }
        throw new QDashError(0, "хаб не отвечает: " + Short(last), null);
    }

    private static string Short(Exception? ex)
    {
        if (ex is null) return "";
        var m = ex.InnerException?.Message is { Length: > 0 } inner && ex is HttpRequestException ? inner : ex.Message;
        return m.Length > 160 ? m[..160] + "…" : m;
    }

    private static string ErrText(Reply rep)
    {
        var j = rep.Json;
        if (j?["error"] is { } e) return e.ToString();
        var t = rep.Body.Trim();
        return t.Length > 0 ? (t.Length > 200 ? t[..200] + "…" : t) : $"HTTP {rep.Status}";
    }

    /// <summary>Подписанный запрос. 403 с need:totp → код → unlock → повтор (один раз).
    /// Возвращает тело как JSON (объект); хаб иногда шлёт 200 с ok:false — вызывающий проверяет ok сам.</summary>
    public async Task<JsonObject> CallAsync(string method, string uri, object? body = null, CancellationToken ct = default)
    {
        var text = body is null ? null : body as string ?? JsonSerializer.Serialize(body, JsonOpts);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var rep = await SendAnyAsync(method, uri, text, signed: true, ct).ConfigureAwait(false);
            if (rep.Status == 403 && (rep.Need == "totp" || rep.Json?["need"]?.ToString() == "totp") && attempt == 0)
            {
                var j = rep.Json;
                var what = j?["what"]?.ToString() ?? uri;
                var tierName = j?["tierName"]?.ToString() ?? "опасное";
                var tier = j?["tier"]?.GetValue<int>() ?? 2;
                if (AskCode is null) throw new QDashError(403, "нужен код подтверждения (2FA): " + what, j);
                var code = await AskCode(what, tierName).ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(code)) throw new QDashError(403, "отменено: код не введён", j);
                await UnlockAsync(code.Trim(), tier, ct).ConfigureAwait(false);
                continue; // повтор с новым номером и подписью
            }
            if (rep.Status >= 400) throw new QDashError(rep.Status, ErrText(rep), rep.Json);
            return rep.Json ?? new JsonObject { ["ok"] = true, ["text"] = rep.Body };
        }
        throw new QDashError(403, "код принят, но действие всё равно отклонено", null);
    }

    public Task<JsonObject> GetAsync(string uri, CancellationToken ct = default) => CallAsync("GET", uri, null, ct);
    public Task<JsonObject> PostAsync(string uri, object body, CancellationToken ct = default) => CallAsync("POST", uri, body, ct);

    /// <summary>GET, у которого ответ — массив (например /api/vps, /api/jobs).</summary>
    public async Task<JsonArray> GetArrayAsync(string uri, CancellationToken ct = default)
    {
        var rep = await SendAnyAsync("GET", uri, null, signed: true, ct).ConfigureAwait(false);
        if (rep.Status >= 400) throw new QDashError(rep.Status, ErrText(rep), rep.Json);
        try { return JsonNode.Parse(rep.Body) as JsonArray ?? new JsonArray(); }
        catch { throw new QDashError(rep.Status, "хаб ответил не JSON", null); }
    }

    /// <summary>Открыть окно тира кодом 2FA (TOTP или код восстановления).</summary>
    public async Task<long> UnlockAsync(string code, int tier, CancellationToken ct = default)
    {
        var rep = await SendAnyAsync("POST", "/api/sec/unlock", JsonSerializer.Serialize(new { code, tier }), signed: true, ct).ConfigureAwait(false);
        var j = rep.Json;
        if (rep.Status >= 400 || j?["ok"]?.GetValue<bool>() != true)
            throw new QDashError(rep.Status, ErrText(rep), j);
        return j?["until"]?.GetValue<long>() ?? 0;
    }

    // ── заведение ──

    /// <summary>Разбор ссылки из портала: qdash://enroll?c=КОД&amp;f=sha256:…&amp;n=имя&amp;u=https://host:port</summary>
    public static bool TryParseEnrollLink(string text, out string url, out string code, out string fp, out string name)
    {
        url = code = fp = name = "";
        text = text.Trim();
        if (!text.StartsWith("qdash://", StringComparison.OrdinalIgnoreCase)) return false;
        Uri u;
        try { u = new Uri("https://" + text[8..]); } catch { return false; }
        var q = System.Web.HttpUtility.ParseQueryString(u.Query);
        url = (q["u"] ?? "").TrimEnd('/');
        code = q["c"] ?? "";
        fp = Norm(q["f"] ?? "");
        name = q["n"] ?? "";
        return url.Length > 0 && code.Length > 0;
    }

    /// <summary>POST /api/dev/claim без подписи: новая пара создаётся здесь, хабу уходит только публичная половина.
    /// Возвращает ключ, который надо сохранить (<see cref="QDashStore.SaveKey"/>).</summary>
    public static async Task<(QDashKey Key, string Host, string Version)> ClaimAsync(string url, string fp, string code, string name, CancellationToken ct = default)
    {
        var hub = new QDashHub { Url = url.TrimEnd('/'), Fp = Norm(fp) };
        using var tmp = new QDashClient(hub, null);
        var (priv, pub) = NewKeyPair();
        var body = JsonSerializer.Serialize(new { code = code.Trim().ToUpperInvariant(), pub = Convert.ToBase64String(pub), kind = "qterm", name });
        var rep = await tmp.SendAnyAsync("POST", "/api/dev/claim", body, signed: false, ct).ConfigureAwait(false);
        var j = rep.Json;
        if (rep.Status >= 400 || j?["ok"]?.GetValue<bool>() != true)
            throw new QDashError(rep.Status, "не завелось: " + ErrText(rep), j);
        var key = new QDashKey
        {
            Dev = j["id"]?.ToString() ?? "",
            Pub = Convert.ToBase64String(pub),
            Priv = Convert.ToBase64String(priv),
            Role = j["role"]?.ToString() ?? "",
            RoleName = j["roleName"]?.ToString() ?? "",
            Name = j["name"]?.ToString() ?? name,
            ClaimedAt = Models.QtJson.NowIso(),
        };
        CryptographicOperations.ZeroMemory(priv);
        return (key, j["host"]?.ToString() ?? "", j["version"]?.ToString() ?? "");
    }

    /// <summary>GET /api/dev/whoami → {id, name, role, roleName, tier, tierName, host, version}.</summary>
    public async Task<JsonObject> WhoAmIAsync(CancellationToken ct = default)
    {
        var j = await GetAsync("/api/dev/whoami", ct).ConfigureAwait(false);
        if (Key is not null)
        {
            Key.Role = j["role"]?.ToString() ?? Key.Role;
            Key.RoleName = j["roleName"]?.ToString() ?? Key.RoleName;
            Key.Name = j["name"]?.ToString() ?? Key.Name;
        }
        return j;
    }

    /// <summary>Роль ключа → потолок тира (read 0 · ops 1 · full 2); неизвестная — чтение (как у хаба).</summary>
    public int RoleTier => Key?.Role switch { "ops" => 1, "full" => 2, _ => 0 };

    public bool Can(int tier) => RoleTier >= tier;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}
