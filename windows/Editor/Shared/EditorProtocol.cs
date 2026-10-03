using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace QTermShared;

/// <summary>
/// Протокол QTerm ↔ QEditor (мак-канон: редактор — отдельное приложение).
/// Именованный канал, по строке JSON на сообщение (переводы строк в тексте
/// экранируются JSON'ом). Сервер канала — QEditor, клиенты — QTerm и вторая
/// копия QEditor (та шлёт activate и выходит).
///   QTerm → QEditor: hello · open{doc,node,path,data} · new · activate ·
///                    saved{doc,ok,error,bytes} · reloaded{doc,data | ok=false,error}
///   QEditor → QTerm: save{doc,data} · reload{doc} · closed{doc}
/// data — base64 СЫРЫХ байт файла: кодировку и концы строк решает редактор.
/// </summary>
public sealed class EditorMsg
{
    [JsonPropertyName("op")] public string Op { get; set; } = "";
    [JsonPropertyName("doc")] public string? Doc { get; set; }
    [JsonPropertyName("node")] public string? Node { get; set; }
    [JsonPropertyName("path")] public string? Path { get; set; }
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("data")] public string? Data { get; set; }
    [JsonPropertyName("ok")] public bool? Ok { get; set; }
    [JsonPropertyName("error")] public string? Error { get; set; }
    [JsonPropertyName("bytes")] public int? Bytes { get; set; }
}

public static class EditorProtocol
{
    /// <summary>Имя канала на пользователя (каналы видны в пределах сеанса).</summary>
    public static string PipeName =>
        "QTermEditor-" + new string(Environment.UserName.Where(char.IsLetterOrDigit).ToArray());

    private static readonly JsonSerializerOptions Opts = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string Encode(EditorMsg m) => JsonSerializer.Serialize(m, Opts);

    public static EditorMsg? Decode(string line)
    {
        try { return JsonSerializer.Deserialize<EditorMsg>(line, Opts); }
        catch { return null; }
    }

    public static StreamWriter Writer(Stream s) => new(s, new UTF8Encoding(false)) { AutoFlush = true };
    public static StreamReader Reader(Stream s) => new(s, new UTF8Encoding(false));
}
