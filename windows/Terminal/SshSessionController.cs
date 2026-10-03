using System.IO;
using System.Security.Cryptography;
using System.Text;
using Renci.SshNet;
using SshNet.Agent;
using Renci.SshNet.Common;
using QTermWin.Models;
using Session = QTermWin.Models.Session;

namespace QTermWin.Terminal;

public enum SessState { Connecting, Connected, Disconnected, Failed }

/// <summary>
/// Одна SSH-сессия (одна вкладка). Все сетевые вызовы — с фонового потока
/// вызывающего; колбэки Ask*/Save*/ConfirmHostKeyChange обязаны сами
/// маршалиться в UI (MainWindow передаёт уже обёрнутые в Dispatcher).
/// </summary>
public sealed class SshSessionController : IDisposable
{
    public Guid TabId { get; }
    private readonly Session _session;
    private readonly SSHKey? _vaultKey;
    private readonly Func<string, string?> _secretGet;

    private SshClient? _client;
    private ShellStream? _shell;
    private ConnectionInfo? _ci;

    /// <summary>Для файловой панели: ConnectionInfo (второе подключение SFTP)
    /// и живой клиент (exec-фолбэк).</summary>
    public (ConnectionInfo? Ci, SshClient? Client) NetHandles() => (_ci, _client);

    /// <summary>Нода этой сессии (для sftpPath/«Отключить» из UI).</summary>
    public Session SessionRef => _session;
    private readonly object _writeLock = new();
    private volatile bool _closed;
    private volatile bool _wasConnected;
    private int _generation;
    private int _cols = 120, _rows = 30;

    public event Action<byte[]>? Output;
    public event Action<SessState, string?>? StateChanged;

    // UI-колбэки (уже промаршаленные в Dispatcher снаружи):
    /// <summary>prompt → (пароль|null, сохранять ли в вейлт).</summary>
    public required Func<string, (string? Password, bool Save)> AskPassword { get; init; }
    public required Func<string, string, bool> ConfirmHostKeyChange { get; init; } // oldFp,newFp → доверять?
    public required Action<string> SaveHostKey { get; init; }                      // b64 wire-блоба
    public required Action<string, string> SaveSecret { get; init; }               // ключ secrets, значение

    public SshSessionController(Guid tabId, Session session, SSHKey? vaultKey,
        Func<string, string?> secretGet)
    {
        TabId = tabId;
        _session = session;
        _vaultKey = vaultKey;
        _secretGet = secretGet;
    }

    private static string UpperId(Guid id) => id.ToString("D").ToUpperInvariant();
    private static string Fp(byte[] wire) =>
        "SHA256:" + Convert.ToBase64String(SHA256.HashData(wire)).TrimEnd('=');

    private void Banner(string text, string color = "33") =>
        Output?.Invoke(Encoding.UTF8.GetBytes($"\x1b[{color}m{text}\x1b[0m\r\n"));

    public void Connect(int cols, int rows)
    {
        _cols = cols > 0 ? cols : 120;
        _rows = rows > 0 ? rows : 30;
        try
        {
            StateChanged?.Invoke(SessState.Connecting, null);
            ConnectCore();
            _wasConnected = true;
            StateChanged?.Invoke(SessState.Connected, null);
        }
        catch (Exception ex) when (!_closed)
        {
            Banner("Ошибка: " + ex.Message, "31");
            StateChanged?.Invoke(SessState.Failed, ex.Message);
        }
    }

