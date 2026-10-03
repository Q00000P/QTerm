using QTermWin.Models;
using Session = QTermWin.Models.Session;

namespace QTermWin.Sync;

/// <summary>Зеркало SyncMerge мака / applySyncMerge андроида — LWW.</summary>
public static class SyncMerge
{
    /// <summary>true = берём remote. Больший updatedAt (ISO8601 лексикографически)
    /// побеждает; null — древний; ничья — локальный.</summary>
    private static bool Newer(string? local, string? remote) => (local, remote) switch
    {
        (null, null) => false,
        (null, _) => true,
        (_, null) => false,
        var (l, r) => string.CompareOrdinal(r, l) > 0,
    };

    private static List<T> MergeList<T>(List<T> local, List<T> remote,
        Func<T, Guid> id, Func<T, string?> time)
    {
        var byId = new Dictionary<Guid, T>();
        var order = new List<Guid>();
        foreach (var item in local) { byId[id(item)] = item; order.Add(id(item)); }
        foreach (var item in remote)
        {
            var k = id(item);
            if (byId.TryGetValue(k, out var existing))
            {
                if (Newer(time(existing), time(item))) byId[k] = item;
            }
            else { byId[k] = item; order.Add(k); }
        }
        return order.Select(k => byId[k]).ToList();
    }

    private static Dictionary<string, string> MergeSecrets(
        Dictionary<string, string> local, Dictionary<string, string> remote)
    {
        var outp = new Dictionary<string, string>(local);
        foreach (var (k, v) in remote)
        {
            if (k.StartsWith("sync.", StringComparison.Ordinal)) continue;
            if (!outp.TryGetValue(k, out var l)) outp[k] = v;
            // панели/имена 3x-ui: LWW по встроенному updatedAt (правка с другого устройства доезжает)
            else if (Xui.XuiStore.IsLww(k) && Xui.XuiStore.RemoteNewer(l, v)) outp[k] = v;
        }
        return outp;
    }

    public static Dictionary<string, CmdStat> MergeCmdHistory(
        Dictionary<string, CmdStat> local, Dictionary<string, CmdStat> remote)
    {
        var outp = new Dictionary<string, CmdStat>(local);
        foreach (var (cmd, r) in remote)
        {
            if (outp.TryGetValue(cmd, out var l))
            {
                if (l.Deleted == true || r.Deleted == true)
                    outp[cmd] = string.CompareOrdinal(r.LastUsed ?? "", l.LastUsed ?? "") > 0 ? r : l;
                else
                    outp[cmd] = new CmdStat
                    {
                        Count = Math.Max(l.Count, r.Count),
                        LastUsed = string.CompareOrdinal(r.LastUsed ?? "", l.LastUsed ?? "") > 0
                            ? r.LastUsed : l.LastUsed,
                    };
            }
            else outp[cmd] = r;
        }
        if (outp.Count > 500)
            outp = outp.OrderByDescending(kv => kv.Value.LastUsed ?? "", StringComparer.Ordinal)
                       .Take(500).ToDictionary(kv => kv.Key, kv => kv.Value);
        return outp;
    }

    public static Dictionary<string, Dictionary<string, CmdStat>> MergeScopes(
        Dictionary<string, Dictionary<string, CmdStat>> local,
        Dictionary<string, Dictionary<string, CmdStat>> remote)
    {
        var outp = new Dictionary<string, Dictionary<string, CmdStat>>(local);
        foreach (var (scope, r) in remote)
            outp[scope] = MergeCmdHistory(outp.GetValueOrDefault(scope) ?? new(), r);
        return outp;
    }

    public static Dictionary<string, DictEntry> MergeDictUser(
        Dictionary<string, DictEntry> local, Dictionary<string, DictEntry> remote)
    {
        var outp = new Dictionary<string, DictEntry>(local);
        foreach (var (cmd, r) in remote)
        {
            if (!outp.TryGetValue(cmd, out var l) ||
                string.CompareOrdinal(r.UpdatedAt ?? "", l.UpdatedAt ?? "") > 0)
                outp[cmd] = r; // LWW, ничья = локальный
        }
        return outp;
    }

    public static SessionVault Merge(SessionVault local, SessionVault remote)
    {
        return new SessionVault
        {
            SchemaVersion = local.SchemaVersion,
            DeviceID = local.DeviceID,
            UpdatedAt = DateTime.UtcNow,
            Sessions = MergeList(local.Sessions, remote.Sessions, s => s.Id, s => s.UpdatedAt),
            SshKeys = MergeList(local.SshKeys ?? new(), remote.SshKeys ?? new(), k => k.Id, k => k.UpdatedAt),
            Snippets = MergeList(local.Snippets ?? new(), remote.Snippets ?? new(), n => n.Id, n => n.UpdatedAt),
            GitCommands = MergeList(local.GitCommands ?? new(), remote.GitCommands ?? new(), g => g.Id, g => g.UpdatedAt),
            Secrets = MergeSecrets(local.Secrets ?? new(), remote.Secrets ?? new()),
            CmdHistory = MergeCmdHistory(local.CmdHistory ?? new(), remote.CmdHistory ?? new()),
            CmdHistoryScopes = MergeScopes(local.CmdHistoryScopes ?? new(), remote.CmdHistoryScopes ?? new()),
            CmdDictUser = MergeDictUser(local.CmdDictUser ?? new(), remote.CmdDictUser ?? new()),
        };
    }
}
