using System.ComponentModel;
using System.IO;
using System.Text;
using System.Windows.Media;

namespace QTermWin.Xui;

public enum LogKind { Info, Ok, Warn, Err, Head, Dim }

/// <summary>Склейка группы клиентов главной в одного.</summary>
public sealed class MergePlan
{
    public string Key = "";
    public string Display = "";
    public XClient Primary = null!;
    public List<XClient> Secondary = new();
    public List<int> Attach = new();
    public Dictionary<string, string> Creds = new();
}

/// <summary>Клиент ноды, который главная не забрала (имя занято): запись ноды убираем,
/// к входящим ноды привязываем клиента главной (ключ Hysteria сохраняем).</summary>
public sealed class ReplaceEntry
{
    public HashSet<string> Tags = new();
    public string Auth = "";
    public string Password = "";
    public List<string> Emails = new();
}

/// <summary>План подключения/ревизии ноды.</summary>
public sealed class NodePlan
{
    public XuiApi Node = null!;
    public string NodeToken = "";
    public string Name = "";
    public XNode? Existing;
    public List<MergePlan> MasterMerge = new();
    public Dictionary<string, ReplaceEntry> Replace = new();
    public Dictionary<string, List<string>> Keep = new();
    public List<string> Others = new();          // ключи клиентов главной, которых на ноде нет
    public bool AttachOthers;
    public int NodeInboundCount;
    public HashSet<string> Toks = new();
    public Dictionary<string, string> KeyDisplay = new();

    /// <summary>Отмеченные в плане ключи склейки на главной / склейки забранных с ноды.</summary>
    public HashSet<string> ApprovedMerge = new(StringComparer.Ordinal);
    public HashSet<string> ApprovedKeep = new(StringComparer.Ordinal);
    /// <summary>Имена, поправленные в плане вручную: ключ → имя.</summary>
    public Dictionary<string, string> NameOverrides = new(StringComparer.Ordinal);

    public bool HasChanges => MasterMerge.Count > 0 || Replace.Count > 0 || Keep.Count > 0 ||
                              (AttachOthers && Others.Count > 0) || Existing is null;
}

/// <summary>Строка плана с галкой: что будет сделано и можно ли это снять.</summary>
public sealed class PlanItem : INotifyPropertyChanged
{
    public string Scope { get; init; } = "";      // главная | имя ноды
    public string Kind { get; init; } = "";       // merge | replace | keep | attach | info
    public string Key { get; init; } = "";
    private string _result = "";
    /// <summary>Итоговое имя; для склеек — можно поправить прямо в плане.</summary>
    public string Result
    {
        get => _result;
        set { if (_result != value) { _result = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Result))); } }
    }
    public bool Editable { get; init; }
    public bool ReadOnly => !Editable;
    /// <summary>Клиент уже сдвоенный (VLESS + Hysteria) — подсветка зелёным.</summary>
    public bool Merged { get; init; }
    /// <summary>Переезд: клиент ищется по ключу имени уже после склейки/переименования.</summary>
    public string ClientKey { get; init; } = "";
    public string From { get; init; } = "";
    public string Note { get; init; } = "";
    public bool Selectable { get; init; } = true;
    public object? Owner { get; init; }           // NodePlan (или null — главная)
    public string Email { get; init; } = "";      // синхронизация: чей клиент
    public List<int> Ids { get; init; } = new();  // синхронизация: какие входящие добавить

    private bool _apply;
    public bool Apply
    {
        get => _apply;
        set { if (_apply != value) { _apply = value; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Apply))); } }
    }

    public string KindText => Kind switch
    {
        "merge" => "склеить на главной",
        "replace" => "дубль на ноде → клиент главной",
        "keep" => "новый с ноды",
        "attach" => "добавить на сервер",
        _ => "",
    };

    public Brush KindBrush => Kind switch
    {
        "merge" => Brushes.CornflowerBlue,
        "replace" => Brushes.Goldenrod,
        "keep" => Brushes.MediumSeaGreen,
        "attach" => Brushes.MediumPurple,
        _ => Brushes.Gray,
    };

    public string AsText => $"[{(Apply ? "x" : " ")}] {Scope,-8} {KindText,-30} {Result,-22} ← {From}{(Note.Length > 0 ? "   · " + Note : "")}";

    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>Операции над главной и нодами (порт qnodes.py). Всё async на UI-потоке, лог — колбэком.</summary>
