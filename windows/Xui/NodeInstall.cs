using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace QTermWin.Xui;

/// <summary>Одна панель из итога установщика: адрес + логин/пароль. Kind — догадка по заголовку раздела
/// («xui» | «awg» | ""), точный вид определяет <see cref="PanelProbe"/>.</summary>
public sealed class InstallBlock
{
    public string Kind = "";
    public string Url = "";
    public string Login = "";
    public string Password = "";
    public string Server = "";
    public string Title = "";

    /// <summary>Имя ноды по умолчанию — первая метка домена: design.repmac.shop → DESIGN.</summary>
    public string SuggestName()
    {
        try
        {
            var h = PanelUrl.Parse(Url).Host;
            return IPAddress.TryParse(h, out _) ? h : h.Split('.')[0].ToUpperInvariant();
        }
        catch { return ""; }
    }

    public string Host
    {
        get { try { return PanelUrl.Parse(Url).Host; } catch { return ""; } }
    }
}

/// <summary>Разбор итога установщика (selfsni / 3x-ui install.sh / awg-v2 / awg-panel), выделенного в терминале.
/// Разделы «=== … ===» / «### … ###»: AdGuard, команды, обфускация пропускаются (у AdGuard свои логин/пароль).
/// В одном выделении может быть несколько панелей (selfsni печатает и 3x-ui, и AWG).</summary>
public static class InstallParser
{
    private static readonly Regex Ansi = new(@"\x1B\[[0-9;?]*[A-Za-z]|\x1B\][^\x07]*\x07", RegexOptions.Compiled);
    private static readonly Regex Section = new(@"^\s*[=#\-*]{2,}\s*(.*?)\s*[=#\-*]{2,}\s*$", RegexOptions.Compiled);
    private static readonly Regex Kv = new(@"^\s*([A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё0-9 _/\-]{0,30}?)\s*:\s+(\S.*?)\s*$", RegexOptions.Compiled);
    private static readonly Regex Http = new(@"https?://[^\s'""<>]+", RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly string[] UrlKeys =
        { "panel", "panel url", "url", "web ui", "webui", "web", "access url", "web panel", "панель", "адрес", "адрес панели", "url панели" };
    private static readonly string[] PassKeys = { "password", "pass", "admin password", "пароль" };
    private static readonly string[] UserKeys = { "username", "user", "login", "логин", "пользователь" };
    private static readonly string[] ServerKeys = { "server", "endpoint", "сервер" };

    private static string KindOf(string title)
    {
        var t = title.ToLowerInvariant();
        if (t.Contains("3x-ui") || t.Contains("x-ui") || t.Contains("xui") || t.Contains("vless") || t.Contains("reality")) return "xui";
        if (t.Contains("amnezia") || t.Contains("awg") || t.Contains("wireguard")) return "awg";
        return "";
    }

    private static bool Skip(string title)
    {
        var t = title.ToLowerInvariant();
        return t.Contains("adguard") || t.Contains("command") || t.Contains("команд") || t.Contains("obfusc") || t.Contains("обфуск");
    }

    private static bool IsAdg(string url) => url.TrimEnd('/').EndsWith("/adg", StringComparison.OrdinalIgnoreCase);

    public static List<InstallBlock> Parse(string? text)
    {
        var list = new List<InstallBlock>();
        if (string.IsNullOrWhiteSpace(text)) return list;
        text = Ansi.Replace(text, "");
        var cur = new InstallBlock();
        var skip = false;
        var title = "";

        void Flush()
        {
            if (cur.Url.Length > 0) list.Add(cur);
            else if (list.Count > 0 && cur.Password.Length > 0 && list[^1].Password.Length == 0)
            {
                // пароль ниже URL, но в своём «разделе» (3x-ui печатает их между ####-полосками)
                list[^1].Password = cur.Password;
                if (list[^1].Login.Length == 0) list[^1].Login = cur.Login;
            }
            var keepTitle = cur.Title;
            cur = new InstallBlock { Title = keepTitle };
        }

        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            var line = raw.TrimEnd();
            if (line.Contains("INSTALLATION COMPLETE", StringComparison.OrdinalIgnoreCase))
            {
                var i = line.IndexOf('-');
                title = i >= 0 ? line[(i + 1)..].Trim(' ', '=', '-', '#') : "";
                cur.Title = title;
                continue;
            }
            var sm = Section.Match(line);
            if (sm.Success && !Kv.IsMatch(line))
            {
                var name = sm.Groups[1].Value;
                // голая полоска «#####» без названия: после пропускаемого раздела (команды, AdGuard) — новый блок;
                // иначе не новый раздел, пока в текущем нет адреса и пароля
                if (name.Length == 0 && !skip && (cur.Url.Length == 0 || cur.Password.Length == 0)) continue;
                Flush();
                skip = Skip(name);
                cur.Kind = KindOf(name);
                if (name.Length > 0 && !skip) cur.Title = title.Length > 0 ? $"{title} · {name}" : name;
                continue;
            }
            if (skip) continue;
            var m = Kv.Match(line);
            if (!m.Success) continue;
            var key = m.Groups[1].Value.Trim().ToLowerInvariant();
            var val = m.Groups[2].Value.Trim().Trim('"', '\'');
            if (UrlKeys.Contains(key))
            {
                var u = Http.Match(val);
                if (!u.Success || IsAdg(u.Value)) continue;
                if (cur.Url.Length > 0 && cur.Url != u.Value)
                {
                    // вторая панель без заголовка раздела — новый блок
                    var kind = cur.Kind;
                    Flush();
                    cur.Kind = kind;
                }
                cur.Url = u.Value;
            }
            else if (PassKeys.Contains(key)) { if (cur.Password.Length == 0) cur.Password = val; }
            else if (UserKeys.Contains(key)) { if (cur.Login.Length == 0) cur.Login = val; }
            else if (ServerKeys.Contains(key)) { if (cur.Server.Length == 0) cur.Server = val; }
        }
        Flush();
        // одна и та же панель дважды (адрес напечатан в двух местах) — оставляем первую с паролем
        return list
            .GroupBy(b => b.Url.TrimEnd('/'), StringComparer.OrdinalIgnoreCase)
            .Select(g => g.OrderByDescending(b => b.Password.Length > 0).First())
            .ToList();
    }
}

