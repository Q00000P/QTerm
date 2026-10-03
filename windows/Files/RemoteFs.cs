using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using Renci.SshNet;

namespace QTermWin.Files;

public sealed record RemoteEntry(string Name, bool IsDir, long Size, string Modified,
    string Perms = "", string Owner = "", bool IsLink = false);

/// <summary>Файловые операции на удалённой ноде.</summary>
public interface IRemoteFs : IDisposable
{
    string Kind { get; } // "SFTP" | "exec"
    string Home();
    List<RemoteEntry> List(string path);
    byte[] Download(string path);
    void Upload(string path, byte[] data);
    void Delete(string path, bool isDir);
    void Mkdir(string path);
    void Rename(string oldPath, string newPath);
    void Chmod(string path, string octal);
}

public static class RemotePath
{
    public static string Join(string dir, string name) =>
        dir == "/" ? "/" + name : dir.TrimEnd('/') + "/" + name;
    public static string Parent(string p)
    {
        p = p.TrimEnd('/');
        var i = p.LastIndexOf('/');
        return i <= 0 ? "/" : p[..i];
    }
    public static string Q(string p) => "'" + p.Replace("'", "'\\''") + "'";
}

/// <summary>Штатный SFTP — отдельное подключение на том же ConnectionInfo.</summary>
public sealed class SftpFs : IRemoteFs
{
    private readonly SftpClient _sftp;
    public string Kind => "SFTP";

    public SftpFs(ConnectionInfo ci)
    {
        _sftp = new SftpClient(ci);
        _sftp.Connect(); // dropbear без sftp-server упадёт здесь → фолбэк
    }

    public string Home() => _sftp.WorkingDirectory;

    private static string PermString(Renci.SshNet.Sftp.ISftpFile f) => string.Concat(
        f.OwnerCanRead ? "r" : "-", f.OwnerCanWrite ? "w" : "-", f.OwnerCanExecute ? "x" : "-",
        f.GroupCanRead ? "r" : "-", f.GroupCanWrite ? "w" : "-", f.GroupCanExecute ? "x" : "-",
        f.OthersCanRead ? "r" : "-", f.OthersCanWrite ? "w" : "-", f.OthersCanExecute ? "x" : "-");

    public List<RemoteEntry> List(string path) =>
        _sftp.ListDirectory(path)
            .Where(f => f.Name is not "." and not "..")
            .Select(f => new RemoteEntry(f.Name, f.IsDirectory, f.Length,
                f.LastWriteTime.ToString("dd.MM.yy HH:mm"),
                PermString(f), $"{f.UserId}:{f.GroupId}", f.IsSymbolicLink))
            .OrderByDescending(e => e.IsDir).ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();

    public byte[] Download(string path)
    {
        using var ms = new MemoryStream();
        _sftp.DownloadFile(path, ms);
        return ms.ToArray();
    }

    public void Upload(string path, byte[] data)
    {
        using var ms = new MemoryStream(data);
        _sftp.UploadFile(ms, path, true);
    }

    public void Delete(string path, bool isDir)
    {
        if (isDir) DeleteRec(path);
        else _sftp.DeleteFile(path);
    }

    private void DeleteRec(string path)
    {
        foreach (var f in _sftp.ListDirectory(path).Where(f => f.Name is not "." and not ".."))
        {
            if (f.IsDirectory) DeleteRec(f.FullName);
            else _sftp.DeleteFile(f.FullName);
        }
        _sftp.DeleteDirectory(path);
    }

    public void Mkdir(string path) => _sftp.CreateDirectory(path);
    public void Rename(string oldPath, string newPath) => _sftp.RenameFile(oldPath, newPath);
    public void Chmod(string path, string octal) =>
        _sftp.ChangePermissions(path, Convert.ToInt16(octal, 8));
    public void Dispose() { try { _sftp.Dispose(); } catch { } }
}

/// <summary>
/// Фолбэк для dropbear без sftp-server (Кинетики): всё через exec-команды
/// BusyBox. Канон с мака/андроида: base64-чанки по 6000 символов —
/// dropbear рубит exec-команды длиннее ~9000.
/// </summary>
public sealed class ExecFs : IRemoteFs
{
    private const int ChunkLen = 6000;
    private readonly SshClient _client;
    public string Kind => "exec";

    public ExecFs(SshClient client) => _client = client;

