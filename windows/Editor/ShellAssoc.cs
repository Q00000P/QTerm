using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace QEditor;

/// <summary>
/// QEditor в проводнике (HKCU — без админа, только для текущего пользователя):
/// • «Открыть в QEditor» в контекстном меню любого файла;
/// • QEditor в списке «Открыть с помощью»;
/// • файлы без расширения (authorized_keys, config, hosts, known_hosts…) — двойным щелчком в QEditor,
///   если за ними ещё ничего не закреплено (чужую привязку не трогаем).
/// Путь к QEditor.exe обновляется при каждом запуске — переезд папки и обновления подхватываются сами.
/// </summary>
internal static class ShellAssoc
{
    private const string ProgId = "QEditor.File";
    private const string Classes = @"Software\Classes\";

    public static void Ensure()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe) || !File.Exists(exe)) return;
            var cmd = $"\"{exe}\" \"%1\"";
            var icon = $"\"{exe}\",0";
            var changed = false;

            changed |= Set(@"*\shell\QEditor", null, "Открыть в QEditor");
            changed |= Set(@"*\shell\QEditor", "Icon", icon);
            changed |= Set(@"*\shell\QEditor\command", null, cmd);

            changed |= Set(@"Applications\QEditor.exe", "FriendlyAppName", "QEditor");
            changed |= Set(@"Applications\QEditor.exe\DefaultIcon", null, icon);
            changed |= Set(@"Applications\QEditor.exe\shell\open\command", null, cmd);

            changed |= Set(ProgId, null, "Текстовый файл (QEditor)");
            changed |= Set(ProgId + @"\DefaultIcon", null, icon);
            changed |= Set(ProgId + @"\shell\open\command", null, cmd);

            // «.» — так Windows называет «без расширения»
            using (var k = Registry.CurrentUser.CreateSubKey(Classes + "."))
            {
                if (string.IsNullOrEmpty(k.GetValue(null) as string)) { k.SetValue(null, ProgId); changed = true; }
            }
            using (var k = Registry.CurrentUser.CreateSubKey(Classes + @".\OpenWithProgids"))
            {
                if (k.GetValue(ProgId) is null) { k.SetValue(ProgId, Array.Empty<byte>(), RegistryValueKind.None); changed = true; }
            }

            if (changed) SHChangeNotify(0x08000000 /* SHCNE_ASSOCCHANGED */, 0 /* SHCNF_IDLIST */, IntPtr.Zero, IntPtr.Zero);
        }
        catch { /* реестр недоступен (политики) — QEditor работает и без этого */ }
    }

    private static bool Set(string key, string? name, string value)
    {
        using var k = Registry.CurrentUser.CreateSubKey(Classes + key);
        if (k.GetValue(name) as string == value) return false;
        k.SetValue(name, value);
        return true;
    }

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