public sealed class XuiOps
{
    private readonly NameUnifier _names;
    private readonly Action<string, LogKind> _log;

    public static string BackupDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm", "xui-backup");

    public XuiOps(NameUnifier names, Action<string, LogKind> log)
    {
        _names = names;
        _log = log;
    }

    private void Ok(string s) => _log("  ✓ " + s, LogKind.Ok);
    private void Warn(string s) => _log("  ! " + s, LogKind.Warn);
    private void Err(string s) => _log("  ✗ " + s, LogKind.Err);
    private void Head(string s) => _log("━━ " + s, LogKind.Head);
    private void Dim(string s) => _log("  " + s, LogKind.Dim);

    // ── служебные хвосты: HYS + имена нод + слова из примечаний входящих ──

    public static HashSet<string> StripTokens(IEnumerable<XInbound> ibs, IEnumerable<XNode> nodes, IEnumerable<string>? extra = null)
    {
        var t = new HashSet<string>(NameUnifier.SuffixTokens, StringComparer.Ordinal);
        foreach (var n in nodes) t.UnionWith(NameUnifier.TokensOf(n.Name));
        foreach (var ib in ibs) t.UnionWith(NameUnifier.TokensOf(ib.Remark));
        if (extra is not null) foreach (var e in extra) t.UnionWith(NameUnifier.TokensOf(e));
        t.RemoveWhere(x => x.Length < 2);
        return t;
    }

    /// <summary>Есть ли среди входящих VLESS-подобные и Hysteria.</summary>
    public static (bool V, bool H) Protos(IEnumerable<int> ids, Dictionary<int, XInbound> ibById)
    {
        bool v = false, h = false;
        foreach (var i in ids)
            if (ibById.TryGetValue(i, out var ib) && ib.MultiUser) { if (ib.IsHys) h = true; else v = true; }
        return (v, h);
    }

    /// <summary>После привязки/отвязки: имена клиентов из списка (и с индексом) приводим к протоколам —
    /// PC (VLESS) / PC-HYS (Hysteria) / PC-SYNC (оба). Ключи и подписка не меняются.</summary>
    public async Task<int> NormalizeIndexAsync(XuiApi m, IEnumerable<string> emails)
    {
        var want = emails.ToHashSet(StringComparer.Ordinal);
        var clients = await m.ClientsAsync();
        var ibById = (await m.InboundsAsync()).ToDictionary(i => i.Id);
        var toks = StripTokens(ibById.Values, await m.NodesAsync());
        int n = 0;
        foreach (var c in clients.Where(c => want.Contains(c.Email)))
        {
            var key = _names.Analyze(c.Email, toks).Key;
            var hasIndex = NameUnifier.BaseText(c.Email) != c.Email.Trim();
            if (!_names.IsCanonical(key) && !hasIndex) continue;
            var (v, h) = Protos(c.InboundIds, ibById);
            var name = _names.DisplayFor(key, new[] { c.Email }, c.Email, v, h);
            if (name == c.Email || clients.Any(x => x.Email == name)) continue;
            try
            {
                await m.UpdateClientAsync(c.Email, XuiApi.ClientPayload(c, name));
                Ok($"{c.Email} → {name}");
                n++;
            }
            catch (XuiException e) { Err($"{c.Email}: {e.Message}"); }
        }
        return n;
    }

    private static bool HysOnly(XClient c, Dictionary<int, XInbound> ibById) =>
        c.InboundIds.Count > 0 && c.InboundIds.All(i => ibById.TryGetValue(i, out var ib) && ib.IsHys);

    // ── план склейки на главной ──

