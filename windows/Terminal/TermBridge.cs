using System.IO;
using System.Text.Json;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace QTermWin.Terminal;

/// <summary>
/// Мост C#↔xterm.js. Одна WebView2 на приложение, N терминалов в DOM.
/// Вывод SSH батчится (~16мс) — PostWebMessage на каждый чанк захлебнётся
/// на cat большого файла.
/// </summary>
public sealed class TermBridge
{
    private readonly WebView2 _web;
    private bool _ready;
    private readonly List<object> _pending = new();

    // Батчер вывода: id → накопленные байты
    private readonly Dictionary<Guid, MemoryStream> _outBuf = new();
    private readonly DispatcherTimer _flushTimer;

    public event Action<Guid, byte[]>? Input;          // байты в stdin сессии
    public event Action<Guid, int, int>? Resized;       // cols, rows
    public event Action? Ready;
    public event Action<string>? JsError;
    public event Action<string>? Hotkey; // id функции из UI.Hotkeys.Actions
    public event Action<Guid, string>? BroadcastCommand; // Enter в активной при «Во все»
    public event Action<string, string>? DictOp; // ("add"|"hide", cmd)
    public event Action<Guid, string>? PrefixChanged;   // набираемая команда ("" = скрыть)
    public event Action<Guid, string>? CommandEntered;  // Enter по чистой строке
    public event Action<Guid, string>? DeleteCommand;   // ПКМ по своей подсказке
    /// <summary>Шелл сообщил папку: (id, текст, osc7) — заголовок «user@host: /path» или OSC 7 file://.</summary>
    public event Action<Guid, string, bool>? Cwd;

