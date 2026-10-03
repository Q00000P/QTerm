using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;
using QTermWin.Models;
using QTermWin.Vault;

namespace QTermWin.Sync;

/// <summary>Конфиг синка — живёт в secrets["sync.config"], в облако не уходит
/// (всё с префиксом "sync." режется из облачной копии). Имена полей = Swift.</summary>
public sealed class SyncConfig
{
    [JsonPropertyName("url")] public string Url { get; set; } = "";
    [JsonPropertyName("login")] public string Login { get; set; } = "";
    [JsonPropertyName("webdavPassword")] public string WebdavPassword { get; set; } = "";
    [JsonPropertyName("encPassword")] public string EncPassword { get; set; } = "";
    [JsonPropertyName("enabled")] public bool Enabled { get; set; }
    [JsonPropertyName("backend")] public string? Backend { get; set; }
    [JsonPropertyName("gdFolder")] public string? GdFolder { get; set; }
    [JsonPropertyName("gdRefreshToken")] public string? GdRefreshToken { get; set; }

    [JsonIgnore] public bool IsGDrive => Backend == "gdrive";
    [JsonIgnore] public bool GdConnected => !string.IsNullOrEmpty(GdRefreshToken);

    // OAuth-клиент «QTerm Desktop» — один на mac/win/linux. Client ID публичный;
    // client secret в исходниках не храним — подставляется при сборке (BuildSecrets).
    public const string GoogleClientId = "422218910721-oankvt8u3bp377g6ejmvr4p4s5437plj.apps.googleusercontent.com";
    public static string GoogleClientSecret => BuildSecrets.Get("GoogleClientSecret");

    public const string SecretKey = "sync.config";
}

/// <summary>Цикл pull → LWW-merge → push. Дебаунс пуша 2с после мутаций,
/// пул на старте, защита от параллельных циклов (канон мака).</summary>
public sealed class SyncEngine
{
    private readonly VaultRepo _repo;
    private readonly Dispatcher _ui;
    private readonly DispatcherTimer _debounce;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private bool _rerun;

    public event Action<string, bool>? Status; // текст, isError

    /// <summary>Вейлт, который едет синком (для сводки «что синхронизируется»).</summary>
    public VaultRepo Repo => _repo;

    public SyncEngine(VaultRepo repo, Dispatcher ui)
    {
        _repo = repo;
        _ui = ui;
        _debounce = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _debounce.Tick += (_, _) => { _debounce.Stop(); _ = Task.Run(SyncNowAsync); };
        _repo.SyncChanged += SchedulePush;
    }

    public SyncConfig Config
    {
        get
        {
            var raw = _repo.Data.Secrets?.GetValueOrDefault(SyncConfig.SecretKey);
            if (raw is null) return new SyncConfig();
            try { return JsonSerializer.Deserialize<SyncConfig>(raw) ?? new SyncConfig(); }
            catch { return new SyncConfig(); }
        }
        set
        {
            _repo.Data.Secrets ??= new();
            _repo.Data.Secrets[SyncConfig.SecretKey] = JsonSerializer.Serialize(value);
            _repo.Persist(sync: false); // сам конфиг пуш не триггерит
        }
    }

    public void SchedulePush()
    {
        if (!Config.Enabled) return;
        _debounce.Stop();
        _debounce.Start();
    }

    public void PullOnLaunch()
    {
        if (Config.Enabled) _ = Task.Run(SyncNowAsync);
    }

    private void Report(string text, bool err = false) => Status?.Invoke(text, err);

    public async Task SyncNowAsync()
    {
        var cfg = Config;
        if (!cfg.Enabled) return;
        if (string.IsNullOrEmpty(cfg.EncPassword)) { Report("Пустой пароль шифрования", true); return; }

        ISyncTransport transport;
        if (cfg.IsGDrive)
        {
            if (!cfg.GdConnected) { Report("Google не подключён — «Войти в Google»", true); return; }
            transport = new GDriveTransport(cfg.GdRefreshToken!, cfg.GdFolder ?? "QTerm");
        }
        else
        {
            if (!Uri.TryCreate(cfg.Url, UriKind.Absolute, out var u) || !u.Scheme.StartsWith("http"))
            { Report("Некорректный URL файла", true); return; }
            transport = new WebDavTransport(cfg.Url, cfg.Login, cfg.WebdavPassword);
        }

        if (!await _gate.WaitAsync(0)) { _rerun = true; return; }
        try
        {
            Report("Синхронизация…");
            var summary = "первый пуш";

            var blob = await transport.GetAsync();
            SessionVault? remote = null;
            if (blob is not null)
            {
                var payload = Qts1.Unpack(blob, cfg.EncPassword);
                remote = JsonSerializer.Deserialize<SessionVault>(payload, QtJson.Options)
                    ?? throw new Exception("Пустой payload блоба");
            }

            // Merge и persist — на UI-потоке (репо принадлежит ему)
            SessionVault cloud = _ui.Invoke(() =>
            {
                if (remote is not null)
                {
                    var merged = SyncMerge.Merge(_repo.Data, remote);
                    _repo.ReplaceData(merged, sync: false);
                    summary = $"слито: сессий {merged.Sessions.Count}, ключей {merged.SshKeys?.Count ?? 0}";
                }
                // Копия в облако БЕЗ "sync.*"
                var c = JsonSerializer.Deserialize<SessionVault>(
                    JsonSerializer.SerializeToUtf8Bytes(_repo.Data, QtJson.Options), QtJson.Options)!;
                c.Secrets = c.Secrets?
                    .Where(kv => !kv.Key.StartsWith("sync.", StringComparison.Ordinal))
                    .ToDictionary(kv => kv.Key, kv => kv.Value);
                return c;
            });

            var packed = Qts1.Pack(JsonSerializer.SerializeToUtf8Bytes(cloud, QtJson.Options), cfg.EncPassword);
            await transport.PutAsync(packed);
            Report($"{DateTime.Now:HH:mm:ss} · {summary}");
        }
        catch (Exception ex)
        {
            Report(ex.Message, true);
        }
        finally
        {
            _gate.Release();
            if (_rerun) { _rerun = false; _ = Task.Run(SyncNowAsync); }
        }
    }
}
