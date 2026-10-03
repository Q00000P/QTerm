using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Encodings.Web;

namespace QTermWin.Models;

// Порт Session.swift 1:1. Имена полей — ЯВНО через JsonPropertyName
// (канон: keyID/deviceID, не keyId), даты ISO8601 без долей секунд,
// UUID uppercase, nil-поля не пишутся (Swift Codable дропает nil).

public enum AuthMethod
{
    password,
    privateKey,
    agent,
}

public sealed class SSHKey
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("privateKey")] public string PrivateKey { get; set; } = "";
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }
}

public sealed class Session
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    [JsonPropertyName("port")] public int Port { get; set; } = 22;
    [JsonPropertyName("username")] public string Username { get; set; } = "";
    [JsonPropertyName("authMethod")] public AuthMethod AuthMethod { get; set; } = AuthMethod.password;
    [JsonPropertyName("keyID")] public Guid? KeyID { get; set; }
    [JsonPropertyName("privateKeyPath")] public string? PrivateKeyPath { get; set; }
    [JsonPropertyName("extra")] public Dictionary<string, string> Extra { get; set; } = new();
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }
}

public sealed class Snippet
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("command")] public string Command { get; set; } = "";
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }
}

/// <summary>Команда с GitHub/гиста: вручную, имя (по нему ищем и выводим),
/// сама команда и заметка. Синк LWW по updatedAt, удаление — tombstone.
/// Канон поля вейлта: "gitCommands" (мак/андроид — то же имя и поля).</summary>
public sealed class GitCommand
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("command")] public string Command { get; set; } = "";
    [JsonPropertyName("note")] public string Note { get; set; } = "";
    /// <summary>Варианты одной команды (curl / wget …). null — один вариант = Command.
    /// Если есть — ВСЕ варианты, Command = Variants[0].Command (для старых читателей).</summary>
    [JsonPropertyName("variants")] public List<GitVariant>? Variants { get; set; }
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }

    public List<GitVariant> AllVariants() =>
        Variants is { Count: > 0 } v
            ? v.Select(x => new GitVariant { Label = x.Label, Command = x.Command }).ToList()
            : new List<GitVariant> { new() { Label = GitVariant.DeriveLabel(Command), Command = Command } };
}

/// <summary>Вариант команды: короткая метка («curl», «wget») + сама команда.</summary>
public sealed class GitVariant
{
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    [JsonPropertyName("command")] public string Command { get; set; } = "";

    /// <summary>Метка по умолчанию — первое слово команды (curl, wget, bash…).</summary>
    public static string DeriveLabel(string cmd)
    {
        var first = cmd.TrimStart().Split(new[] { ' ', '\t', '\n', '\r' }, 2, StringSplitOptions.RemoveEmptyEntries)
            .FirstOrDefault() ?? "";
        if (first is "sudo" or "sh" or "bash" && cmd.TrimStart().Split(' ', 3, StringSplitOptions.RemoveEmptyEntries) is { Length: > 1 } parts
            && parts[1] is "curl" or "wget")
            first = parts[1];
        first = first.Split('/').Last();
        return first.Length is > 0 and <= 16 ? first : "вариант";
    }
}

public sealed class CmdStat
{
    [JsonPropertyName("count")] public int Count { get; set; }
    [JsonPropertyName("lastUsed")] public string? LastUsed { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }
}

/// <summary>Своя запись словаря (мак-канон cmdDictUser): scope server|mac|both,
/// deleted поверх встроенной = скрыть её.</summary>
public sealed class DictEntry
{
    [JsonPropertyName("scope")] public string Scope { get; set; } = "server";
    [JsonPropertyName("updatedAt")] public string? UpdatedAt { get; set; }
    [JsonPropertyName("deleted")] public bool? Deleted { get; set; }
}

public sealed class SessionVault
{
    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; } = 1;
    [JsonPropertyName("deviceID")] public Guid DeviceID { get; set; } = Guid.NewGuid();
    [JsonPropertyName("updatedAt")] public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("sessions")] public List<Session> Sessions { get; set; } = new();
    [JsonPropertyName("snippets")] public List<Snippet>? Snippets { get; set; }
    // Ключи: "<sessionID>.password", "key:<keyID>.passphrase",
    // "path:<путь>.passphrase", легаси "<sessionID>.privateKeyPassphrase"
    [JsonPropertyName("secrets")] public Dictionary<string, string>? Secrets { get; set; }
    [JsonPropertyName("sshKeys")] public List<SSHKey>? SshKeys { get; set; }
    [JsonPropertyName("cmdHistory")] public Dictionary<string, CmdStat>? CmdHistory { get; set; }
    // Мак-поля: журналы по скоупам (cmdHistory = серверный легаси, "mac" = маковский)
    // и пользовательский словарь. ЗЕРКАЛО ОБЯЗАТЕЛЬНО — иначе пуш винды стирает их из облака
    [JsonPropertyName("cmdHistoryScopes")]
    public Dictionary<string, Dictionary<string, CmdStat>>? CmdHistoryScopes { get; set; }
    [JsonPropertyName("cmdDictUser")]
    public Dictionary<string, DictEntry>? CmdDictUser { get; set; }
    // Команды с Git (имя / команда / заметка)
    [JsonPropertyName("gitCommands")] public List<GitCommand>? GitCommands { get; set; }
}

/// <summary>UUID uppercase (Swift-канон). Guid.ToString даёт lowercase.</summary>
public sealed class UpperGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
        => Guid.Parse(reader.GetString()!);

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions o)
        => writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// <summary>
/// Даты: ПИШЕМ строго ISO8601 UTC без долей секунд (числовые даты валят
/// kotlinx на андроиде — уже наступали). ЧИТАЕМ терпимо, как декодер мака:
/// ISO-строка ЛИБО число (эвристика: >1e11 — unix-мс; &lt;1e9 — Apple
/// refDate, +978307200; иначе unix-секунды).
/// </summary>
public sealed class AppleTolerantDateConverter : JsonConverter<DateTime>
{
    private static readonly DateTime Epoch = DateTime.UnixEpoch;

    public override DateTime Read(ref Utf8JsonReader reader, Type t, JsonSerializerOptions o)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            var s = reader.GetString()!;
            return DateTimeOffset.Parse(s, null, System.Globalization.DateTimeStyles.AssumeUniversal
                | System.Globalization.DateTimeStyles.AdjustToUniversal).UtcDateTime;
        }
        var v = reader.GetDouble();
        double unixSec = v > 1e11 ? v / 1000.0
                       : v < 1e9  ? v + 978307200.0
                       : v;
        return Epoch.AddSeconds(unixSec);
    }

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions o)
        => writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"));
}

public static class QtJson
{
    public static readonly JsonSerializerOptions Options = Build();

    private static JsonSerializerOptions Build()
    {
        var o = new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, // кириллица как есть
        };
        o.Converters.Add(new UpperGuidConverter());
        o.Converters.Add(new AppleTolerantDateConverter());
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase)); // password/privateKey/agent
        return o;
    }

    /// <summary>Сейчас в каноне синка: ISO8601 UTC без долей, сравнимо лексикографически.</summary>
    public static string NowIso() =>
        DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
}
