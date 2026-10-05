using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace QTermWin.Xui;

/// <summary>Каскад-сервер: SSH-сессия QTerm, на которой стоит qcascade — mihomo с правилами как на Кинетиках.
/// Ноды — из своих источников (клиенты на панелях 3x-ui, ссылки подписок, WireGuard/AWG), трафик клиентов
/// 3x-ui, AWG-панели и MTProto-прокси сервера перехватывается в mihomo.
/// Живёт в secrets вейлта ("xui.cascade:&lt;ID&gt;", LWW по updatedAt как xui.panel) и едет синком.</summary>
public sealed class CascadeServer
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    /// <summary>id SSH-сессии QTerm этого сервера.</summary>
    [JsonPropertyName("ssh")] public string Ssh { get; set; } = "";
    /// <summary>v1: клиент главной, чья подписка стояла на сервере (только для показа; в v2 источники — на сервере).</summary>
    [JsonPropertyName("client")] public string? Client { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }

    public override string ToString() => Name;
}

/// <summary>Источник нод каскада — запись /etc/qcascade/sources.json на сервере.
/// sub — Clash/Mihomo-подписка (свой клиент на панели 3x-ui или любая ссылка), wg — WireGuard/AmneziaWG-конфиг.
/// meta — откуда взят (kind: xui | link | awg | conf, панель, клиент, инбаунды); скрипт его не трогает.</summary>
public sealed class CascadeSource
{
    public string Name { get; set; } = "";
    public string Type { get; set; } = "sub";
    public string Url { get; set; } = "";
    public string Conf { get; set; } = "";
    public bool Enabled { get; set; } = true;
    public string Prefix { get; set; } = "";
    public JsonObject Meta { get; set; } = new();

    public static readonly Regex NameRx = new("^[A-Za-z0-9._-]{1,32}$", RegexOptions.Compiled);
    public static readonly Regex PrefixRx = new("^[A-Za-z0-9._-]{0,16}$", RegexOptions.Compiled);

    public bool IsWg => Type == "wg";
    public string Kind => MetaStr("kind") is { Length: > 0 } k ? k : IsWg ? "conf" : "link";
    public Guid? PanelId => Guid.TryParse(MetaStr("panel"), out var g) ? g : null;

    public string MetaStr(string k)
    {
        var n = Meta[k];
        if (n is JsonValue v) return v.TryGetValue<string>(out var s) ? s : v.ToJsonString().Trim('"');
        return "";
    }

    public List<int> MetaInbounds()
    {
        var list = new List<int>();
        if (Meta["inbounds"] is JsonArray a)
            foreach (var x in a)
                if (x is JsonValue v && v.TryGetValue<int>(out var i)) list.Add(i);
        return list;
    }

    public static CascadeSource From(JsonObject o) => new()
    {
        Name = J.Str(o, "name"),
        Type = J.Str(o, "type") is { Length: > 0 } t ? t : "sub",
        Url = J.Str(o, "url"),
        Conf = J.Str(o, "conf"),
        Enabled = J.Bool(o, "enabled", true),
        Prefix = J.Str(o, "prefix"),
        Meta = o["meta"] is JsonObject m ? (JsonObject)m.DeepClone() : new JsonObject(),
    };

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["name"] = Name, ["type"] = Type, ["enabled"] = Enabled, ["prefix"] = Prefix };
        if (IsWg) o["conf"] = Conf; else o["url"] = Url;
        o["meta"] = Meta.DeepClone();
        return o;
    }

    public CascadeSource Clone() => From(ToJson());

    /// <summary>Откуда источник — для списка.</summary>
    public string Origin => Kind switch
    {
        "xui" => $"клиент {MetaStr("client")} на панели {MetaStr("panelName")}" +
                 (MetaInbounds().Count > 0 ? $" · инбаундов {MetaInbounds().Count}" : ""),
        "awg" => $"клиент {MetaStr("client")} AWG-панели {MetaStr("panelName")}" +
                 (MetaStr("iface") is { Length: > 0 } i ? $" ({i})" : ""),
        "conf" => "конфиг WireGuard / AWG",
        _ => "ссылка подписки",
    };

    /// <summary>Быстрая проверка конфига WireGuard до отправки на сервер (полная — в скрипте).</summary>
    public static string? CheckWgConf(string conf)
    {
        var t = conf.Replace("\r", "");
        if (!Regex.IsMatch(t, @"^\s*\[Interface\]", RegexOptions.Multiline | RegexOptions.IgnoreCase)) return "нет раздела [Interface]";
        if (!Regex.IsMatch(t, @"^\s*\[Peer\]", RegexOptions.Multiline | RegexOptions.IgnoreCase)) return "нет раздела [Peer]";
        foreach (var k in new[] { "PrivateKey", "Address", "PublicKey", "Endpoint" })
            if (!Regex.IsMatch(t, $@"^\s*{k}\s*=\s*\S", RegexOptions.Multiline | RegexOptions.IgnoreCase)) return $"нет {k}";
        return null;
    }
}

