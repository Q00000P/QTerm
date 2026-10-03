using QTermWin.Models;
using QTermWin.Sync;
using QTermWin.Terminal;

namespace QTermWin.Vault;

public sealed record ImportStats(
    int SessionsAdded, int SessionsUpdated,
    int KeysAdded, int KeysUpdated,
    int SnippetsAdded, int SnippetsUpdated,
    int SecretsAdded, int GitAdded = 0, int GitUpdated = 0)
{
    public override string ToString() =>
        $"Ноды: +{SessionsAdded} / обновлено {SessionsUpdated}\n" +
        $"Ключи: +{KeysAdded} / обновлено {KeysUpdated}\n" +
        $"Сниппеты: +{SnippetsAdded} / обновлено {SnippetsUpdated}\n" +
        $"Команды Git: +{GitAdded} / обновлено {GitUpdated}\n" +
        $"Секреты: +{SecretsAdded}";
}

/// <summary>
/// Вейлт в памяти + persist. Merge-семантика импорта — как на андроиде:
/// существующие записи (по id) ОБНОВЛЯЮТСЯ из импорта («переэкспорт с
/// мака = обновить всё»), локальный extra["hostkey"] (TOFU этого
/// устройства) приоритетнее импортного, секреты — putIfAbsent.
/// </summary>
public sealed class VaultRepo
{
    private readonly LocalVaultStore _store;
    public SessionVault Data { get; private set; } = new();
    public event Action? Changed;
    /// <summary>Мутация, достойная пуша синка (дебаунс 2с в SyncEngine).</summary>
    public event Action? SyncChanged;

    public VaultRepo(LocalVaultStore? store = null)
    {
        _store = store ?? new LocalVaultStore();
    }

    public void LoadOrInit()
    {
        Data = _store.InitializeIfNeeded();
        if (SanitizeJournals() > 0) _store.Save(Data); // мусор → tombstone, уедет синком
        Changed?.Invoke();
    }

    public IEnumerable<Session> VisibleSessions =>
        Data.Sessions.Where(s => s.Deleted != true)
                     .OrderBy(s => s.Name, StringComparer.OrdinalIgnoreCase);

    public SSHKey? KeyById(Guid? id) =>
        id is null ? null : Data.SshKeys?.FirstOrDefault(k => k.Id == id && k.Deleted != true);

