using QTermWin.Terminal;

namespace QTermWin.Files;

/// <summary>Файловая панель одной вкладки: бекенд + текущий путь.</summary>
public sealed class FileService : IDisposable
{
    public IRemoteFs Fs { get; }
    public string CurrentPath { get; set; }
    public List<RemoteEntry> Entries { get; set; } = new();
    /// <summary>Домашняя папка (для ~ в заголовке шелла при «следовать за терминалом»).</summary>
    public string HomeDir { get; private set; } = "/";
    /// <summary>Недавние папки (первая — последняя посещённая).</summary>
    public List<string> History { get; } = new();

    private FileService(IRemoteFs fs, string start)
    {
        Fs = fs;
        CurrentPath = start;
    }

    public void Remember(string path)
    {
        History.Remove(path);
        History.Insert(0, path);
        if (History.Count > 20) History.RemoveRange(20, History.Count - 20);
    }

    /// <summary>Блокирующий вызов — только с фонового потока.</summary>
    public static FileService Create(SshSessionController ctl)
    {
        var (ci, client) = ctl.NetHandles();
        if (ci is null || client is null)
            throw new Exception("Сессия не подключена");
        IRemoteFs fs;
        try
        {
            fs = new SftpFs(ci);
        }
        catch
        {
            // dropbear без sftp-server — канонический фолбэк
            fs = new ExecFs(client);
        }
        // Стартовый путь проводника: extra["sftpPath"] (канон мака),
        // при фейле листинга — home, потом /
        string home;
        try { home = fs.Home(); } catch { home = "/"; }
        if (string.IsNullOrWhiteSpace(home)) home = "/";
        var start = ctl.SessionRef.Extra.GetValueOrDefault("sftpPath");
        var path = home;
        if (!string.IsNullOrWhiteSpace(start))
        {
            try { fs.List(start!); path = start!; }
            catch { /* фолбэк — home */ }
        }
        var svc = new FileService(fs, path) { HomeDir = home };
        svc.Remember(path);
        return svc;
    }

    private readonly object _sync = new();

    // SftpClient/SshClient не потокобезопасны, а панель и редактор делят
    // один бекенд — все операции через lock.
    public List<RemoteEntry> ListL(string p) { lock (_sync) return Fs.List(p); }
    public byte[] DownloadL(string p) { lock (_sync) return Fs.Download(p); }
    public void UploadL(string p, byte[] d) { lock (_sync) Fs.Upload(p, d); }
    public void DeleteL(string p, bool isDir) { lock (_sync) Fs.Delete(p, isDir); }
    public void MkdirL(string p) { lock (_sync) Fs.Mkdir(p); }
    public void RenameL(string a, string b) { lock (_sync) Fs.Rename(a, b); }
    public void ChmodL(string p, string octal) { lock (_sync) Fs.Chmod(p, octal); }
    public void DownloadDirL(string r, string l, Action<string> pr) { lock (_sync) RemoteFsRecursive.DownloadDir(Fs, r, l, pr); }
    public void UploadDirL(string l, string r, Action<string> pr) { lock (_sync) RemoteFsRecursive.UploadDir(Fs, l, r, pr); }

    public void Refresh() => Entries = ListL(CurrentPath);

    public void Dispose() => Fs.Dispose();
}
