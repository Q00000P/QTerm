using System.Text;
using System.Text.RegularExpressions;

namespace QTermWin.Xui;

/// <summary>
/// Унификатор имён клиентов: S26 / s26 / S-26 / «S26 HYS» / s26_hys / ЛАП-hys → один ключ (S26, LAP),
/// ключ → каноническое имя из списка (S26-HYS, Lap-HYS). Служебные хвосты (HYS/HY2/…,
/// имена нод и входящих) отрезаются с краёв, кириллица понимается и как похожие латинские
/// буквы (МАМА), и как транслит (ЛАП → LAP). Порт qnodes.py.
/// </summary>
public sealed class NameUnifier
{
    public static readonly HashSet<string> HysTokens = new(StringComparer.Ordinal)
        { "HYS", "HY2", "HYST", "HYSTERIA", "HYSTERIA2" };

    private static readonly Dictionary<char, char> Confusable = new()
    {
        ['А'] = 'A', ['В'] = 'B', ['Е'] = 'E', ['Ё'] = 'E', ['К'] = 'K', ['М'] = 'M', ['Н'] = 'H', ['О'] = 'O',
        ['Р'] = 'P', ['С'] = 'C', ['Т'] = 'T', ['У'] = 'Y', ['Х'] = 'X', ['І'] = 'I',
        ['а'] = 'A', ['в'] = 'B', ['е'] = 'E', ['ё'] = 'E', ['к'] = 'K', ['м'] = 'M', ['н'] = 'H', ['о'] = 'O',
        ['р'] = 'P', ['с'] = 'C', ['т'] = 'T', ['у'] = 'Y', ['х'] = 'X', ['і'] = 'I',
    };

    private static readonly Dictionary<char, string> Translit = new()
    {
        ['А'] = "A", ['Б'] = "B", ['В'] = "V", ['Г'] = "G", ['Д'] = "D", ['Е'] = "E", ['Ё'] = "E", ['Ж'] = "ZH",
        ['З'] = "Z", ['И'] = "I", ['Й'] = "Y", ['К'] = "K", ['Л'] = "L", ['М'] = "M", ['Н'] = "N", ['О'] = "O",
        ['П'] = "P", ['Р'] = "R", ['С'] = "S", ['Т'] = "T", ['У'] = "U", ['Ф'] = "F", ['Х'] = "H", ['Ц'] = "TS",
        ['Ч'] = "CH", ['Ш'] = "SH", ['Щ'] = "SCH", ['Ъ'] = "", ['Ы'] = "Y", ['Ь'] = "", ['Э'] = "E", ['Ю'] = "YU",
        ['Я'] = "YA", ['І'] = "I",
    };

    private static readonly Regex NonWord = new("[^A-Z0-9]+", RegexOptions.Compiled);
    /// <summary>Хвосты-индексы протокола: HYS (Hysteria) и SYNC (сдвоенный VLESS+Hysteria).</summary>
    public static readonly HashSet<string> SuffixTokens = new(HysTokens.Append("SYNC"), StringComparer.Ordinal);

    private static readonly Regex SuffixTail = new(@"^(.*?)[\s_.\-]+(hysteria2?|hyst|hys|hy2|sync)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>Имя без индекса протокола: «PC-HYS» / «PC-SYNC» → «PC».</summary>
    public static string BaseText(string s)
    {
        var t = s.Trim();
        while (true)
        {
            var m = SuffixTail.Match(t);
            if (!m.Success) return t;
            var b = m.Groups[1].Value.Trim(' ', '-', '_', '.');
            if (b.Length == 0) return t;
            t = b;
        }
    }

    /// <summary>Правило имён: без индекса — VLESS, -HYS — Hysteria, -SYNC — сдвоенный.</summary>
    public static string WithIndex(string baseText, bool vless, bool hys) =>
        baseText + (vless && hys ? "-SYNC" : hys ? "-HYS" : "");

    /// <summary>ключ → каноническое имя для показа</summary>
    private readonly Dictionary<string, string> _display = new(StringComparer.Ordinal);
    /// <summary>ключ синонима → ключ канона</summary>
    private readonly Dictionary<string, string> _alias = new(StringComparer.Ordinal);

    public bool IsCanonical(string key) => _display.ContainsKey(key);
    public IReadOnlyDictionary<string, string> Canon => _display;

    public NameUnifier(XuiNamesConfig cfg)
    {
        foreach (var raw in cfg.Lines)
        {
            var line = raw.Split('#', 2)[0].Trim();
            if (line.Length == 0) continue;
            var eq = line.IndexOf('=');
            if (eq > 0)
            {
                var a = line[..eq].Trim();
                var b = line[(eq + 1)..].Trim();
                if (a.Length == 0 || b.Length == 0) continue;
                var bk = BaseKey(b);
                _display.TryAdd(bk, BaseText(b));
                _alias[BaseKey(a)] = bk;
                _alias[StripHys(Parts(DoTranslit(a)))] = bk;
            }
            else
            {
                _display[BaseKey(line)] = BaseText(line);
            }
        }
    }

    // ── примитивы ──

    private static string DoConfusable(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s) sb.Append(Confusable.TryGetValue(ch, out var r) ? r : ch);
        return sb.ToString();
    }