    public ImportStats MergeImport(SessionVault imported)
    {
        int sAdd = 0, sUpd = 0, kAdd = 0, kUpd = 0, nAdd = 0, nUpd = 0, secAdd = 0;

        // Сессии: обновление по id, локальный hostkey приоритетнее
        foreach (var imp in imported.Sessions)
        {
            var idx = Data.Sessions.FindIndex(s => s.Id == imp.Id);
            if (idx >= 0)
            {
                var localHostkey = Data.Sessions[idx].Extra.TryGetValue("hostkey", out var hk) ? hk : null;
                if (localHostkey is not null)
                    imp.Extra["hostkey"] = localHostkey;
                Data.Sessions[idx] = imp;
                sUpd++;
            }
            else
            {
                Data.Sessions.Add(imp);
                sAdd++;
            }
        }

        // Ключи из вейлта
        if (imported.SshKeys is { Count: > 0 } impKeys)
        {
            Data.SshKeys ??= new();
            foreach (var imp in impKeys)
            {
                var idx = Data.SshKeys.FindIndex(k => k.Id == imp.Id);
                if (idx >= 0) { Data.SshKeys[idx] = imp; kUpd++; }
                else          { Data.SshKeys.Add(imp); kAdd++; }
            }
        }

        // Сниппеты
        if (imported.Snippets is { Count: > 0 } impSnips)
        {
            Data.Snippets ??= new();
            foreach (var imp in impSnips)
            {
                var idx = Data.Snippets.FindIndex(n => n.Id == imp.Id);
                if (idx >= 0) { Data.Snippets[idx] = imp; nUpd++; }
                else          { Data.Snippets.Add(imp); nAdd++; }
            }
        }

        // Команды Git: обновление по id, как сниппеты
        int gAdd = 0, gUpd = 0;
        if (imported.GitCommands is { Count: > 0 } impGit)
        {
            Data.GitCommands ??= new();
            foreach (var imp in impGit)
            {
                var idx = Data.GitCommands.FindIndex(g => g.Id == imp.Id);
                if (idx >= 0) { Data.GitCommands[idx] = imp; gUpd++; }
                else          { Data.GitCommands.Add(imp); gAdd++; }
            }
        }

        // Секреты: putIfAbsent (локальные не перетираем)
        if (imported.Secrets is { Count: > 0 } impSecrets)
        {
            Data.Secrets ??= new();
            foreach (var (k, v) in impSecrets)
            {
                if (Data.Secrets.TryAdd(k, v)) secAdd++;
                else if (Xui.XuiStore.IsLww(k) && Xui.XuiStore.RemoteNewer(Data.Secrets[k], v))
                    Data.Secrets[k] = v; // панели 3x-ui — LWW, как в синке
            }
        }

        // Журнал команд: канонический merge (deleted у любой стороны →
        // LWW по lastUsed целиком; иначе count=max, lastUsed=max)
        if (imported.CmdHistoryScopes is { Count: > 0 } impScopes)
            Data.CmdHistoryScopes = SyncMerge.MergeScopes(Data.CmdHistoryScopes ?? new(), impScopes);
        if (imported.CmdDictUser is { Count: > 0 } impDict)
            Data.CmdDictUser = SyncMerge.MergeDictUser(Data.CmdDictUser ?? new(), impDict);
        if (imported.CmdHistory is { Count: > 0 } impHist)
        {
            Data.CmdHistory ??= new();
            foreach (var (cmd, imp) in impHist)
            {
                if (!Data.CmdHistory.TryGetValue(cmd, out var loc))
                {
                    Data.CmdHistory[cmd] = imp;
                    continue;
                }
                Data.CmdHistory[cmd] = MergeCmdStat(loc, imp);
            }
        }

        Persist();
        return new ImportStats(sAdd, sUpd, kAdd, kUpd, nAdd, nUpd, secAdd, gAdd, gUpd);
    }

    private static CmdStat MergeCmdStat(CmdStat a, CmdStat b)
    {
        if (a.Deleted == true || b.Deleted == true)
        {
            var la = a.LastUsed ?? "";
            var lb = b.LastUsed ?? "";
            return string.CompareOrdinal(lb, la) > 0 ? b : a; // ничья = локальный
        }
        return new CmdStat
        {
            Count = Math.Max(a.Count, b.Count),
            LastUsed = string.CompareOrdinal(b.LastUsed ?? "", a.LastUsed ?? "") > 0
                ? b.LastUsed : a.LastUsed,
        };
    }

    // ── Команды Git ──

    public IEnumerable<GitCommand> VisibleGitCommands =>
        (Data.GitCommands ?? new()).Where(g => g.Deleted != true)
            .OrderBy(g => g.Name, StringComparer.OrdinalIgnoreCase);

    public GitCommand? GitCommandById(Guid id) =>
        Data.GitCommands?.FirstOrDefault(g => g.Id == id && g.Deleted != true);

    /// <summary>Добавить/обновить (по id), updatedAt = сейчас → уедет синком.</summary>
    public void SaveGitCommand(GitCommand g)
    {
        Data.GitCommands ??= new();
        g.UpdatedAt = QtJson.NowIso();
        g.Deleted = null;
        var idx = Data.GitCommands.FindIndex(x => x.Id == g.Id);
        if (idx >= 0) Data.GitCommands[idx] = g; else Data.GitCommands.Add(g);
        Persist();
    }

