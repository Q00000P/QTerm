using System.IO;
using System.Text.RegularExpressions;

namespace QTermWin.Xui;

/// <summary>Бэкап базы панели: файл, панель, версия панели на момент снятия, время.</summary>
public sealed class XuiBackup
{
    public string Path = "";
    public string Panel = "";
    public string Version = "";       // без «v»; пусто — старый бэкап без версии
    public DateTime Time;
    public long Size;
    public string FileName => System.IO.Path.GetFileName(Path);
}

/// <summary>Бэкапы баз 3x-ui в %APPDATA%\QTerm\xui-backup: «ИМЯ__vВЕРСИЯ__ГГГГММДД-ЧЧММСС.db».
/// Снимаются перед любым изменением (ревизия, подключение ноды, обновление, смена ядра, восстановление, откат).</summary>
public static class XuiBackups
{
    public static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm", "xui-backup");

    private static readonly Regex Named = new(@"^(.*)__v(.+?)__(\d{8}-\d{6})\.db$", RegexOptions.Compiled);
    private static readonly Regex Legacy = new(@"^(.*)-(\d{8}-\d{6})\.db$", RegexOptions.Compiled);

    public static string Safe(string name) =>
        string.Concat(name.Select(ch => char.IsLetterOrDigit(ch) || ch is '-' or '.' ? ch : '_'));

    public static string Norm(string? version) => (version ?? "").Trim().TrimStart('v', 'V');

    public static async Task<string> SaveAsync(XuiApi api, string name)
    {
        Directory.CreateDirectory(Dir);
        var ver = "";
        try { ver = Norm((await api.StatusAsync())?["panelVersion"]?.GetValue<string>()); } catch { }
        if (ver.Length == 0) ver = "unknown";
        var path = Path.Combine(Dir, $"{Safe(name)}__v{ver}__{DateTime.Now:yyyyMMdd-HHmmss}.db");
        await File.WriteAllBytesAsync(path, await api.GetDbAsync());
        return path;
    }

    public static List<XuiBackup> List()
    {
        var list = new List<XuiBackup>();
        if (!Directory.Exists(Dir)) return list;
        foreach (var f in Directory.GetFiles(Dir, "*.db"))
        {
            var fn = Path.GetFileName(f);
            var b = new XuiBackup { Path = f, Size = new FileInfo(f).Length };
            var m = Named.Match(fn);
            string stamp;
            if (m.Success) { b.Panel = m.Groups[1].Value; b.Version = m.Groups[2].Value == "unknown" ? "" : m.Groups[2].Value; stamp = m.Groups[3].Value; }
            else if (Legacy.Match(fn) is { Success: true } l) { b.Panel = l.Groups[1].Value; stamp = l.Groups[2].Value; }
            else { b.Panel = Path.GetFileNameWithoutExtension(fn); stamp = ""; }
            b.Time = DateTime.TryParseExact(stamp, "yyyyMMdd-HHmmss", null, System.Globalization.DateTimeStyles.None, out var t)
                ? t : File.GetLastWriteTime(f);
            list.Add(b);
        }
        return list.OrderByDescending(b => b.Time).ToList();
    }

    /// <summary>Бэкапы этой панели (по имени; старые бэкапы главной назывались «master»).</summary>
    public static List<XuiBackup> For(XuiPanel p) =>
        List().Where(b => b.Panel.Equals(Safe(p.Name), StringComparison.OrdinalIgnoreCase) ||
                          (p.IsMaster && b.Panel.Equals("master", StringComparison.OrdinalIgnoreCase))).ToList();

    /// <summary>Сравнение версий «3.9.0» / «v3.8.5».</summary>
    public static int Compare(string a, string b)
    {
        static int[] Parts(string s) => Norm(s).Split('.', '-').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        var pa = Parts(a); var pb = Parts(b);
        for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            var x = i < pa.Length ? pa[i] : 0; var y = i < pb.Length ? pb[i] : 0;
            if (x != y) return x.CompareTo(y);
        }
        return 0;
    }
}
