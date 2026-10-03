using System.IO;
using System.Text.Json;

namespace QEditor;

/// <summary>Настройки вида QEditor (%APPDATA%\QTerm\editor-settings.json) + недавние файлы.</summary>
public sealed class EditorSettings
{
    public string Theme { get; set; } = "dark"; // dark | light | system
    public bool LineNumbers { get; set; } = true;
    public bool WordWrap { get; set; }
    public bool ShowWhitespace { get; set; }
    public bool ShowEol { get; set; }
    public bool HighlightLine { get; set; } = true;
    public bool ColumnRuler { get; set; }
    public bool Toolbar { get; set; } = true;
    public bool StatusBar { get; set; } = true;
    public double FontSize { get; set; } = 13.5;
    public int TabSize { get; set; } = 4;
    public bool UseSpaces { get; set; } = true;
    public List<string> Recent { get; set; } = new();
    public double Width { get; set; } = 1100;
    public double Height { get; set; } = 760;

    private static string PathFile => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm", "editor-settings.json");

    public static EditorSettings Current { get; } = Load();

    private static EditorSettings Load()
    {
        try
        {
            if (File.Exists(PathFile))
                return JsonSerializer.Deserialize<EditorSettings>(File.ReadAllText(PathFile)) ?? new();
        }
        catch { }
        return new();
    }

    public static void Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PathFile)!);
            File.WriteAllText(PathFile, JsonSerializer.Serialize(Current,
                new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    public static void AddRecent(string path)
    {
        var r = Current.Recent;
        r.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        r.Insert(0, path);
        if (r.Count > 12) r.RemoveRange(12, r.Count - 12);
        Save();
    }
}