/// <summary>Что за панель по адресу — без входа.
/// 3x-ui v3: GET {base}/csrf-token → {"success":true}; старая amnezia-wg-easy: GET {base}/api/session → 200 {requiresPassword};
/// awg-panel (wg-easy v15): GET {base}/api/session → 401.</summary>
public static class PanelProbe
{
    public const string Xui = "xui", Awg = "awg", AwgOld = "awg1";

    private static HttpClient Http(bool verifyTls)
    {
        var h = new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All, UseCookies = false };
        if (!verifyTls) h.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
        return new HttpClient(h) { Timeout = TimeSpan.FromSeconds(15) };
    }

    public static async Task<string?> DetectAsync(string url, bool verifyTls)
    {
        var b = PanelUrl.Parse(url).Base;
        using var http = Http(verifyTls);
        try
        {
            using (var r = await http.GetAsync(b + "/csrf-token"))
            {
                var t = await r.Content.ReadAsStringAsync();
                if ((int)r.StatusCode == 200 && t.Contains("\"success\"", StringComparison.Ordinal)) return Xui;
                if ((int)r.StatusCode == 403 && t.Length == 0)
                    throw new XuiException("403 — панель 3x-ui пускает только по своему домену (webDomain): открой по нему, не по IP");
            }
            using (var r = await http.GetAsync(b + "/api/session"))
            {
                var t = await r.Content.ReadAsStringAsync();
                if ((int)r.StatusCode == 200 && t.Contains("requiresPassword", StringComparison.Ordinal)) return AwgOld;
                if ((int)r.StatusCode == 401) return Awg;
            }
            return null;
        }
        catch (HttpRequestException ex) when (ex.InnerException is AuthenticationException)
        { throw new XuiException($"сертификат не прошёл проверку ({ex.InnerException.Message})"); }
        catch (HttpRequestException ex)
        { throw new XuiException($"нет связи ({ex.InnerException?.Message ?? ex.Message})"); }
        catch (TaskCanceledException)
        { throw new XuiException("таймаут"); }
    }

    public static string Text(string? kind) => kind switch
    {
        Xui => "3x-ui",
        Awg => "AWG · awg-panel",
        AwgOld => "AWG · старая amnezia-wg-easy",
        _ => "не определена",
    };
}