    private string Run(string cmd)
    {
        using var c = _client.CreateCommand(cmd);
        var result = c.Execute();
        if (c.ExitStatus != 0)
            throw new Exception(string.IsNullOrWhiteSpace(c.Error) ? $"exit {c.ExitStatus}: {cmd}" : c.Error.Trim());
        return result;
    }

    public string Home() => Run("pwd").Trim();

    // BusyBox ls -lA: "drwxr-xr-x  2 root root  4096 Aug 20 12:00 name"
    private static readonly Regex LsLine = new(
        @"^([\-dl])([rwxstT\-]{9})\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+(\S+\s+\S+\s+\S+)\s+(.+)$",
        RegexOptions.Compiled);

    public List<RemoteEntry> List(string path)
    {
        var outp = Run($"ls -lA -- {RemotePath.Q(path)}");
        var list = new List<RemoteEntry>();
        foreach (var line in outp.Split('\n'))
        {
            var m = LsLine.Match(line.TrimEnd('\r'));
            if (!m.Success) continue; // "total N", девайсы и прочая экзотика
            var name = m.Groups[7].Value;
            var isLink = m.Groups[1].Value == "l";
            if (isLink)
            {
                var arrow = name.IndexOf(" -> ", StringComparison.Ordinal);
                if (arrow > 0) name = name[..arrow];
            }
            list.Add(new RemoteEntry(name,
                m.Groups[1].Value == "d",
                long.Parse(m.Groups[5].Value),
                m.Groups[6].Value,
                m.Groups[2].Value,
                $"{m.Groups[3].Value}:{m.Groups[4].Value}",
                isLink));
        }
        return list.OrderByDescending(e => e.IsDir)
                   .ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public byte[] Download(string path)
    {
        var b64 = Run($"base64 -- {RemotePath.Q(path)}");
        return Convert.FromBase64String(b64.Replace("\n", "").Replace("\r", ""));
    }

    public void Upload(string path, byte[] data)
    {
        var part = path + ".qtpart";
        var b64 = Convert.ToBase64String(data);
        Run($": > {RemotePath.Q(part)}");
        for (int i = 0; i < b64.Length; i += ChunkLen)
        {
            var chunk = b64.Substring(i, Math.Min(ChunkLen, b64.Length - i));
            Run($"printf '%s' '{chunk}' | base64 -d >> {RemotePath.Q(part)}");
        }
        Run($"mv -- {RemotePath.Q(part)} {RemotePath.Q(path)}");
    }

    public void Delete(string path, bool isDir) => Run($"rm -rf -- {RemotePath.Q(path)}");
    public void Mkdir(string path) => Run($"mkdir -p -- {RemotePath.Q(path)}");
    public void Rename(string oldPath, string newPath) =>
        Run($"mv -- {RemotePath.Q(oldPath)} {RemotePath.Q(newPath)}");
    public void Chmod(string path, string octal) => Run($"chmod {octal} -- {RemotePath.Q(path)}");
    public void Dispose() { } // клиент принадлежит контроллеру сессии
}

/// <summary>Рекурсивные операции поверх любого IRemoteFs, с прогрессом.</summary>
public static class RemoteFsRecursive
{
    public static void DownloadDir(IRemoteFs fs, string remote, string localDir,
        Action<string> progress)
    {
        System.IO.Directory.CreateDirectory(localDir);
        var entries = fs.List(remote);
        int i = 0;
        foreach (var en in entries)
        {
            i++;
            var r = RemotePath.Join(remote, en.Name);
            var l = System.IO.Path.Combine(localDir, en.Name);
            if (en.IsDir) DownloadDir(fs, r, l, progress);
            else
            {
                progress($"↓ {en.Name} ({i}/{entries.Count})");
                System.IO.File.WriteAllBytes(l, fs.Download(r));
            }
        }
    }

    public static void UploadDir(IRemoteFs fs, string localDir, string remote,
        Action<string> progress)
    {
        fs.Mkdir(remote);
        var files = System.IO.Directory.GetFiles(localDir);
        int i = 0;
        foreach (var f in files)
        {
            i++;
            progress($"↑ {System.IO.Path.GetFileName(f)} ({i}/{files.Length})");
            fs.Upload(RemotePath.Join(remote, System.IO.Path.GetFileName(f)),
                System.IO.File.ReadAllBytes(f));
        }
        foreach (var d in System.IO.Directory.GetDirectories(localDir))
            UploadDir(fs, d, RemotePath.Join(remote, System.IO.Path.GetFileName(d)), progress);
    }
}