    public TermBridge(WebView2 web)
    {
        _web = web;
        _flushTimer = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(16),
        };
        _flushTimer.Tick += (_, _) => FlushOutput();
    }

    public async Task InitAsync()
    {
        var userData = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "QTerm", "WebView2");
        var env = await CoreWebView2Environment.CreateAsync(userDataFolder: userData);
        await _web.EnsureCoreWebView2Async(env);

        var core = _web.CoreWebView2;
        core.Settings.AreBrowserAcceleratorKeysEnabled = false; // Ctrl+F/P/R — не браузеру
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.IsZoomControlEnabled = false;

        var assets = Path.Combine(AppContext.BaseDirectory, "Assets", "xterm");
        core.SetVirtualHostNameToFolderMapping(
            "qterm.assets", assets, CoreWebView2HostResourceAccessKind.Allow);

        core.WebMessageReceived += OnMessage;
        core.Navigate("https://qterm.assets/term.html");
    }

    private void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        using var doc = JsonDocument.Parse(e.TryGetWebMessageAsString());
        var root = doc.RootElement;
        switch (root.GetProperty("op").GetString())
        {
            case "ready":
                _ready = true;
                foreach (var m in _pending) PostRaw(m);
                _pending.Clear();
                _flushTimer.Start();
                Ready?.Invoke();
                break;
            case "in":
                Input?.Invoke(
                    Guid.Parse(root.GetProperty("id").GetString()!),
                    Convert.FromBase64String(root.GetProperty("data").GetString()!));
                break;
            case "resize":
                Resized?.Invoke(
                    Guid.Parse(root.GetProperty("id").GetString()!),
                    root.GetProperty("cols").GetInt32(),
                    root.GetProperty("rows").GetInt32());
                break;
            case "prefix":
                PrefixChanged?.Invoke(
                    Guid.Parse(root.GetProperty("id").GetString()!),
                    root.GetProperty("prefix").GetString()!);
                break;
            case "cmd":
                CommandEntered?.Invoke(
                    Guid.Parse(root.GetProperty("id").GetString()!),
                    root.GetProperty("cmd").GetString()!);
                break;
            case "copy":
                try { System.Windows.Clipboard.SetText(root.GetProperty("text").GetString() ?? ""); }
                catch { /* буфер занят другим процессом — бывает, молчим */ }
                break;
            case "paste":
                try
                {
                    var clip = System.Windows.Clipboard.GetText();
                    if (!string.IsNullOrEmpty(clip))
                        // Обратно в JS через term.paste(): вставка проходит ТРЕКЕР
                        // (иначе рассинхрон буфера — подсказки дохли на вкладке)
                        Post(new
                        {
                            op = "do-paste",
                            id = root.GetProperty("id").GetString(),
                            data = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(clip)),
                        });
                }
                catch { }
                break;
            case "dict":
                DictOp?.Invoke(root.GetProperty("act").GetString() ?? "",
                               root.GetProperty("cmd").GetString() ?? "");
                break;
            case "bcast-cmd":
                BroadcastCommand?.Invoke(
                    Guid.Parse(root.GetProperty("id").GetString()!),
                    root.GetProperty("cmd").GetString()!);
                break;
            case "hotkey":
                Hotkey?.Invoke(root.GetProperty("key").GetString() ?? "");
                break;
            case "jserr":
                JsError?.Invoke(root.GetProperty("text").GetString() ?? "");
                break;
            case "cwd":
                Cwd?.Invoke(
                    Guid.Parse(root.GetProperty("id").GetString()!),
                    root.GetProperty("v").GetString() ?? "",
                    root.TryGetProperty("osc7", out var o7) && o7.GetBoolean());
                break;
            case "delcmd":
                DeleteCommand?.Invoke(
                    Guid.Parse(root.GetProperty("id").GetString()!),
                    root.GetProperty("cmd").GetString()!);
                break;
        }
    }

    private void Post(object m)
    {
        if (!_ready) { _pending.Add(m); return; }
        PostRaw(m);
    }

    private void PostRaw(object m) =>
        _web.CoreWebView2.PostWebMessageAsString(JsonSerializer.Serialize(m));

    public void CreateTerm(Guid id) => Post(new { op = "create", id = id.ToString() });
    public void Show(Guid id)       => Post(new { op = "show", id = id.ToString() });
    public void Fit()               => Post(new { op = "fit" });
    public void Clear(Guid id)      => Post(new { op = "clear", id = id.ToString() });
    public void SetBroadcast(bool on) => Post(new { op = "broadcast", on });
    public void SetTermFontSize(int size) => Post(new { op = "font", size });
    public void SetScrollback(int lines) => Post(new { op = "scrollback", lines });
    public void SetTermTheme(bool light) => Post(new { op = "theme", light });

    /// <summary>Горячие клавиши в xterm: ловятся по ev.code (физическая клавиша).</summary>
    public void SetKeys(IEnumerable<(string Id, bool Ctrl, bool Shift, bool Alt, string Code)> keys) =>
        Post(new
        {
            op = "keys",
            items = keys.Select(k => new { id = k.Id, c = k.Ctrl, s = k.Shift, a = k.Alt, code = k.Code }).ToArray(),
        });

    public void Suggest(Guid id, string prefix, IEnumerable<(string T, bool Own)> items) =>
        Post(new
        {
            op = "suggest",
            id = id.ToString(),
            prefix,
            items = items.Select(x => new { t = x.T, own = x.Own }).ToArray(),
        });

    public void Close(Guid id)
    {
        lock (_outBuf) _outBuf.Remove(id);
        Post(new { op = "close", id = id.ToString() });
    }

    /// <summary>Из SSH-потока (любой тред) — в батчер.</summary>
    public void Output(Guid id, byte[] data)
    {
        lock (_outBuf)
        {
            if (!_outBuf.TryGetValue(id, out var ms))
                _outBuf[id] = ms = new MemoryStream();
            ms.Write(data);
        }
    }

    private void FlushOutput()
    {
        List<(Guid, byte[])>? batch = null;
        lock (_outBuf)
        {
            foreach (var (id, ms) in _outBuf)
            {
                if (ms.Length == 0) continue;
                (batch ??= new()).Add((id, ms.ToArray()));
                ms.SetLength(0);
            }
        }
        if (batch is null) return;
        foreach (var (id, data) in batch)
            Post(new { op = "out", id = id.ToString(), data = Convert.ToBase64String(data) });
    }
}