    /// <summary>Авто-реконнект после обрыва (НЕ после неудачного логина):
    /// бэкофф 2-4-8-16-30с, generation убивает гонки (канон мак/андроид).</summary>
    private void StartAutoReconnect()
    {
        if (!_wasConnected) return;
        var gen = Interlocked.Increment(ref _generation);
        Task.Run(async () =>
        {
            int[] delays = { 2, 4, 8, 16, 30 };
            for (int attempt = 0; ; attempt++)
            {
                await Task.Delay(TimeSpan.FromSeconds(delays[Math.Min(attempt, delays.Length - 1)]));
                if (_closed || gen != _generation) return;
                Banner($"Авто-реконнект, попытка {attempt + 1}…");
                try
                {
                    StateChanged?.Invoke(SessState.Connecting, null);
                    try { _shell?.Dispose(); } catch { }
                    try { _client?.Dispose(); } catch { }
                    _shell = null; _client = null;
                    ConnectCore();
                    StateChanged?.Invoke(SessState.Connected, null);
                    return;
                }
                catch (Exception ex)
                {
                    if (_closed || gen != _generation) return;
                    Banner("Не вышло: " + ex.Message, "31");
                    StateChanged?.Invoke(SessState.Disconnected, ex.Message);
                }
            }
        });
    }

    private void ConnectCore()
    {
        if (_session.AuthMethod == AuthMethod.agent)
        {
            var ac = ConnectAgent();
            FinishConnect(ac, null);
            return;
        }
        var methods = BuildAuth(out var passwordUsed);
        SshClient client;
        try
        {
            client = ConnectWith(methods);
        }
        catch (Renci.SshNet.Common.SshAuthenticationException)
            when (_session.AuthMethod == AuthMethod.privateKey)
        {
            // Канон андроида: ключ не принят → фолбэк на пароль
            Banner("Ключ не принят — пробую пароль");
            string pw;
            var stored = _secretGet($"{UpperId(_session.Id)}.password");
            if (stored is not null) pw = stored;
            else
            {
                var (entered, save) = AskPassword($"Ключ отвергнут. Пароль {_session.Username}@{_session.Host}");
                pw = entered ?? throw new Exception("Отменено");
                passwordUsed = save ? pw : null;
            }
            var kbd = new KeyboardInteractiveAuthenticationMethod(_session.Username);
            kbd.AuthenticationPrompt += (_, e) => { foreach (var pr in e.Prompts) pr.Response = pw; };
            client = ConnectWith(new()
            {
                new PasswordAuthenticationMethod(_session.Username, pw), kbd,
            });
        }
        FinishConnect(client, passwordUsed);
    }

    private sealed class BoolBox { public bool Value = true; }

    private SshClient ConnectWith(List<AuthenticationMethod> methods)
    {
        var ci = new ConnectionInfo(_session.Host, _session.Port, _session.Username, methods.ToArray())
        {
            Timeout = TimeSpan.FromSeconds(15),
        };
        _ci = ci;
        var client = new SshClient(ci);
        AttachTofu(client, out var trusted);
        client.Connect();
        if (!trusted.Value) { client.Dispose(); throw new Exception("Ключ хоста отвергнут"); }
        return client;
    }

    /// <summary>Агентная ветка (SshNet.Agent): ключи из OpenSSH-agent/Pageant.
    /// SSH.NET не даёт кастомную AuthenticationMethod, зато принимает готовые
    /// ключи агента в конструктор SshClient — форк не нужен.</summary>
    private SshClient ConnectAgent()
    {
        IPrivateKeySource[] keys;
        string src;
        try
        {
            try { keys = new SshAgent().RequestIdentities().ToArray(); src = "OpenSSH-agent"; }
            catch { keys = new Pageant().RequestIdentities().ToArray(); src = "Pageant"; }
        }
        catch (Exception ex) when (ex is MissingMethodException or MissingFieldException
            or TypeLoadException or BadImageFormatException
            || ex.InnerException is MissingMethodException or TypeLoadException)
        {
            // Пакет агента собран под SSH.NET 2024.x — на 2026.0.0 API разъехался
            throw new Exception(
                "Пакет агента несовместим с SSH.NET 2026 (" + ex.GetType().Name +
                "). Скажи — пришлю сборку с фиксацией версии SSH.NET 2024.2.0: " + ex.Message);
        }
        catch (Exception ex)
        {
            throw new Exception("Агент недоступен (запущен ssh-agent/Pageant с ключами?): " + ex.Message);
        }
        if (keys.Length == 0)
            throw new Exception("В агенте нет ключей (ssh-add / добавь в Pageant)");
        Banner($"{src}: ключей в агенте — {keys.Length}");

        var client = new SshClient(_session.Host, _session.Port, _session.Username, keys);
        client.ConnectionInfo.Timeout = TimeSpan.FromSeconds(15);
        AttachTofu(client, out var trusted);
        client.Connect();
        if (!trusted.Value) { client.Dispose(); throw new Exception("Ключ хоста отвергнут"); }
        return client;
    }

