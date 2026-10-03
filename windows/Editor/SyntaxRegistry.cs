using System.IO;
using System.Reflection;
using System.Xml;
using ICSharpCode.AvalonEdit.Highlighting;
using ICSharpCode.AvalonEdit.Highlighting.Xshd;

namespace QEditor;

/// <summary>Подсветка синтаксиса: свои определения в тёмной палитре
/// (встроенные в AvalonEdit рассчитаны на светлый фон), автоопределение по
/// расширению, имени файла, пути и шебангу.</summary>
public static class SyntaxRegistry
{
    public const string Plain = "Текст";

    // Порядок = порядок в меню «Синтаксис»
    public static readonly (string Name, string File, string Comment)[] All =
    {
        (Plain, "", "#"),
        ("Shell", "Shell", "#"),
        ("YAML", "YAML", "#"),
        ("JSON", "JSON", "//"),
        ("INI / Conf", "INI", "#"),
        ("Nginx", "Nginx", "#"),
        ("Python", "Python", "#"),
        ("JavaScript / TS", "JavaScript", "//"),
        ("PowerShell", "PowerShell", "#"),
        ("XML / HTML", "XML", "<!--"),
        ("SQL", "SQL", "--"),
        ("Markdown", "Markdown", "<!--"),
        ("Dockerfile", "Dockerfile", "#"),
        ("Diff", "Diff", "#"),
        ("C / C# / Go / Java / Rust", "CLike", "//"),
    };

    private static readonly Dictionary<string, IHighlightingDefinition?> Cache = new();

    /// <summary>Определение подсветки под текущую тему (X.xshd — тёмная, X.Light.xshd — светлая).</summary>
    public static IHighlightingDefinition? Get(string name)
    {
        var light = QTermShared.ThemeManager.IsLight;
        var cacheKey = (light ? "L:" : "D:") + name;
        if (Cache.TryGetValue(cacheKey, out var d)) return d;
        var entry = All.FirstOrDefault(a => a.Name == name);
        IHighlightingDefinition? def = null;
        if (!string.IsNullOrEmpty(entry.File))
        {
            try
            {
                using var s = Assembly.GetExecutingAssembly()
                    .GetManifestResourceStream($"QEditor.Syntax.{entry.File}{(light ? ".Light" : "")}.xshd");
                if (s is not null)
                {
                    using var r = XmlReader.Create(s);
                    def = HighlightingLoader.Load(r, HighlightingManager.Instance);
                }
            }
            catch { def = null; } // битое определение — просто без подсветки
        }
        Cache[cacheKey] = def;
        return def;
    }

    /// <summary>Префикс строчного комментария для «Закомментировать» по умолчанию.</summary>
    public static string CommentPrefix(string name) =>
        All.FirstOrDefault(a => a.Name == name).Comment is { Length: > 0 } c ? c : "#";

    public static string Detect(string path, string text)
    {
        var file = Path.GetFileName(path.Replace('/', Path.DirectorySeparatorChar)).ToLowerInvariant();
        var ext = Path.GetExtension(file);
        var p = path.Replace('\\', '/').ToLowerInvariant();

        if (file is "dockerfile" || file.StartsWith("dockerfile.") || ext == ".dockerfile") return "Dockerfile";
        if (file is ".bashrc" or ".profile" or ".bash_profile" or ".zshrc" or "crontab" or "profile") return "Shell";
        if (p.Contains("/nginx/") || file == "nginx.conf" || ext == ".nginx") return "Nginx";
        switch (ext)
        {
            case ".sh": case ".bash": case ".zsh": case ".ksh": case ".ash": return "Shell";
            case ".yaml": case ".yml": return "YAML";
            case ".json": case ".jsonc": case ".json5": return "JSON";
            case ".ini": case ".cfg": case ".toml": case ".env": case ".properties": case ".service":
            case ".timer": case ".network": case ".netdev": case ".mount": return "INI / Conf";
            case ".py": case ".pyw": return "Python";
            case ".js": case ".mjs": case ".cjs": case ".ts": case ".tsx": case ".jsx": return "JavaScript / TS";
            case ".ps1": case ".psm1": case ".psd1": return "PowerShell";
            case ".xml": case ".html": case ".htm": case ".xhtml": case ".svg": case ".plist":
            case ".xaml": case ".csproj": case ".config": return "XML / HTML";
            case ".sql": return "SQL";
            case ".md": case ".markdown": return "Markdown";
            case ".diff": case ".patch": return "Diff";
            case ".c": case ".h": case ".cpp": case ".hpp": case ".cc": case ".cs": case ".java":
            case ".go": case ".rs": case ".kt": case ".swift": return "C / C# / Go / Java / Rust";
        }

        // Без расширения/неоднозначные: шебанг и содержимое
        var first = text.Length > 200 ? text[..200] : text;
        var nl = first.IndexOf('\n');
        if (nl >= 0) first = first[..nl];
        if (first.StartsWith("#!"))
        {
            if (first.Contains("python")) return "Python";
            if (first.Contains("node")) return "JavaScript / TS";
            if (first.Contains("pwsh")) return "PowerShell";
            return "Shell";
        }
        if (p.Contains("/init.d/") || p.Contains("/cron")) return "Shell";
        if (ext == ".conf")
        {
            var head = text.Length > 4000 ? text[..4000] : text;
            if (head.Contains("server {") || head.Contains("location ") || head.Contains("upstream ")) return "Nginx";
            return "INI / Conf";
        }
        var t = text.TrimStart();
        if (t.StartsWith("{") || t.StartsWith("[{")) return "JSON";
        if (t.StartsWith("<?xml") || t.StartsWith("<")) return "XML / HTML";
        return Plain;
    }
}