    public List<MergePlan> PlanMerge(List<XClient> clients, List<XInbound> inbounds, List<XNode> nodes)
    {
        var ibById = inbounds.ToDictionary(i => i.Id);
        var toks = StripTokens(inbounds, nodes);
        var keyOf = new Dictionary<XClient, (string Key, bool Hys)>();
        var groups = new Dictionary<string, List<XClient>>(StringComparer.Ordinal);
        foreach (var c in clients)
        {
            var a = _names.Analyze(c.Email, toks);
            keyOf[c] = a;
            if (!groups.TryGetValue(a.Key, out var g)) groups[a.Key] = g = new();
            g.Add(c);
        }

        var plan = new List<MergePlan>();
        foreach (var (key, grp) in groups.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            // основной — с UUID (VLESS): его ID подписки уже стоит на устройствах
            var prim = grp.OrderBy(r => !string.IsNullOrEmpty(r.Uuid) && !keyOf[r].Hys ? 0 : 1)
                          .ThenBy(r => HysOnly(r, ibById) ? 1 : 0)
                          .ThenBy(r => !string.IsNullOrEmpty(r.Uuid) ? 0 : 1)
                          .ThenBy(r => r.Id).First();
            var union = grp.SelectMany(r => r.InboundIds).Distinct().ToList();
            var (v, h) = Protos(union, ibById);
            var display = _names.DisplayFor(key, grp.Select(r => r.Email), prim.Email, v, h);
            var sec = grp.Where(r => !ReferenceEquals(r, prim)).ToList();
            var rename = prim.Email != display;
            if (rename && clients.Any(c => c.Email == display && keyOf[c].Key != key)) rename = false; // имя занято чужим
            // одиночки не из списка не трогаем; из списка — приводим индекс к протоколам
            if (sec.Count == 0 && (!rename || !_names.IsCanonical(key))) continue;

            var attach = union.Where(i => !prim.InboundIds.Contains(i)).ToList();
            var creds = new Dictionary<string, string>();
            foreach (var s in sec)
            {
                if (s.Auth.Length > 0 && prim.Auth.Length == 0) creds.TryAdd("auth", s.Auth);
                if (s.Password.Length > 0 && prim.Password.Length == 0) creds.TryAdd("password", s.Password);
                if (s.Uuid.Length > 0 && prim.Uuid.Length == 0) creds.TryAdd("id", s.Uuid);
            }
            plan.Add(new MergePlan
            {
                Key = key, Display = rename ? display : prim.Email, Primary = prim,
                Secondary = sec, Attach = attach, Creds = creds,
            });
        }
        return plan;
    }

    public static string Label(XInbound ib, Dictionary<int, XNode> nodes) =>
        $"{(ib.Remark.Length > 0 ? ib.Remark : ib.Tag)}@{(ib.NodeId is int n ? (nodes.TryGetValue(n, out var x) ? x.Name : "узел " + n) : "главная")}";

    public void LogPlan(List<MergePlan> plan, List<XInbound> inbounds, List<XNode> nodes)
    {
        var ibById = inbounds.ToDictionary(i => i.Id);
        var nb = nodes.ToDictionary(n => n.Id);
        if (plan.Count == 0) { Ok("дублей нет, имена уже единые"); return; }
        foreach (var p in plan)
        {
            _log($"  {p.Display}  ←  {string.Join(", ", new[] { p.Primary.Email }.Concat(p.Secondary.Select(s => s.Email)))}", LogKind.Info);
            if (p.Attach.Count > 0)
                Dim("    + входящие: " + string.Join(", ", p.Attach.Where(ibById.ContainsKey).Select(i => Label(ibById[i], nb))));
            if (p.Creds.ContainsKey("auth")) Dim("    ключ Hysteria сохраняется");
        }
    }

    public async Task<int> ApplyMergeAsync(XuiApi m, List<MergePlan> plan)
    {
        int errors = 0;
        foreach (var p in plan)
        {
            try
            {
                foreach (var s in p.Secondary) await m.DeleteClientAsync(s.Email);
                if (p.Display != p.Primary.Email || p.Creds.Count > 0)
                    await m.UpdateClientAsync(p.Primary.Email, XuiApi.ClientPayload(p.Primary, p.Display, p.Creds));
                if (p.Attach.Count > 0) await m.AttachAsync(p.Display, p.Attach);
                Ok(p.Display);
            }
            catch (XuiException e) { errors++; Err($"{p.Display}: {e.Message}"); }
        }
        return errors;
    }

    // ── бэкапы ──

