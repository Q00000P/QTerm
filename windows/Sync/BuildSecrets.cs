using System.Reflection;

namespace QTermWin.Sync;

/// <summary>Секреты, подставленные при сборке (в исходниках и в гите их нет).
/// Источник — MSBuild-свойство: файл secrets.local.props рядом с csproj (в .gitignore)
/// или переменная окружения QTERM_GOOGLE_CLIENT_SECRET (в CI — секрет репозитория).
/// В сборку попадают как [AssemblyMetadata(ключ, значение)].</summary>
public static class BuildSecrets
{
    public static string Get(string key)
    {
        var v = typeof(BuildSecrets).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == key)?.Value;
        if (string.IsNullOrWhiteSpace(v))
            throw new InvalidOperationException(
                $"В этой сборке нет {key}: собери с secrets.local.props или переменной QTERM_GOOGLE_CLIENT_SECRET " +
                "(синк через WebDAV работает и без него)");
        return v;
    }
}