    private void AttachTofu(SshClient client, out BoolBox trusted)
    {
        var box = new BoolBox();
        trusted = box;
        client.HostKeyReceived += (_, e) =>
        {
            var seen = Convert.ToBase64String(e.HostKey);
            if (!_session.Extra.TryGetValue("hostkey", out var known) || string.IsNullOrEmpty(known))
            {
                SaveHostKey(seen);
                _session.Extra["hostkey"] = seen;
                Banner($"Первый контакт: ключ хоста сохранён ({Fp(e.HostKey)})");
                e.CanTrust = true;
                return;
            }
            if (known == seen) { e.CanTrust = true; return; }

            var oldFp = "SHA256:" + Convert.ToBase64String(
                SHA256.HashData(Convert.FromBase64String(known))).TrimEnd('=');
            var ok = ConfirmHostKeyChange(oldFp, Fp(e.HostKey));
            if (ok)
            {
                SaveHostKey(seen);
                _session.Extra["hostkey"] = seen;
            }
            else box.Value = false;
            e.CanTrust = ok;
        };
    }

    private void FinishConnect(SshClient client, string? passwordUsed)
    {
        client.KeepAliveInterval = TimeSpan.FromSeconds(25);
        client.ErrorOccurred += (_, e) => OnDrop("ошибка: " + e.Exception.Message);
        _client = client;

        // Пароль сработал и его не было в вейлте — доливаем
        if (passwordUsed is { } pw && _secretGet($"{UpperId(_session.Id)}.password") is null)
            SaveSecret($"{UpperId(_session.Id)}.password", pw);

        var shell = client.CreateShellStream("xterm-256color",
            (uint)_cols, (uint)_rows, 0, 0, 32768);
        // cd termPath — ПО ПЕРВОМУ ВЫВОДУ шелла (промпт пришёл = шелл жив).
        // Запись сразу после CreateShellStream SSH.NET глотал до старта шелла.
        var needCd = _session.Extra.TryGetValue("termPath", out var tp)
            && !string.IsNullOrWhiteSpace(tp) ? tp : null;
        int cdSent = 0;
        shell.DataReceived += (_, e) =>
        {
            Output?.Invoke(e.Data);
            if (needCd is not null && Interlocked.Exchange(ref cdSent, 1) == 0)
                Write(Encoding.UTF8.GetBytes($"cd '{needCd.Replace("'", "'\\''")}'\n"));
        };
        shell.Closed += (_, _) => OnDrop("соединение закрыто");
        _shell = shell;
    }

    /// <summary>Переподключение с тем же терминалом: скроллбек сохраняется,
    /// cd termPath повторится (канон мак/андроид).</summary>
    public void Reconnect()
    {
        if (_closed) return;
        Interlocked.Increment(ref _generation); // убить авто-цикл
        try { _shell?.Dispose(); } catch { }
        try { _client?.Dispose(); } catch { }
        _shell = null; _client = null;
        Banner("Переподключение…");
        Connect(_cols, _rows);
    }