    public async Task<string> BackupAsync(XuiApi api, string name)
    {
        Directory.CreateDirectory(BackupDir);
        var safe = string.Concat(name.Select(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_' or '.' ? ch : '_'));
        var path = Path.Combine(BackupDir, $"{safe}-{DateTime.Now:yyyyMMdd-HHmmss}.db");
        await File.WriteAllBytesAsync(path, await api.GetDbAsync());
        return path;
    }

    // ── нода: план ──

    public async Task<NodePlan> PlanNodeAsync(XuiApi master, XuiApi node, string nodeToken, string? newName, bool attachOthers)
    {
        await node.StatusAsync();
        var nodes = await master.NodesAsync();
        var existing = nodes.FirstOrDefault(n => node.Url.SameAs(n.Address, n.Port, n.BasePath));
        var name = existing?.Name ?? (string.IsNullOrWhiteSpace(newName) ? node.Url.Host.Split('.')[0].ToUpperInvariant() : newName.Trim());
        if (existing is null && nodes.Any(n => n.Name == name))
            throw new XuiException($"узел с именем «{name}» уже есть на главной");

        var mc = await master.ClientsAsync();
        var mi = await master.InboundsAsync();
        var nClients = await node.ClientsAsync();
        var nInbounds = await node.InboundsAsync();
        var nIbById = nInbounds.ToDictionary(i => i.Id);
        var keepV = new HashSet<string>(StringComparer.Ordinal);
        var keepH = new HashSet<string>(StringComparer.Ordinal);

        var plan = new NodePlan
        {
            Node = node, NodeToken = nodeToken, Name = name, Existing = existing, AttachOthers = attachOthers,
            NodeInboundCount = nInbounds.Count,
            Toks = StripTokens(mi.Concat(nInbounds), nodes, new[] { name }),
        };
        plan.MasterMerge = PlanMerge(mc, mi, nodes);

        var masterKeys = new Dictionary<string, XClient>(StringComparer.Ordinal);
        foreach (var c in mc) masterKeys.TryAdd(_names.Analyze(c.Email, plan.Toks).Key, c);
        foreach (var p in plan.MasterMerge) plan.KeyDisplay[p.Key] = p.Display;
        string Disp(string k) => plan.KeyDisplay.TryGetValue(k, out var d) ? d
            : masterKeys.TryGetValue(k, out var c) ? c.Email
            : plan.Keep.TryGetValue(k, out var ke) ? _names.DisplayFor(k, ke, ke[0], keepV.Contains(k), keepH.Contains(k))
            : k;

        var nodeIbIds = existing is null ? new HashSet<int>()
            : mi.Where(i => i.NodeId == existing.Id).Select(i => i.Id).ToHashSet();
        var adopted = mc.Where(c => c.InboundIds.Any(nodeIbIds.Contains)).Select(c => c.Email).ToHashSet(StringComparer.Ordinal);

        foreach (var c in nClients)
        {
            if (adopted.Contains(c.Email)) continue;
            var k = _names.Analyze(c.Email, plan.Toks, masterKeys.Keys).Key;
            var tags = c.InboundIds.Where(nIbById.ContainsKey).Select(i => nIbById[i].Tag);
            if (masterKeys.ContainsKey(k))
            {
                if (!plan.Replace.TryGetValue(k, out var r)) plan.Replace[k] = r = new ReplaceEntry();
                r.Tags.UnionWith(tags);
                r.Emails.Add(c.Email);
                if (r.Auth.Length == 0) r.Auth = c.Auth;
                if (r.Password.Length == 0) r.Password = c.Password;
            }
            else
            {
                if (!plan.Keep.TryGetValue(k, out var l)) plan.Keep[k] = l = new();
                l.Add(c.Email);
                foreach (var i in c.InboundIds.Where(nIbById.ContainsKey).Select(i => nIbById[i]).Where(i => i.MultiUser))
                    (i.IsHys ? keepH : keepV).Add(k);
            }
        }

        var keysOnNode = new HashSet<string>(plan.Replace.Keys, StringComparer.Ordinal);
        foreach (var e in adopted) keysOnNode.Add(_names.Analyze(e, plan.Toks).Key);
        plan.Others = masterKeys.Keys.Where(k => !keysOnNode.Contains(k)).OrderBy(k => k, StringComparer.Ordinal).ToList();
        foreach (var k in plan.Replace.Keys.Concat(plan.Keep.Keys).Concat(plan.Others))
            plan.KeyDisplay.TryAdd(k, Disp(k));
        return plan;
    }

    public string Describe(NodePlan p, List<XInbound> mi, List<XNode> nodes)
    {
        var sb = new StringBuilder();
        sb.AppendLine(p.Existing is null
            ? $"Нода «{p.Name}» ({p.Node.Url.Host}:{p.Node.Url.Port}) — НОВАЯ, будет добавлена на главную"
            : $"Нода «{p.Name}» уже на главной — доводим до единых имён");
        if (p.MasterMerge.Count > 0)
        {
            sb.AppendLine("\nЕдиные имена на главной:");
            foreach (var m in p.MasterMerge)
                sb.AppendLine($"  {m.Display} ← {string.Join(", ", new[] { m.Primary.Email }.Concat(m.Secondary.Select(s => s.Email)))}");
        }
        if (p.Replace.Count > 0 || p.Keep.Count > 0)
        {
            sb.AppendLine("\nКлиенты ноды:");
            foreach (var (k, r) in p.Replace.OrderBy(x => x.Key))
                sb.AppendLine($"  {p.KeyDisplay[k]} ← на ноде: {string.Join(", ", r.Emails)}  (запись ноды убрать, привязать клиента главной)");
            foreach (var (k, l) in p.Keep.OrderBy(x => x.Key))
                sb.AppendLine($"  {p.KeyDisplay[k]} ← на ноде: {string.Join(", ", l)}  (новый, заберётся и получит единое имя)");
        }
        if (p.AttachOthers && p.Others.Count > 0)
            sb.AppendLine("\nПривязать к ноде остальных: " + string.Join(", ", p.Others.Select(k => p.KeyDisplay[k])));
        if (!p.HasChanges) sb.AppendLine("\nМенять нечего — всё в порядке.");
        return sb.ToString().TrimEnd();
    }

    // ── план с галками ──

    public List<PlanItem> MergeItems(List<MergePlan> plan, string scope, List<XInbound> inbounds, List<XNode> nodes, object? owner = null)
    {
        var ibById = inbounds.ToDictionary(i => i.Id);
        var nb = nodes.ToDictionary(n => n.Id);
        return plan.Select(p => new PlanItem
        {
            Scope = scope, Kind = "merge", Key = p.Key, Owner = owner, Editable = true,
            Result = p.Display,
            From = string.Join(", ", new[] { p.Primary.Email }.Concat(p.Secondary.Select(s => s.Email))),
            Note = string.Join("; ", new[]
            {
                p.Display != p.Primary.Email ? $"переименовать {p.Primary.Email} → {p.Display}" : "",
                p.Secondary.Count > 0 ? $"убрать записи: {string.Join(", ", p.Secondary.Select(s => s.Email))}" : "",
                p.Attach.Count > 0 ? "+ " + string.Join(", ", p.Attach.Where(ibById.ContainsKey).Select(i => Label(ibById[i], nb))) : "",
                p.Creds.ContainsKey("auth") ? "ключ Hysteria сохранится" : "",
            }.Where(x => x.Length > 0)),
            Apply = _names.IsCanonical(p.Key),
        }).ToList();
    }

    public List<PlanItem> NodeItems(NodePlan p)
    {
        var items = new List<PlanItem>();
        foreach (var (k, r) in p.Replace.OrderBy(x => x.Key, StringComparer.Ordinal))
            items.Add(new PlanItem
            {
                Scope = p.Name, Kind = "replace", Key = k, Owner = p,
                Result = p.KeyDisplay[k], From = string.Join(", ", r.Emails),
                Note = "запись ноды убрать, к её входящим привязать клиента главной (VLESS-ключ станет как на главной). Не отмечено — главная эту запись не увидит",
                Apply = _names.IsCanonical(k),
            });
        foreach (var (k, l) in p.Keep.OrderBy(x => x.Key, StringComparer.Ordinal))
        {
            var disp = p.KeyDisplay[k];
            var needMerge = l.Count > 1 || (l[0] != disp && _names.IsCanonical(k));
            if (!needMerge) disp = l[0];
            items.Add(new PlanItem
            {
                Scope = p.Name, Kind = "keep", Key = k, Owner = p, Editable = needMerge,
                Result = disp, From = string.Join(", ", l),
                Note = needMerge ? "главная заберёт; отмечено — склеить в одно имя" : "главная заберёт как есть",
                Selectable = needMerge,
                Apply = needMerge && _names.IsCanonical(k),
            });
        }
        foreach (var k in p.Others)
            items.Add(new PlanItem
            {
                Scope = p.Name, Kind = "attach", Key = k, Owner = p,
                Result = p.KeyDisplay[k], From = "только на других серверах",
                Note = "привязать ко всем входящим ноды",
                Apply = p.AttachOthers,
            });
        return items;
    }

    /// <summary>Галки → план ноды: снятые дубли не трогаем, снятые склейки не делаем.</summary>
    public static void ApplySelection(NodePlan p, IEnumerable<PlanItem> items)
    {
        var mine = items.Where(i => ReferenceEquals(i.Owner, p) || (i.Owner is null && i.Kind == "merge")).ToList();
        p.ApprovedMerge = mine.Where(i => i.Kind == "merge" && i.Apply).Select(i => i.Key).ToHashSet(StringComparer.Ordinal);
        p.ApprovedKeep = mine.Where(i => i.Kind == "keep" && i.Apply).Select(i => i.Key).ToHashSet(StringComparer.Ordinal);
        var rep = mine.Where(i => i.Kind == "replace" && i.Apply).Select(i => i.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var k in p.Replace.Keys.ToList()) if (!rep.Contains(k)) p.Replace.Remove(k);
        p.Others = mine.Where(i => i.Kind == "attach" && i.Apply).Select(i => i.Key).ToList();
        p.AttachOthers = p.Others.Count > 0;
        p.NameOverrides = Overrides(mine);
    }

    /// <summary>Ручные правки имён в плане (только отмеченные склейки).</summary>
    public static Dictionary<string, string> Overrides(IEnumerable<PlanItem> items) =>
        items.Where(i => i.Editable && i.Apply && i.Result.Trim().Length > 0)
             .GroupBy(i => i.Key).ToDictionary(g => g.Key, g => g.First().Result.Trim(), StringComparer.Ordinal);

    public static void ApplyOverrides(List<MergePlan> plan, Dictionary<string, string> ov)
    {
        foreach (var m in plan)
            if (ov.TryGetValue(m.Key, out var name)) m.Display = name;
    }

    // ── нода: применение ──

    private async Task WaitAdoptionAsync(XuiApi m, int nodeId, int nodeIbCount, int timeoutSec = 150)
    {
        Dim($"жду, пока главная заберёт входящие и клиентов ноды (до {timeoutSec} с)…");
        var t0 = DateTime.UtcNow;
        (int, int)? last = null;
        int stable = 0;
        while ((DateTime.UtcNow - t0).TotalSeconds < timeoutSec)
        {
            try
            {
                var ibs = (await m.InboundsAsync()).Where(i => i.NodeId == nodeId).ToList();
                var ids = ibs.Select(i => i.Id).ToHashSet();
                var att = (await m.ClientsAsync()).Sum(c => c.InboundIds.Count(ids.Contains));
                var sig = (ibs.Count, att);
                if (ibs.Count >= nodeIbCount && last == sig)
                {
                    if (++stable >= 2) { Ok($"импортировано входящих: {ibs.Count}, привязок клиентов: {att}"); return; }
                }
                else stable = 0;
                last = sig;
            }
            catch (XuiException) { }
            await Task.Delay(5000);
        }
        Warn("импорт не завершился за отведённое время — продолжаю с тем, что есть");
    }

    private async Task<HashSet<string>> NodeEmailsOnMasterAsync(XuiApi m, int nodeId) =>
        (await m.InboundsAsync()).Where(i => i.NodeId == nodeId).SelectMany(i => i.ClientEmails)
                                 .ToHashSet(StringComparer.Ordinal);

    /// <summary>После удаления записей прямо на ноде ждём, пока главная перечитает ноду —
    /// иначе при следующей отправке конфигурации она вернёт их обратно.</summary>
    private async Task WaitMasterForgetsAsync(XuiApi m, int nodeId, IEnumerable<string> emails, int timeoutSec = 90)
    {
        var set = emails.ToHashSet(StringComparer.Ordinal);
        if (set.Count == 0) return;
        Dim("жду, пока главная перечитает ноду…");
        var t0 = DateTime.UtcNow;
        while ((DateTime.UtcNow - t0).TotalSeconds < timeoutSec)
        {
            try
            {
                if (!(await NodeEmailsOnMasterAsync(m, nodeId)).Overlaps(set)) { Ok("главная видит ноду без дублей"); return; }
            }
            catch (XuiException) { }
            await Task.Delay(5000);
        }
        Warn("главная всё ещё видит старые записи — продолжаю; при ошибках просто запусти ещё раз");
    }

    /// <returns>id узла на главной</returns>
    public async Task<int> ApplyNodeAsync(XuiApi master, NodePlan p)
    {
        Head($"Нода «{p.Name}»");
        Ok("бэкап главной → " + await BackupAsync(master, "master"));
        Ok("бэкап ноды → " + await BackupAsync(p.Node, p.Name));
        int errors = 0;

        // 1) дубли на самой ноде
        var removed = new List<string>();
        foreach (var r in p.Replace.Values)
            foreach (var e in r.Emails)
            {
                try { await p.Node.DeleteClientAsync(e); removed.Add(e); }
                catch (XuiException ex) { Err($"нода: не удалось удалить {e}: {ex.Message}"); errors++; }
            }
        if (removed.Count > 0) Ok($"убрал дубли на ноде: {removed.Count}");
        if (p.Existing is not null && removed.Count > 0) await WaitMasterForgetsAsync(master, p.Existing.Id, removed);

        // 2) единые имена на главной (план пересчитываем — мог поменяться)
        var nodes = await master.NodesAsync();
        var merge = PlanMerge(await master.ClientsAsync(), await master.InboundsAsync(), nodes)
            .Where(m => p.ApprovedMerge.Contains(m.Key)).ToList();
        ApplyOverrides(merge, p.NameOverrides);
        if (merge.Count > 0) errors += await ApplyMergeAsync(master, merge);

        // 3) регистрация узла
        int nodeId;
        if (p.Existing is not null) nodeId = p.Existing.Id;
        else
        {
            var tname = $"qterm-master-{DateTime.Now:yyyyMMddHHmmss}";
            string? syncToken = null;
            try { syncToken = await p.Node.CreateTokenAsync(tname, "node-sync"); }
            catch (XuiException e) { Warn($"ограниченный токен node-sync не создался ({e.Message}) — регистрирую с введённым"); }
            var body = new
            {
                name = p.Name, remark = "", scheme = p.Node.Url.Scheme, address = p.Node.Url.Host,
                port = p.Node.Url.Port, basePath = p.Node.Url.BasePathOrSlash,
                apiToken = syncToken ?? p.NodeToken, enable = true,
                allowPrivateAddress = IsPrivateHost(p.Node.Url.Host),
                tlsVerifyMode = p.Node.VerifyTls ? "verify" : "skip", pinnedCertSha256 = "",
                inboundSyncMode = "all", inboundTags = Array.Empty<string>(), outboundTag = "",
            };
            var view = await master.AddNodeAsync(body);
            nodeId = view?["id"]?.GetValue<int>() ?? 0;
            if (nodeId == 0) nodeId = (await master.NodesAsync()).FirstOrDefault(n => n.Name == p.Name)?.Id ?? 0;
            if (nodeId == 0) throw new XuiException("узел добавлен, но не нашёл его id");
            Ok($"узел «{p.Name}» добавлен (id {nodeId}){(syncToken is not null ? ", на ноде выпущен токен " + tname : "")}");
            await WaitAdoptionAsync(master, nodeId, p.NodeInboundCount);
        }

        // 4) склейка приехавших с ноды
        nodes = await master.NodesAsync();
        var merge2 = PlanMerge(await master.ClientsAsync(), await master.InboundsAsync(), nodes)
            .Where(m => p.ApprovedMerge.Contains(m.Key) || p.ApprovedKeep.Contains(m.Key)).ToList();
        ApplyOverrides(merge2, p.NameOverrides);
        if (merge2.Count > 0)
        {
            Dim("склеиваю приехавших с ноды:");
            errors += await ApplyMergeAsync(master, merge2);
        }

        // 5) привязка клиентов главной к входящим ноды
        var mc = await master.ClientsAsync();
        var mi = await master.InboundsAsync();
        var nodeIbs = mi.Where(i => i.NodeId == nodeId).ToList();
        var prefix = $"n{nodeId}-";
        int? IbIdByTag(string tag) => nodeIbs.FirstOrDefault(i => i.Tag == tag || i.Tag == prefix + tag)?.Id;
        var multi = nodeIbs.Where(i => i.MultiUser).Select(i => i.Id).ToList();
        var byKey = new Dictionary<string, XClient>(StringComparer.Ordinal);
        foreach (var c in mc) byKey.TryAdd(_names.Analyze(c.Email, p.Toks).Key, c);

        var todo = new SortedDictionary<string, (XClient C, List<int> Ids, ReplaceEntry? R)>(StringComparer.Ordinal);
        foreach (var (k, r) in p.Replace)
        {
            if (!byKey.TryGetValue(k, out var c)) { Err($"не нашёл на главной клиента для {k}"); errors++; continue; }
            todo[c.Email] = (c, r.Tags.Select(IbIdByTag).Where(i => i is not null).Select(i => i!.Value).ToList(), r);
        }
        if (p.AttachOthers)
            foreach (var k in p.Others)
                if (byKey.TryGetValue(k, out var c) && !todo.ContainsKey(c.Email))
                    todo[c.Email] = (c, multi.ToList(), null);

        foreach (var (email, (c, ids, r)) in todo)
        {
            var need = ids.Where(i => !c.InboundIds.Contains(i)).Distinct().ToList();
            if (need.Count == 0) continue;
            var over = new Dictionary<string, string>();
            if (r is not null && r.Auth.Length > 0 && c.Auth.Length == 0) over["auth"] = r.Auth; // ключ Hysteria с ноды
            if (r is not null && r.Password.Length > 0 && c.Password.Length == 0) over["password"] = r.Password;
            for (int attempt = 1; attempt <= 2; attempt++)
            {
                try
                {
                    if (over.Count > 0)
                    {
                        await master.UpdateClientAsync(email, XuiApi.ClientPayload(c, null, over));
                        over.Clear();
                    }
                    await master.AttachAsync(email, need);
                    Ok($"{email} → {string.Join(", ", need.Select(i => nodeIbs.First(x => x.Id == i).Remark))}");
                    break;
                }
                catch (XuiException e) when (attempt == 1 && e.Message.Contains("already in use"))
                {
                    Warn($"{email}: нода ещё держит старую запись — убираю и повторяю");
                    try { await p.Node.DeleteClientAsync(email); } catch (XuiException) { }
                    await WaitMasterForgetsAsync(master, nodeId, new[] { email }, 60);
                }
                catch (XuiException e) { errors++; Err($"{email}: {e.Message}"); break; }
            }
        }

        // индекс протокола в имени (PC / PC-HYS / PC-SYNC) — после привязок мог измениться
        if (todo.Count > 0) await NormalizeIndexAsync(master, todo.Keys);

        if (errors > 0) Warn($"ошибок: {errors}; бэкапы в {BackupDir}; повторный запуск безопасен");
        else Ok($"нода «{p.Name}» готова");
        return nodeId;
    }

    private static bool IsPrivateHost(string host)
    {
        try
        {
            foreach (var ip in System.Net.Dns.GetHostAddresses(host))
            {
                var b = ip.GetAddressBytes();
                if (System.Net.IPAddress.IsLoopback(ip) || ip.IsIPv6LinkLocal || ip.IsIPv6SiteLocal) return true;
                if (b.Length == 4 && (b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
                                      (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254))) return true;
                if (b.Length == 16 && (b[0] & 0xFE) == 0xFC) return true; // fc00::/7
            }
        }
        catch { }
        return false;
    }
}
