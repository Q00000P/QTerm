using System.IO;
using System.Text.Json;
using Windows.Security.Credentials;

namespace QTermWin.Security;

public sealed class AppSettings
{
    public bool HelloRequired { get; set; }
    public string? ExternalEditor { get; set; } // путь к exe; пусто = ассоциация системы
    public string? UiFontFamily { get; set; }   // пусто = Segoe UI Variable Text
    public double? UiFontSize { get; set; }     // пусто = 14
    public int? TermFontSize { get; set; }      // пусто = 14
    public string? Theme { get; set; }          // dark | light | system (пусто = dark)
    public int? ScrollbackLines { get; set; }   // пусто = 20000, clamp 50…1_000_000 (мак-канон)
    public bool? FsShowHidden { get; set; }     // файлы: показывать .dot (пусто = да)
    public bool? FsFollowTerminal { get; set; } // файлы: следовать за папкой терминала
    public Dictionary<string, string>? Hotkeys { get; set; }
    public Dictionary<string, GitUse>? GitUsage { get; set; } // команды Git: частота/последний вариант (локально) // id функции → «Ctrl+Shift+KeyG» ("" = снято); только отличия от умолчаний

    private static string PathFile => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(PathFile))
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(PathFile)) ?? new();
        }
        catch { }
        return new();
    }

    public void Save()
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PathFile)!);
        File.WriteAllText(PathFile, JsonSerializer.Serialize(this));
    }
}

/// <summary>Использование команды Git на этом устройстве (для сортировки быстрого вызова).</summary>
public sealed class GitUse
{
    public string? LastUsed { get; set; } // ISO8601 UTC
    public int Count { get; set; }
    public int Variant { get; set; }      // последний выбранный вариант
}

/// <summary>
/// Гейт Windows Hello поверх DPAPI-вейлта через KeyCredentialManager:
/// при включении создаётся кредентиал QTermVault, на старте — RequestSignAsync
/// (системный диалог Hello: биометрия/PIN). Это гейт доступа, не криптопривязка
/// ключа вейлта — вейлт по-прежнему под DPAPI пользователя.
/// </summary>
public static class HelloGate
{
    private const string CredName = "QTermVault";
    private static readonly byte[] Challenge = "QTerm-hello-gate-v1"u8.ToArray();

    public static async Task EnableAsync()
    {
        var supported = await KeyCredentialManager.IsSupportedAsync();
        if (!supported)
            throw new Exception("Windows Hello не настроен в системе (Параметры → Учётные записи)");
        var res = await KeyCredentialManager.RequestCreateAsync(
            CredName, KeyCredentialCreationOption.ReplaceExisting);
        if (res.Status != KeyCredentialStatus.Success)
            throw new Exception($"не создался кредентиал ({res.Status})");
        var s = AppSettings.Load();
        s.HelloRequired = true;
        s.Save();
    }

    public static void Disable()
    {
        var s = AppSettings.Load();
        s.HelloRequired = false;
        s.Save();
    }

    /// <summary>true = пускаем; false = отказ (закрыться).</summary>
    public static async Task<bool> VerifyAsync()
    {
        try
        {
            var open = await KeyCredentialManager.OpenAsync(CredName);
            if (open.Status != KeyCredentialStatus.Success)
                return open.Status == KeyCredentialStatus.NotFound; // кредентиал снесли — не запираем насмерть
            var sign = await open.Credential.RequestSignAsync(
                global::Windows.Security.Cryptography.CryptographicBuffer.CreateFromByteArray(Challenge));
            return sign.Status == KeyCredentialStatus.Success;
        }
        catch
        {
            return true; // Hello сломан системно — не окирпичивать доступ к вейлту
        }
    }
}