/// <summary>Операции qcascade на сервере поверх exec-канала SSH-сессии (терминал не трогается).
/// Скрипт встроен в QTerm (scripts/vpn-cascade.sh) и заливается на сервер сам — гист не нужен.
/// Каждая команда оборачивается: stderr в stdout, код возврата — маркером @@QCRC в конце вывода.</summary>
public sealed class CascadeRemote
{
    public const string Bin = "/usr/local/sbin/qcascade";
    private const string Script = "vpn-cascade.sh";          // в домашней папке пользователя SSH
    private const string InstLog = ".qcascade-install.log";
    private const string InstRc = ".qcascade-install.rc";
    private const string SrcFile = ".qcascade-src.json";     // источники для первой установки (600, скрипт удаляет)
    private const string PipeFile = ".qcascade-pipe.tmp";
    private const int Chunk = 60000;                         // base64 на команду: < 128 КБ на аргумент bash -c

    public sealed record Result(int Rc, string Out)
    {
        public bool Ok => Rc == 0;
    }

    private readonly Func<string, int, Task<string>> _exec;
    private string? _sudo;

    public CascadeRemote(Func<string, int, Task<string>> exec) => _exec = exec;

    public static string Q(string s) => "'" + s.Replace("'", "'\\''") + "'";

    private static readonly Regex RcMark = new(@"\r?\n?@@QCRC=(-?\d+)\s*$", RegexOptions.Compiled);

    public async Task<Result> RunAsync(string cmd, int timeoutSec = 60)
    {
        var outp = await _exec("{ " + cmd + "\n} 2>&1; printf '\\n@@QCRC=%d\\n' $?", timeoutSec);
        var m = RcMark.Match(outp);
        if (!m.Success) return new Result(-1, outp.TrimEnd());
        return new Result(int.Parse(m.Groups[1].Value), outp[..m.Index].TrimEnd('\r', '\n'));
    }

    /// <summary>"" под root, "sudo -n " — если пользователь не root, но sudo без пароля есть.</summary>
    public async Task<string> SudoAsync()
    {
        if (_sudo is not null) return _sudo;
        var r = await RunAsync("id -u", 30);
        if (!r.Ok) throw new XuiException("сервер не выполняет команды: " + r.Out);
        if (r.Out.Trim() == "0") return _sudo = "";
        var s = await RunAsync("sudo -n true", 30);
        if (!s.Ok) throw new XuiException("нужен root или sudo без пароля — войди в SSH-сессии под root");
        return _sudo = "sudo -n ";
    }

    /// <summary>qcascade &lt;args&gt; от root.</summary>
    public async Task<Result> QcAsync(string args, int timeoutSec = 120) =>
        await RunAsync(await SudoAsync() + Bin + " " + args, timeoutSec);

    /// <summary>Текст на stdin команды root (настройки, источники): секреты — не аргументами команды.
    /// Большой текст (WG-конфиги) — через временный файл 600 в домашней папке.</summary>
    public async Task<Result> PipeAsync(string text, string target, int timeoutSec = 120)
    {
        var data = new UTF8Encoding(false).GetBytes(text);
        var sudo = await SudoAsync();
        if (data.Length * 4 / 3 < Chunk)
            return await RunAsync($"printf %s {Q(Convert.ToBase64String(data))} | base64 -d | {sudo}{target}", timeoutSec);
        await UploadAsync(PipeFile, data, "600");
        return await RunAsync($"{sudo}{target} < {PipeFile}; rc=$?; rm -f {PipeFile}; exit $rc", timeoutSec);
    }

    /// <summary>Версия qcascade на сервере; null — не установлен.</summary>
    public async Task<string?> RemoteVersionAsync()
    {
        var r = await RunAsync($"[ -x {Bin} ] && {Bin} version", 30);
        if (!r.Ok) return null;
        var m = Regex.Match(r.Out, @"qcascade\s+(\S+)");
        return m.Success ? m.Groups[1].Value : null;
    }

    private static JsonObject? ParseObj(string s)
    {
        var i = s.IndexOf('{');
        if (i < 0) return null;
        try { return JsonNode.Parse(s[i..]) as JsonObject; } catch { return null; }
    }

