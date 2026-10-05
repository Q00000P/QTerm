using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using QTermShared;

namespace QTermWin.UI;

/// <summary>
/// QTerm ↔ QEditor (отдельное приложение, мак-канон). QTerm — клиент канала:
/// поднимает QEditor.exe при необходимости, шлёт файлы нод (open), принимает
/// save и заливает через свой SSH/SFTP/exec, отвечает saved.
/// </summary>
public sealed class EditorBridge
{
    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int dwProcessId);
    private const int ASFW_ANY = -1;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _wl = new();
    private NamedPipeClientStream? _pipe;
    private StreamWriter? _w;
    private readonly Dictionary<string, (Files.FileService Svc, string Remote)> _routes = new();

    /// <summary>Открыть файл ноды в QEditor. Возвращает id документа.</summary>
    public async Task<string> OpenAsync(Files.FileService svc, string remote, byte[] data, string node)
    {
        var doc = Guid.NewGuid().ToString("N");
        lock (_routes) _routes[doc] = (svc, remote);
        await SendAsync(new EditorMsg
        {
            Op = "open", Doc = doc, Node = node, Path = remote, Data = Convert.ToBase64String(data),
        });
        return doc;
    }

    /// <summary>Сравнить два открытых документа (вкладка diff в QEditor).</summary>
    public Task CompareAsync(string docA, string docB) =>
        SendAsync(new EditorMsg { Op = "compare", Doc = docA, Text = docB });

    /// <summary>Сравнить документ ноды с локальным файлом.</summary>
    public Task CompareLocalAsync(string docA, string localPath) =>
        SendAsync(new EditorMsg { Op = "compare", Doc = docA, Path = localPath });

    public Task NewDocAsync() => SendAsync(new EditorMsg { Op = "new" });

    private async Task SendAsync(EditorMsg m)
    {
        var line = EditorProtocol.Encode(m);
        await _gate.WaitAsync();
        try
        {
            // QEditor без окна (упал при закрытии, но жив и держит канал) молча съел бы файл — убрать, канал к нему бросить
            if (await Task.Run(() => EditorProcess.KillZombies("QTerm перед открытием в QEditor")) > 0) Drop();
            for (int attempt = 0; attempt < 2; attempt++)
            {
                if (!await EnsureConnectedAsync())
                    throw new Exception("QEditor не запустился");
                AllowSetForegroundWindow(ASFW_ANY); // пусть редактор вынырнет поверх
                try
                {
                    lock (_wl) _w!.WriteLine(line);
                    return;
                }
                catch (IOException) { Drop(); } // редактор закрыли — переподключиться
            }
            throw new Exception("QEditor не отвечает");
        }
        finally { _gate.Release(); }
    }

    private void Drop()
    {
        lock (_wl)
        {
            try { _pipe?.Dispose(); } catch { }
            _pipe = null;
            _w = null;
        }
    }

    private async Task<bool> EnsureConnectedAsync()
    {
        lock (_wl) if (_pipe is { IsConnected: true } && _w is not null) return true;
        Drop();
        if (await TryConnectAsync(300)) return true;
        var exe = FindEditorExe() ?? throw new Exception(
            "QEditor.exe не найден рядом с QTerm.exe — положи его в ту же папку");
        Process.Start(new ProcessStartInfo(exe, "--from-qterm") { UseShellExecute = false });
        for (int i = 0; i < 40; i++)
        {
            if (await TryConnectAsync(250)) return true;
            await Task.Delay(100);
        }
        return false;
    }

    private async Task<bool> TryConnectAsync(int timeoutMs)
    {
        var p = new NamedPipeClientStream(".", EditorProtocol.PipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous);
        try { await p.ConnectAsync(timeoutMs); }
        catch { p.Dispose(); return false; }
        var w = EditorProtocol.Writer(p);
        try { w.WriteLine(EditorProtocol.Encode(new EditorMsg { Op = "hello" })); }
        catch { p.Dispose(); return false; }
        lock (_wl) { _pipe = p; _w = w; }
        _ = Task.Run(() => ReadLoop(p));
        return true;
    }

    private async Task ReadLoop(NamedPipeClientStream p)
    {
        try
        {
            using var r = EditorProtocol.Reader(p);
            string? line;
            while ((line = await r.ReadLineAsync()) is not null)
            {
                if (EditorProtocol.Decode(line) is not { } m) continue;
                if (m.Op == "save") _ = Task.Run(() => HandleSave(m));
                else if (m.Op == "reload") _ = Task.Run(() => HandleReload(m));
                else if (m.Op == "closed" && m.Doc is not null)
                    lock (_routes) _routes.Remove(m.Doc);
            }
        }
        catch { }
        finally
        {
            lock (_wl) if (_pipe == p) { _pipe = null; _w = null; }
        }
    }

    private void HandleSave(EditorMsg m)
    {
        var reply = new EditorMsg { Op = "saved", Doc = m.Doc };
        Files.FileService? svc = null;
        string? remote = null;
        lock (_routes)
            if (m.Doc is not null && _routes.TryGetValue(m.Doc, out var route))
                (svc, remote) = route;
        if (svc is null || remote is null)
        {
            reply.Ok = false;
            reply.Error = "вкладка ноды в QTerm закрыта — файл больше не привязан";
        }
        else
        {
            try
            {
                // сырые байты от QEditor (он сам кодирует и ставит концы строк);
                // text — совместимость со старым протоколом
                var data = m.Data is not null ? Convert.FromBase64String(m.Data)
                    : new UTF8Encoding(false).GetBytes(m.Text ?? "");
                svc.UploadL(remote, data);
                reply.Ok = true;
                reply.Bytes = data.Length;
            }
            catch (Exception ex)
            {
                reply.Ok = false;
                reply.Error = ex.Message;
            }
        }
        lock (_wl)
        {
            try { _w?.WriteLine(EditorProtocol.Encode(reply)); } catch { }
        }
    }

    private void HandleReload(EditorMsg m)
    {
        var reply = new EditorMsg { Op = "reloaded", Doc = m.Doc };
        Files.FileService? svc = null;
        string? remote = null;
        lock (_routes)
            if (m.Doc is not null && _routes.TryGetValue(m.Doc, out var route))
                (svc, remote) = route;
        if (svc is null || remote is null)
        {
            reply.Ok = false;
            reply.Error = "вкладка ноды в QTerm закрыта — файл больше не привязан";
        }
        else
        {
            try { reply.Data = Convert.ToBase64String(svc.DownloadL(remote)); }
            catch (Exception ex) { reply.Ok = false; reply.Error = ex.Message; }
        }
        lock (_wl)
        {
            try { _w?.WriteLine(EditorProtocol.Encode(reply)); } catch { }
        }
    }

    /// <summary>Релиз: QEditor.exe рядом с QTerm.exe. Дев (dotnet run): ищем
    /// Editor\bin\**\QEditor.exe вверх по дереву от бинаря.</summary>
    private static string? FindEditorExe()
    {
        var dir = Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;
        var near = Path.Combine(dir, "QEditor.exe");
        if (File.Exists(near)) return near;
        for (var d = new DirectoryInfo(dir); d is not null; d = d.Parent)
        {
            var proj = Path.Combine(d.FullName, "Editor", "QEditor.csproj");
            if (!File.Exists(proj)) continue;
            var bin = Path.Combine(d.FullName, "Editor", "bin");
            if (!Directory.Exists(bin)) return null;
            return Directory.GetFiles(bin, "QEditor.exe", SearchOption.AllDirectories)
                .OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
        }
        return null;
    }
}