    private static string DoTranslit(string s)
    {
        var sb = new StringBuilder(s.Length + 4);
        foreach (var ch in s.ToUpperInvariant()) sb.Append(Translit.TryGetValue(ch, out var r) ? r : ch.ToString());
        return sb.ToString();
    }

    private static List<string> Parts(string s) =>
        NonWord.Split(s.ToUpperInvariant()).Where(p => p.Length > 0).ToList();

    private static string StripHys(List<string> parts)
    {
        var p = parts.ToList();
        bool changed = true;
        while (changed && p.Count > 1)
        {
            changed = false;
            if (SuffixTokens.Contains(p[^1])) { p.RemoveAt(p.Count - 1); changed = true; }
        }
        return string.Concat(p);
    }

    /// <summary>Ключ канонического имени: без регистра/разделителей и без хвоста HYS.</summary>
    public static string BaseKey(string s) => StripHys(Parts(DoConfusable(s)));

    public static string BareKey(string s) => string.Concat(Parts(DoConfusable(s)));

    public static IEnumerable<string> TokensOf(string s) => Parts(DoConfusable(s));

    // ── разбор имени клиента ──

    /// <summary>email → (ключ, был ли хвост HYS). stripTokens — служебные хвосты (HYS, имена нод/входящих).</summary>
    public (string Key, bool Hys) Analyze(string email, ISet<string> stripTokens, IEnumerable<string>? extraKnown = null)
    {
        var known = new HashSet<string>(_display.Keys, StringComparer.Ordinal);
        known.UnionWith(_alias.Keys);
        if (extraKnown is not null) known.UnionWith(extraKnown);
        var protect = _display.Keys;

        var results = new List<(string, bool)>();
        foreach (var variant in new[] { DoConfusable(email), DoTranslit(email) })
        {
            var parts = Parts(variant);
            bool hys = false, changed = true;
            while (changed && parts.Count > 1)
            {
                changed = false;
                foreach (var side in new[] { -1, 0 })
                {
                    if (parts.Count <= 1) break;
                    var idx = side == -1 ? parts.Count - 1 : 0;
                    var tok = parts[idx];
                    // HYS/HY2 — только хвостом: «hy2@selfsni» — это имя, а не Hysteria
                    if (side == 0 && SuffixTokens.Contains(tok)) continue;
                    if (stripTokens.Contains(tok) && !protect.Contains(tok))
                    {
                        hys |= HysTokens.Contains(tok);
                        parts.RemoveAt(idx);
                        changed = true;
                    }
                }
            }
            var key = string.Concat(parts);
            if (!known.Contains(key))
            {
                foreach (var t in SuffixTokens.OrderByDescending(x => x.Length))
                {
                    if (key.EndsWith(t, StringComparison.Ordinal) && key.Length > t.Length &&
                        known.Contains(key[..^t.Length]))
                    {
                        key = key[..^t.Length];
                        hys |= t != "SYNC";
                        break;
                    }
                }
            }
            if (_alias.TryGetValue(key, out var ak)) key = ak;
            results.Add((key, hys));
        }
        foreach (var r in results)
            if (known.Contains(r.Item1) || _display.ContainsKey(r.Item1)) return r;
        return results[0];
    }

    /// <summary>Итоговое имя: база (из списка или из текущих имён) + индекс протокола.</summary>
    public string DisplayFor(string key, IEnumerable<string> emails, string fallbackEmail, bool vless, bool hys)
    {
        string? baseText = _display.TryGetValue(key, out var d) ? d : null;
        if (baseText is null)
            foreach (var e in emails)
            {
                var cand = BaseText(e);
                if (cand.Length > 0 && BareKey(cand) == key) { baseText = cand; break; }
            }
        baseText ??= BaseText(fallbackEmail);
        return !vless && !hys ? fallbackEmail : WithIndex(baseText, vless, hys);
    }

    public string DefaultsText() => string.Join("\n", XuiNamesConfig.DefaultNames);
}