    public async Task<JsonObject> StatusAsync()
    {
        var r = await QcAsync("status --json 2>/dev/null", 60);
        return ParseObj(r.Out) ?? throw new XuiException("qcascade status не вернул JSON: " + Short(r.Out));
    }

    /// <summary>Что есть на сервере: 3x-ui (инбаунды, клиенты), интерфейсы AWG, MTProto (пользователи, контейнеры).</summary>
    public async Task<JsonObject> DetectAsync()
    {
        var r = await QcAsync("detect 2>/dev/null", 60);
        return ParseObj(r.Out) ?? throw new XuiException("qcascade detect не вернул JSON: " + Short(r.Out));
    }

    /// <summary>Источники целиком (со ссылками и конфигами — только для правки, в QTerm не хранятся).</summary>
    public async Task<List<CascadeSource>> SourcesAsync()
    {
        var r = await QcAsync("sources get", 60);
        var o = r.Ok ? ParseObj(r.Out) : null;
        if (o is null) throw new XuiException("источники не прочитались: " + Short(r.Out));
        return (o["sources"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(CascadeSource.From).ToList();
    }

    public static string SourcesJson(IEnumerable<CascadeSource> list) =>
        new JsonObject
        {
            ["v"] = 1,
            ["sources"] = new JsonArray(list.Select(s => (JsonNode?)s.ToJson()).ToArray()),
        }.ToJsonString();

    /// <summary>Записать источники (сервер проверяет их сам и не примет кривые). Применение — отдельно (apply).</summary>
    public async Task SaveSourcesAsync(IEnumerable<CascadeSource> list)
    {
        var r = await PipeAsync(SourcesJson(list), Bin + " sources set -");
        if (!r.Ok) throw new XuiException(Short(Clean(r.Out)));
    }

    public async Task<string> LogsAsync(int lines = 300) => (await QcAsync($"logs {lines}", 60)).Out;

    public static string Short(string s) => s.Length > 400 ? s[..400] + "…" : s;

    /// <summary>Вывод qcascade без цветовых кодов и префиксов [ERR].</summary>
    public static string Clean(string s) =>
        Regex.Replace(s, @"\x1b\[[0-9;]*m", "").Replace("[ERR]", "").Trim();

    // ── файлы ──

    /// <summary>Заливка в файл (путь от домашней папки или абсолютный, куда пишет пользователь SSH): base64-чанки + сверка sha256.
    /// Файл создаётся с umask 077 — секреты не читаются другими пользователями даже во время заливки.</summary>
    public async Task UploadAsync(string path, byte[] data, string? mode = null)
    {
        var b64 = Convert.ToBase64String(data);
        var tmp = path + ".b64";
        var r = await RunAsync($"rm -f {Q(tmp)}; umask 077; : > {Q(tmp)}", 30);
        if (!r.Ok) throw new XuiException("не пишется файл на сервере: " + r.Out);
        for (int i = 0; i < b64.Length; i += Chunk)
        {
            var part = b64.Substring(i, Math.Min(Chunk, b64.Length - i));
            r = await RunAsync($"printf %s {Q(part)} >> {Q(tmp)}", 60);
            if (!r.Ok) throw new XuiException("заливка оборвалась: " + r.Out);
        }
        var sha = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        r = await RunAsync($"rm -f {Q(path)}; umask 077; base64 -d {Q(tmp)} > {Q(path)} && rm -f {Q(tmp)}" +
                           (mode is null ? "" : $" && chmod {mode} {Q(path)}") + $" && sha256sum {Q(path)}", 60);
        if (!r.Ok || !r.Out.TrimStart().StartsWith(sha, StringComparison.OrdinalIgnoreCase))
            throw new XuiException("файл доехал до сервера битым: " + Short(r.Out));
    }

    /// <summary>Чтение файла от root (конфиги в /etc/qcascade).</summary>
    public async Task<string> ReadRootFileAsync(string path)
    {
        var r = await RunAsync(await SudoAsync() + "cat " + Q(path), 60);
        if (!r.Ok) throw new XuiException($"не прочитался {path}: {Short(r.Out)}");
        return r.Out.Replace("\r\n", "\n");
    }

    /// <summary>Запись файла от root: заливка во временный в домашней папке → install на место.</summary>
    public async Task WriteRootFileAsync(string path, string text)
    {
        var tmp = ".qcascade-upload.tmp";
        var body = text.Replace("\r\n", "\n");
        if (!body.EndsWith('\n')) body += "\n";
        await UploadAsync(tmp, new UTF8Encoding(false).GetBytes(body));
        var r = await RunAsync($"{await SudoAsync()}install -m 644 {Q(tmp)} {Q(path)} && rm -f {Q(tmp)}", 60);
        if (!r.Ok) throw new XuiException($"не записался {path}: {Short(r.Out)}");
    }

    // ── скрипт ──

    /// <summary>Встроенный vpn-cascade.sh (LF, без BOM).</summary>
    public static byte[] ScriptBytes()
    {
        using var s = typeof(CascadeRemote).Assembly.GetManifestResourceStream("vpn-cascade.sh")
                      ?? throw new XuiException("в сборке QTerm нет vpn-cascade.sh");
        using var ms = new MemoryStream();
        s.CopyTo(ms);
        var text = Encoding.UTF8.GetString(ms.ToArray()).TrimStart('﻿').Replace("\r\n", "\n");
        return new UTF8Encoding(false).GetBytes(text);
    }

    private static string? _scriptVersion;
    public static string ScriptVersion => _scriptVersion ??=
        Regex.Match(Encoding.UTF8.GetString(ScriptBytes()), "VERSION=\"([^\"]+)\"").Groups[1].Value;

    /// <summary>a новее b (семвер).</summary>
    public static bool Newer(string a, string? b) =>
        b is not null && Version.TryParse(a, out var va) && Version.TryParse(b, out var vb) && va > vb;

    /// <summary>Сервер на qcascade 2.x — источники, AWG, MTProto, резерв.</summary>
    public static bool IsV2(string? ver) => ver is not null && !Newer("2.0.0", ver);

    public Task UploadScriptAsync() => UploadAsync(Script, ScriptBytes(), "700");

    /// <summary>Настройки qcascade (QC_XRAY_MODE, QC_AWG_MODE, QC_RESERVE…): строки K=V через stdin.
    /// До установки — через залитый скрипт.</summary>
    public async Task SetAsync(IDictionary<string, string> env, bool viaScript = false)
    {
        var lines = string.Concat(env.Select(kv => kv.Key + "=" + kv.Value.Replace("\r", "").Replace("\n", " ") + "\n"));
        var r = await PipeAsync(lines, (viaScript ? $"bash ./{Script}" : Bin) + " set -", 60);
        if (!r.Ok) throw new XuiException("настройки не сохранились: " + Short(Clean(r.Out)));
    }

    /// <summary>Установка в фоне на сервере (setsid nohup): переживает обрыв SSH; лог и код — в домашней папке.
    /// sourcesJson — источники для первой установки (файл 600, скрипт забирает и удаляет).</summary>
    public async Task StartInstallAsync(string? sourcesJson = null)
    {
        var sudo = await SudoAsync();
        var srcEnv = "";
        if (sourcesJson is not null)
        {
            await UploadAsync(SrcFile, new UTF8Encoding(false).GetBytes(sourcesJson), "600");
            srcEnv = $" QC_SOURCES_FILE=\"$PWD/{SrcFile}\"";
        }
        var r = await RunAsync(
            $"rm -f {InstRc}; setsid nohup sh -c '{sudo}env QC_NONINTERACTIVE=1{srcEnv} bash ./{Script} install; echo $? > {InstRc}; rm -f {SrcFile}' " +
            $"> {InstLog} 2>&1 < /dev/null &", 30);
        if (!r.Ok) throw new XuiException("установка не запустилась: " + Short(r.Out));
    }

    /// <summary>Новые строки лога установки (после уже прочитанных), сколько строк в логе всего,
    /// и код возврата, когда установка закончилась.</summary>
    public async Task<(string[] Lines, int Total, int? Rc)> PollInstallAsync(int have)
    {
        // код читаем ДО подсчёта строк: появился код — лог уже дописан целиком
        var r = await RunAsync(
            $"r=$(cat {InstRc} 2>/dev/null); t=$(wc -l < {InstLog} 2>/dev/null || echo 0); " +
            $"echo \"@@RC=$r\"; echo \"@@T=$t\"; [ \"$t\" -gt {have} ] && sed -n \"$(({have}+1)),${{t}}p\" {InstLog}; true", 60);
        int? rc = null;
        var total = have;
        var body = new List<string>();
        foreach (var l in r.Out.Replace("\r", "").Split('\n'))
        {
            if (l.StartsWith("@@RC=")) { if (int.TryParse(l[5..].Trim(), out var v)) rc = v; }
            else if (l.StartsWith("@@T=")) { if (int.TryParse(l[4..].Trim(), out var t)) total = Math.Max(have, t); }
            else body.Add(l);
        }
        return (body.ToArray(), total, rc);
    }
}
