using System.IO;
using System.IO.Pipes;
using System.Windows.Threading;
using QTermShared;

namespace QEditor;

/// <summary>
/// Сервер канала на стороне QEditor. QTerm подключается (hello) и шлёт
/// open/new/activate; сохранить/перечитать файл ноды = save/reload →
/// QTerm делает это своим SSH и отвечает saved/reloaded. Экземпляров
/// сервера несколько — вторая копия QEditor может постучаться activate/new.
/// </summary>
public sealed class HostLink
{
    private readonly Dispatcher _ui;
    private readonly object _wl = new();
    private StreamWriter? _host;
    private readonly Dictionary<string, TaskCompletionSource<EditorMsg>> _pending = new();

    public event Action<EditorMsg>? Open;
    public event Action? NewDoc;
    public event Action? Activate;
    public event Action<string>? OpenLocal;
    public event Action<bool>? HostChanged;
    /// <summary>Сравнить: Doc с Text (id документа) или с локальным файлом Path.</summary>
    public event Action<EditorMsg>? Compare;

    public HostLink(Dispatcher ui) { _ui = ui; }

    public bool HostConnected { get { lock (_wl) return _host is not null; } }

    public void Start() => _ = Task.Run(AcceptLoop);

    private async Task AcceptLoop()
    {
        while (true)
        {
            NamedPipeServerStream srv;
            try
            {
                srv = new NamedPipeServerStream(EditorProtocol.PipeName, PipeDirection.InOut,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await srv.WaitForConnectionAsync();
            }
            catch { await Task.Delay(500); continue; }
            _ = Task.Run(() => Serve(srv));
        }
    }

    private async Task Serve(NamedPipeServerStream srv)
    {
        StreamWriter w = EditorProtocol.Writer(srv);
        bool isHost = false;
        try
        {
            using var r = EditorProtocol.Reader(srv);
            string? line;
            while ((line = await r.ReadLineAsync()) is not null)
            {
                if (EditorProtocol.Decode(line) is not { } m) continue;
                switch (m.Op)
                {
                    case "hello":
                        isHost = true;
                        lock (_wl) _host = w;
                        _ = _ui.InvokeAsync(() => HostChanged?.Invoke(true));
                        break;
                    case "open":
                        _ui.Invoke(() => Open?.Invoke(m));
                        break;
                    case "new":
                        _ui.Invoke(() => NewDoc?.Invoke());
                        break;
                    case "activate":
                        _ui.Invoke(() => Activate?.Invoke());
                        break;
                    case "compare":
                        _ui.Invoke(() => Compare?.Invoke(m));
                        break;
                    case "openlocal":
                        if (m.Path is { } lp) _ui.Invoke(() => OpenLocal?.Invoke(lp));
                        break;
                    case "saved":
                    case "reloaded":
                        Complete(m.Op + ":" + m.Doc, m);
                        break;
                }
            }
        }
        catch { /* обрыв канала */ }
        finally
        {
            if (isHost)
            {
                bool wasHost;
                lock (_wl) { wasHost = _host == w; if (wasHost) _host = null; }
                if (wasHost)
                {
                    FailPending("QTerm закрыт — связь с нодой потеряна");
                    _ = _ui.InvokeAsync(() => HostChanged?.Invoke(false));
                }
            }
            try { srv.Dispose(); } catch { }
        }
    }

    private void Complete(string key, EditorMsg m)
    {
        TaskCompletionSource<EditorMsg>? tcs = null;
        lock (_pending) if (_pending.Remove(key, out var t)) tcs = t;
        tcs?.TrySetResult(m);
    }

    private void FailPending(string why)
    {
        List<TaskCompletionSource<EditorMsg>> all;
        lock (_pending) { all = _pending.Values.ToList(); _pending.Clear(); }
        foreach (var t in all) t.TrySetResult(new EditorMsg { Op = "fail", Ok = false, Error = why });
    }

    private bool Send(EditorMsg m)
    {
        lock (_wl)
        {
            if (_host is null) return false;
            try { _host.WriteLine(EditorProtocol.Encode(m)); return true; }
            catch { _host = null; return false; }
        }
    }

    private async Task<EditorMsg> Request(string replyOp, EditorMsg m, TimeSpan timeout)
    {
        var key = replyOp + ":" + m.Doc;
        var tcs = new TaskCompletionSource<EditorMsg>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_pending) _pending[key] = tcs;
        if (!Send(m))
        {
            lock (_pending) _pending.Remove(key);
            return new EditorMsg { Ok = false, Error = "QTerm не запущен — с нодой связи нет (Ctrl+Shift+S — копия на диск)" };
        }
        var done = await Task.WhenAny(tcs.Task, Task.Delay(timeout));
        if (done != tcs.Task)
        {
            lock (_pending) _pending.Remove(key);
            return new EditorMsg { Ok = false, Error = "QTerm не ответил вовремя" };
        }
        return tcs.Task.Result;
    }

    /// <summary>Сохранить файл ноды: сырые байты уходят в QTerm, он заливает.</summary>
    public async Task<(bool Ok, string? Error, int Bytes)> SaveAsync(string doc, byte[] data)
    {
        var m = await Request("saved",
            new EditorMsg { Op = "save", Doc = doc, Data = Convert.ToBase64String(data) },
            TimeSpan.FromMinutes(2));
        return (m.Ok == true, m.Error, m.Bytes ?? 0);
    }

    /// <summary>Перечитать файл с ноды.</summary>
    public async Task<(byte[]? Data, string? Error)> ReloadAsync(string doc)
    {
        var m = await Request("reloaded", new EditorMsg { Op = "reload", Doc = doc }, TimeSpan.FromMinutes(2));
        if (m.Ok == false || m.Data is null) return (null, m.Error ?? "нет данных");
        try { return (Convert.FromBase64String(m.Data), null); }
        catch (Exception ex) { return (null, ex.Message); }
    }

    public void NotifyClosed(string doc) => Send(new EditorMsg { Op = "closed", Doc = doc });
}