    /// <summary>Удаление = tombstone (канон синка), иначе вернётся с другого устройства.</summary>
    public void DeleteGitCommand(Guid id)
    {
        var g = Data.GitCommands?.FirstOrDefault(x => x.Id == id);
        if (g is null) return;
        g.Deleted = true;
        g.UpdatedAt = QtJson.NowIso();
        Persist();
    }

    public void Persist(bool sync = true)
    {
        _store.Save(Data);
        Changed?.Invoke();
        if (sync) SyncChanged?.Invoke();
    }

    /// <summary>Замена вейлта целиком (merge синка). sync=false — не эхо-пушить.</summary>
    public void ReplaceData(SessionVault v, bool sync)
    {
        Data = v;
        // после синка: мусор, пришедший с других устройств, — в tombstone
        if (SanitizeJournals() > 0) sync = true;
        Persist(sync);
    }

    // ── Журнал команд (канон: recordCommand БЕЗ пуша — уедет со следующим) ──

    public IEnumerable<KeyValuePair<string, CmdStat>> VisibleCmdHistory =>
        (Data.CmdHistory ?? new()).Where(kv => kv.Value.Deleted != true);

    public void RecordCommand(string cmd)
    {
        if (!LooksLikeCommand(cmd) || LooksSensitive(cmd)) return;
        Data.CmdHistory ??= new();
        var now = QtJson.NowIso();
        if (Data.CmdHistory.TryGetValue(cmd, out var st) && st.Deleted != true)
            Data.CmdHistory[cmd] = new CmdStat { Count = st.Count + 1, LastUsed = now };
        else
            Data.CmdHistory[cmd] = new CmdStat { Count = 1, LastUsed = now }; // воскрешение с нуля
        if (Data.CmdHistory.Count > 500)
            Data.CmdHistory = Data.CmdHistory
                .OrderByDescending(kv => kv.Value.LastUsed ?? "", StringComparer.Ordinal)
                .Take(500).ToDictionary(kv => kv.Key, kv => kv.Value);
        Persist(sync: false);
    }

    public void DeleteCommand(string cmd)
    {
        Data.CmdHistory ??= new();
        Data.CmdHistory[cmd] = new CmdStat { Count = 0, LastUsed = QtJson.NowIso(), Deleted = true };
        Persist(); // tombstone пушится (канон)
    }

    // ── Пользовательский словарь (мак-канон cmdDictUser, скоуп server/both на винде) ──

    private static bool ScopeHere(DictEntry e) => e.Scope is "server" or "both";

    /// <summary>Действующий словарь: встроенный минус скрытые + свои.</summary>
    public IEnumerable<(string Cmd, bool Own)> EffectiveDict()
    {
        var user = Data.CmdDictUser ?? new();
        var hidden = user.Where(kv => kv.Value.Deleted == true && ScopeHere(kv.Value))
                         .Select(kv => kv.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var c in CommandDict.Common)
            if (!hidden.Contains(c)) yield return (c, false);
        foreach (var (cmd, e) in user)
            if (e.Deleted != true && ScopeHere(e) && !CommandDict.Common.Contains(cmd))
                yield return (cmd, true);
    }

    public void AddDictEntry(string cmd)
    {
        cmd = cmd.Trim();
        if (cmd.Length < 2) return;
        Data.CmdDictUser ??= new();
        Data.CmdDictUser[cmd] = new DictEntry { Scope = "server", UpdatedAt = QtJson.NowIso() };
        Persist();
    }

    /// <summary>Скрыть встроенную (tombstone поверх) или убрать свою.</summary>
    public void RemoveDictEntry(string cmd)
    {
        Data.CmdDictUser ??= new();
        Data.CmdDictUser[cmd] = new DictEntry { Scope = "server", UpdatedAt = QtJson.NowIso(), Deleted = true };
        Persist();
    }

    public void ClearCmdHistory()
    {
        if (Data.CmdHistory is null) return;
        var now = QtJson.NowIso();
        foreach (var k in Data.CmdHistory.Where(kv => kv.Value.Deleted != true).Select(kv => kv.Key).ToList())
            Data.CmdHistory[k] = new CmdStat { Count = 0, LastUsed = now, Deleted = true };
        Persist();
    }

