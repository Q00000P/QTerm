using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace QTermWin.Xui;

/// <summary>Каскад-сервер: SSH-сессия QTerm, на которой стоит qcascade — mihomo с правилами как на Кинетиках,
/// ноды из Clash-подписки главной, трафик клиентов 3x-ui (VLESS, Hysteria, AWG) перехватывается в mihomo.
/// Живёт в secrets вейлта ("xui.cascade:&lt;ID&gt;", LWW по updatedAt как xui.panel) и едет синком.</summary>
public sealed class CascadeServer
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    /// <summary>id SSH-сессии QTerm этого сервера.</summary>
    [JsonPropertyName("ssh")] public string Ssh { get; set; } = "";
    /// <summary>Клиент главной, чья Clash-подписка стоит на сервере (для показа; сама ссылка — только на сервере).</summary>
    [JsonPropertyName("client")] public string? Client { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }

    public override string ToString() => Name;
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

    /// <summary>Инбаунды и клиенты 3x-ui сервера — для выбора «кого каскадить».</summary>
    public async Task<JsonObject> XrayListAsync()
    {
        var r = await QcAsync("xray list 2>/dev/null", 60);
        return ParseObj(r.Out) ?? throw new XuiException("qcascade xray list не вернул JSON: " + Short(r.Out));
    }

    public static string Short(string s) => s.Length > 300 ? s[..300] + "…" : s;

    // ── файлы ──

    /// <summary>Заливка в файл (путь от домашней папки или абсолютный, куда пишет пользователь SSH): base64-чанки + сверка sha256.</summary>
    public async Task UploadAsync(string path, byte[] data, string? mode = null)
    {
        var b64 = Convert.ToBase64String(data);
        var tmp = path + ".b64";
        var r = await RunAsync($": > {Q(tmp)}", 30);
        if (!r.Ok) throw new XuiException("не пишется файл на сервере: " + r.Out);
        for (int i = 0; i < b64.Length; i += Chunk)
        {
            var part = b64.Substring(i, Math.Min(Chunk, b64.Length - i));
            r = await RunAsync($"printf %s {Q(part)} >> {Q(tmp)}", 60);
            if (!r.Ok) throw new XuiException("заливка оборвалась: " + r.Out);
        }
        var sha = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        r = await RunAsync($"base64 -d {Q(tmp)} > {Q(path)} && rm -f {Q(tmp)}" +
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

    public Task UploadScriptAsync() => UploadAsync(Script, ScriptBytes(), "700");

    /// <summary>Настройки qcascade (QC_SUB_URL, QC_XRAY_MODE…): строки K=V через stdin, не аргументами —
    /// ссылка подписки не светится в ps. До установки — через залитый скрипт.</summary>
    public async Task SetAsync(IDictionary<string, string> env, bool viaScript = false)
    {
        var lines = string.Concat(env.Select(kv => kv.Key + "=" + kv.Value.Replace("\r", "").Replace("\n", " ") + "\n"));
        var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(lines));
        var target = viaScript ? $"bash ./{Script}" : Bin;
        var r = await RunAsync($"printf %s {Q(b64)} | base64 -d | {await SudoAsync()}{target} set -", 60);
        if (!r.Ok) throw new XuiException("настройки не сохранились: " + Short(r.Out));
    }

    /// <summary>Установка в фоне на сервере (setsid nohup): переживает обрыв SSH; лог и код — в домашней папке.</summary>
    public async Task StartInstallAsync()
    {
        var sudo = await SudoAsync();
        var r = await RunAsync(
            $"rm -f {InstRc}; setsid nohup sh -c '{sudo}env QC_NONINTERACTIVE=1 bash ./{Script} install; echo $? > {InstRc}' " +
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
