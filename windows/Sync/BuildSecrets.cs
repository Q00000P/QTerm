using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;

namespace QTermWin.Sync;

/// <summary>Секреты сборки (в исходниках и в гите их нет). Где ищутся, по порядку:
/// 1) вшитые при сборке — [AssemblyMetadata] из secrets.local.props рядом с csproj или переменной
///    QTERM_GOOGLE_CLIENT_SECRET (в CI — секрет репозитория);
/// 2) переменная окружения QTERM_GOOGLE_CLIENT_SECRET при запуске;
/// 3) %APPDATA%\QTerm\secrets.local.props (тот же формат, что у сборки) — так любая сборка,
///    в том числе с GitHub, берёт секрет этого компьютера.</summary>
public static class BuildSecrets
{
    private static readonly Dictionary<string, (string Env, string Prop)> Names = new()
    {
        ["GoogleClientSecret"] = ("QTERM_GOOGLE_CLIENT_SECRET", "QTermGoogleClientSecret"),
    };

    public static string Get(string key)
    {
        var v = typeof(BuildSecrets).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == key)?.Value;
        if (string.IsNullOrWhiteSpace(v) && Names.TryGetValue(key, out var n))
        {
            v = Environment.GetEnvironmentVariable(n.Env)
                ?? Environment.GetEnvironmentVariable(n.Env, EnvironmentVariableTarget.User);
            if (string.IsNullOrWhiteSpace(v)) v = FromProps(n.Prop);
        }
        if (string.IsNullOrWhiteSpace(v))
            throw new InvalidOperationException(
                $"В этой сборке нет {key}: положи secrets.local.props в %APPDATA%\\QTerm или задай переменную " +
                "QTERM_GOOGLE_CLIENT_SECRET (синк через WebDAV работает и без него)");
        return v.Trim();
    }

    private static string? FromProps(string prop)
    {
        try
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm", "secrets.local.props");
            if (!File.Exists(path)) return null;
            var m = Regex.Match(File.ReadAllText(path), $"<{prop}>\\s*([^<]+?)\\s*</{prop}>");
            return m.Success ? m.Groups[1].Value : null;
        }
        catch { return null; }
    }
}