    /// <summary>Фильтр журнала (канон): длина 2..200, без управляющих, первый
    /// токен ^[A-Za-z0-9_./~-]+$, не с «-», не только цифры, стоп-слова.</summary>
    // ── Гигиена журнала (мак-канон волны 17) ──

    private static readonly System.Text.RegularExpressions.Regex[] SensitiveRx =
    {
        new(@"(pass(wd|word)?|passphrase|token|secret|api[_-]?key|auth)\s*[=:]\s*\S", RxO),
        new(@"\bbearer\s+\S", RxO),
        new(@"authorization\s*:", RxO),
        new(@"\bmysql\b.*\s-p\S", RxO),
        new(@"\bsshpass\b", RxO),
        new(@"\|\s*chpasswd\b", RxO),
        new(@"--pass(word)?(=|\s+)\S", RxO),
        new(@"\bexport\s+\w*(token|secret|pass|key)\w*\s*=", RxO),
        new(@"[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@", RxO),                // user:pass@host
        new(@"\b(vless|vmess|trojan|ss|hy2|hysteria2?|tuic)://", RxO),        // ссылки прокси
        new(@"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.", System.Text.RegularExpressions.RegexOptions.Compiled), // JWT
        new(@"\b[0-9a-fA-F]{32,}\b", System.Text.RegularExpressions.RegexOptions.Compiled),                          // hex-секреты
    };
    private const System.Text.RegularExpressions.RegexOptions RxO =
        System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.Compiled;

    /// <summary>Похоже на секрет: пароли/токены/ключи/ссылки с кредами.</summary>
    public static bool LooksSensitive(string s)
    {
        if (s.Length > 250) return true;
        if (SensitiveRx.Any(r => r.IsMatch(s))) return true;
        // длинные смешанные токены: сегмент ≥16 с верхним+нижним регистром+цифрой
        foreach (var seg in s.Split(new[] { ' ', '\t', '=', ':', '/', '"', '\'' }, StringSplitOptions.RemoveEmptyEntries))
            if (seg.Length >= 16 && seg.Any(char.IsUpper) && seg.Any(char.IsLower) && seg.Any(char.IsDigit))
                return true;
        return false;
    }

    /// <summary>Мусор журнала (все скоупы) → tombstone (lastUsed=now, разъедется
    /// по устройствам); tombstone'ы старше 30 дней удаляются. Возврат — сколько правок.</summary>
    public int SanitizeJournals()
    {
        var now = QtJson.NowIso();
        var cutoff = DateTime.UtcNow.AddDays(-30).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
        int changed = 0;
        void Clean(Dictionary<string, CmdStat>? h)
        {
            if (h is null) return;
            foreach (var (cmd, st) in h.ToList())
            {
                if (st.Deleted == true)
                {
                    if (string.CompareOrdinal(st.LastUsed ?? "", cutoff) < 0) { h.Remove(cmd); changed++; }
                }
                else if (!LooksLikeCommand(cmd) || LooksSensitive(cmd))
                {
                    h[cmd] = new CmdStat { Count = 0, LastUsed = now, Deleted = true };
                    changed++;
                }
            }
        }
        Clean(Data.CmdHistory);
        if (Data.CmdHistoryScopes is { } sc) foreach (var h in sc.Values) Clean(h);
        return changed;
    }

    public static bool LooksLikeCommand(string s)
    {
        s = s.Trim();
        if (s.Length is < 2 or > 250) return false;
        if (s.Any(char.IsControl)) return false;
        var first = s.Split(' ', '\t')[0];
        if (first.StartsWith('-')) return false;
        if (first.All(char.IsDigit)) return false;
        if (!first.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '.' or '/' or '~' or '-')) return false;
        var stop = new[] { "y", "n", "yes", "no", "q", "да", "нет" };
        return !stop.Contains(s.ToLowerInvariant());
    }
}