/// <summary>Вход в 3x-ui по логину/паролю (cookie-сессия + CSRF) и выпуск API-токена — как «Новый токен» в настройках.</summary>
public static class XuiLogin
{
    public sealed record Result(string? Token, bool NeedTwoFactor, string Message, bool Ok = false);

    /// <param name="tokenName">null — только проверить вход, токен не выпускать.</param>
    public static async Task<Result> IssueTokenAsync(string url, string login, string password, string? twoFactor,
        bool verifyTls, string? tokenName, string scope = "admin")
    {
        var b = PanelUrl.Parse(url).Base;
        var h = new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.All, UseCookies = true, CookieContainer = new CookieContainer(),
        };
        if (!verifyTls) h.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
        using var http = new HttpClient(h) { Timeout = TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        http.DefaultRequestHeaders.Add("X-Requested-With", "XMLHttpRequest");

        async Task<(int Code, JsonNode? Js)> Send(HttpMethod m, string path, object? body, string? csrf)
        {
            using var req = new HttpRequestMessage(m, b + path);
            if (body is not null)
                req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
            if (csrf is not null) req.Headers.Add("X-CSRF-Token", csrf);
            try
            {
                using var resp = await http.SendAsync(req);
                var text = await resp.Content.ReadAsStringAsync();
                JsonNode? js = null;
                try { js = JsonNode.Parse(text); } catch { }
                return ((int)resp.StatusCode, js);
            }
            catch (HttpRequestException ex) when (ex.InnerException is AuthenticationException)
            { throw new XuiException($"сертификат не прошёл проверку ({ex.InnerException.Message})"); }
            catch (HttpRequestException ex)
            { throw new XuiException($"нет связи ({ex.InnerException?.Message ?? ex.Message})"); }
            catch (TaskCanceledException)
            { throw new XuiException("таймаут"); }
        }

        static bool Ok(JsonNode? js) { try { return js?["success"]?.GetValue<bool>() == true; } catch { return false; } }
        static string? Msg(JsonNode? js) { try { return js?["msg"]?.GetValue<string>(); } catch { return null; } }

        async Task<string> Csrf()
        {
            var (code, js) = await Send(HttpMethod.Get, "/csrf-token", null, null);
            if (code == 403) throw new XuiException("403 — 3x-ui пускает только по своему домену (webDomain)");
            if (!Ok(js) || js!["obj"]?.GetValue<string>() is not { Length: > 0 } t)
                throw new XuiException($"не 3x-ui v3 или неверный путь панели (csrf-token: HTTP {code})");
            return t;
        }

        var csrf = await Csrf();
        var (lc, lj) = await Send(HttpMethod.Post, "/login",
            new { username = login, password, twoFactorCode = twoFactor ?? "" }, csrf);
        if (lc == 403) throw new XuiException("вход: 403 (CSRF/домен)");
        if (!Ok(lj))
        {
            var (_, tf) = await Send(HttpMethod.Post, "/getTwoFactorEnable", new { }, csrf);
            var need = false;
            try { need = Ok(tf) && tf!["obj"]?.GetValue<bool>() == true; } catch { }
            if (need && string.IsNullOrWhiteSpace(twoFactor))
                return new Result(null, true, "включена 2FA — введи код из приложения");
            return new Result(null, false, "логин/пароль" + (need ? "/код 2FA" : "") + " не подошли" +
                (Msg(lj) is { Length: > 0 } mm ? $" ({mm})" : ""));
        }
        if (tokenName is null) return new Result(null, false, "✓ вход по логину и паролю работает", true);
        csrf = await Csrf(); // после входа сессия та же, но токен берём заново — дешевле, чем гадать
        var (tc, tj) = await Send(HttpMethod.Post, "/panel/api/setting/apiTokens/create",
            new { name = tokenName, scope, expiresAt = 0 }, csrf);
        if (!Ok(tj)) throw new XuiException($"токен не выпустился: HTTP {tc} {Msg(tj)}");
        var token = tj!["obj"]?["token"]?.GetValue<string>();
        if (string.IsNullOrEmpty(token)) throw new XuiException("токен выпущен, но панель не вернула его текст");
        return new Result(token, false, $"✓ вход по паролю, выпущен API-токен «{tokenName}» ({scope})", true);
    }
}