    private List<AuthenticationMethod> BuildAuth(out string? passwordUsed)
    {
        passwordUsed = null;
        var user = _session.Username;

        if (_session.AuthMethod == AuthMethod.privateKey)
        {
            string? keyText = null;
            string passKey = "";
            if (_vaultKey is not null)
            {
                keyText = _vaultKey.PrivateKey;
                passKey = $"key:{UpperId(_vaultKey.Id)}.passphrase";
            }
            else if (_session.PrivateKeyPath is { } p && File.Exists(p))
            {
                keyText = File.ReadAllText(p);
                passKey = $"path:{p}.passphrase";
            }

            if (keyText is null)
            {
                // Нода без ключа (или файловый ключ не найден) — честный пароль,
                // сам QTerm НИЧЕГО не назначает
                Banner("Ключ не назначен/не найден — вход по паролю");
            }
            else
            {
                var passphrase = _secretGet(passKey)
                    ?? _secretGet($"{UpperId(_session.Id)}.privateKeyPassphrase"); // легаси

                PrivateKeyFile pk;
                try
                {
                    pk = MakeKey(keyText, passphrase);
                }
                catch (SshPassPhraseNullOrEmptyException)
                {
                    var (entered, save) = AskPassword($"Passphrase ключа «{_vaultKey?.Name ?? _session.PrivateKeyPath}»");
                    if (entered is null) throw new Exception("Отменено");
                    pk = MakeKey(keyText, entered); // не подошла — исключение наружу
                    if (save) SaveSecret(passKey, entered);
                }
                return new() { new PrivateKeyAuthenticationMethod(user, pk) };
            }
        }

        // password: из вейлта или спросить; + keyboard-interactive тем же
        // паролем (часть серверов требует именно его)
        var pw = _secretGet($"{UpperId(_session.Id)}.password");
        if (pw is null)
        {
            var (entered, save) = AskPassword($"Пароль {user}@{_session.Host}");
            pw = entered ?? throw new Exception("Отменено");
            passwordUsed = save ? pw : null;
        }
        var kbd = new KeyboardInteractiveAuthenticationMethod(user);
        var pwCopy = pw;
        kbd.AuthenticationPrompt += (_, e) =>
        {
            foreach (var p in e.Prompts) p.Response = pwCopy;
        };
        return new() { new PasswordAuthenticationMethod(user, pw), kbd };
    }

    private static PrivateKeyFile MakeKey(string keyText, string? passphrase)
    {
        var ms = new MemoryStream(Encoding.UTF8.GetBytes(keyText));
        return passphrase is null ? new PrivateKeyFile(ms) : new PrivateKeyFile(ms, passphrase);
    }

    private void OnDrop(string reason)
    {
        if (_closed) return;
        Banner("Разрыв: " + reason, "31");
        StateChanged?.Invoke(SessState.Disconnected, reason);
        StartAutoReconnect();
    }

    /// <summary>stdin (из моста, любой тред).</summary>
    public void Write(byte[] data)
    {
        lock (_writeLock)
        {
            try
            {
                if (data.Length > 4096)
                {
                    // Портянки (heredoc от LLM) — чанками, чтобы PTY не резал частичной записью
                    for (int off = 0; off < data.Length; off += 4096)
                    {
                        var n = Math.Min(4096, data.Length - off);
                        _shell?.Write(data, off, n);
                        _shell?.Flush();
                        Thread.Sleep(8);
                    }
                    return;
                }
                _shell?.Write(data, 0, data.Length);
                _shell?.Flush();
            }
            catch { OnDrop("запись не удалась"); }
        }
    }

    /// <summary>
    /// window-change. Публичного API в SSH.NET нет по сей день (issue #40) —
    /// рефлексия в канал с тихой деградацией: не вышло — размер останется
    /// стартовым, ничего не ломается.
    /// </summary>
    public void Resize(int cols, int rows)
    {
        _cols = cols; _rows = rows;
        var shell = _shell;
        if (shell is null) return;
        try
        {
            var ch = shell.GetType()
                .GetField("_channel", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
                ?.GetValue(shell);
            ch?.GetType().GetMethod("SendWindowChangeRequest")
                ?.Invoke(ch, new object[] { (uint)cols, (uint)rows, 0u, 0u });
        }
        catch { }
    }

    public void Dispose()
    {
        _closed = true;
        try { _shell?.Dispose(); } catch { }
        try { _client?.Dispose(); } catch { }
    }
}
