using System.Windows.Input;

namespace QTermWin.UI;

/// <summary>Функция приложения, на которую можно повесить сочетание.</summary>
public sealed record HotkeyAction(string Id, string Title, string Default);

/// <summary>
/// Сочетание: модификаторы + ФИЗИЧЕСКАЯ клавиша в терминах KeyboardEvent.code
/// («KeyG», «Digit1», «F5»…). Одно представление и для xterm.js (там ловим по
/// ev.code — не зависит от раскладки RU/EN), и для WPF (Key → code).
/// Хранится строкой «Ctrl+Shift+KeyG».
/// </summary>
public sealed record Gesture(bool Ctrl, bool Shift, bool Alt, string Code)
{
    public static Gesture? Parse(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var parts = s.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0) return null;
        bool c = false, sh = false, a = false;
        foreach (var p in parts[..^1])
        {
            if (p.Equals("Ctrl", StringComparison.OrdinalIgnoreCase)) c = true;
            else if (p.Equals("Shift", StringComparison.OrdinalIgnoreCase)) sh = true;
            else if (p.Equals("Alt", StringComparison.OrdinalIgnoreCase)) a = true;
            else return null;
        }
        return new Gesture(c, sh, a, parts[^1]);
    }

    private string Mods => (Ctrl ? "Ctrl+" : "") + (Shift ? "Shift+" : "") + (Alt ? "Alt+" : "");

    /// <summary>Для хранения: «Ctrl+Shift+KeyG».</summary>
    public string Canon => Mods + Code;

    /// <summary>Для людей: «Ctrl+Shift+G».</summary>
    public string Display => Mods + Hotkeys.KeyLabel(Code);

    public bool IsFKey => Code.Length >= 2 && Code[0] == 'F' && char.IsDigit(Code[1]);
}

public static class Hotkeys
{
    /// <summary>Все функции QTerm с горячими клавишами. Default "" = не назначено.</summary>
    public static readonly HotkeyAction[] Actions = BuildActions();

    private static HotkeyAction[] BuildActions()
    {
        var list = new List<HotkeyAction>
        {
            new("git", "Команды Git: быстрый вызов", "Ctrl+Shift+KeyG"),
            new("gitedit", "Команды Git: редактор", ""),
            new("snippets", "Меню «Команды»", ""),
            new("journal", "Журнал команд", ""),
            new("copy", "Копировать выделение (терминал)", "Ctrl+Shift+KeyC"),
            new("paste", "Вставить (терминал)", "Ctrl+Shift+KeyV"),
            new("clear", "Очистить терминал", ""),
            new("broadcast", "«Во все» вкл/выкл", ""),
            new("reconnect", "Переподключить", ""),
            new("files", "Файлы: показать/скрыть", ""),
            new("dup", "Дублировать вкладку", "Ctrl+KeyT"),
            new("close", "Закрыть вкладку", "Ctrl+KeyW"),
            new("next", "Следующая вкладка", ""),
            new("prev", "Предыдущая вкладка", ""),
        };
        for (int i = 1; i <= 9; i++)
            list.Add(new($"tab{i}", $"Вкладка {i}", $"Ctrl+Digit{i}"));
        list.AddRange(new HotkeyAction[]
        {
            new("newnode", "Новая нода", ""),
            new("sync", "Синк", ""),
            new("qeditor", "QEditor (скрапбук)", ""),
            new("xui", "Ноды 3x-ui", ""),
            new("cascade", "Каскад", ""),
            new("nodeadd", "Нода из выделения (итог установщика 3x-ui / AWG)", "Ctrl+Shift+KeyA"),
            new("hotkeys", "Горячие клавиши…", ""),
        });
        return list.ToArray();
    }

    /// <summary>Текущая раскладка функций: переопределения из settings.json поверх
    /// умолчаний ("" в настройках = снято).</summary>
    public static Dictionary<string, Gesture?> Load()
    {
        var ov = Security.AppSettings.Load().Hotkeys ?? new();
        var map = new Dictionary<string, Gesture?>();
        foreach (var a in Actions)
            map[a.Id] = Gesture.Parse(ov.TryGetValue(a.Id, out var s) ? s : a.Default);
        return map;
    }

    /// <summary>Пишем только отличия от умолчаний (новые умолчания будущих волн доедут).</summary>
    public static void Save(Dictionary<string, Gesture?> map)
    {
        var ov = new Dictionary<string, string>();
        foreach (var a in Actions)
        {
            var cur = map.GetValueOrDefault(a.Id)?.Canon ?? "";
            var def = Gesture.Parse(a.Default)?.Canon ?? "";
            if (cur != def) ov[a.Id] = cur;
        }
        var st = Security.AppSettings.Load();
        st.Hotkeys = ov.Count > 0 ? ov : null;
        st.Save();
    }

    public static string? Find(Dictionary<string, Gesture?> map, bool ctrl, bool shift, bool alt, string code)
    {
        foreach (var (id, g) in map)
            if (g is not null && g.Ctrl == ctrl && g.Shift == shift && g.Alt == alt && g.Code == code)
                return id;
        return null;
    }

    public static string Title(string id) =>
        Actions.FirstOrDefault(a => a.Id == id)?.Title ?? id;

    /// <summary>WPF Key → KeyboardEvent.code (null — клавиша не назначаема).</summary>
    public static string? CodeOf(Key k)
    {
        if (k >= Key.A && k <= Key.Z) return "Key" + k;
        if (k >= Key.D0 && k <= Key.D9) return "Digit" + (k - Key.D0);
        if (k >= Key.NumPad0 && k <= Key.NumPad9) return "Numpad" + (k - Key.NumPad0);
        if (k >= Key.F1 && k <= Key.F24) return "F" + (k - Key.F1 + 1);
        return k switch
        {
            Key.OemTilde => "Backquote",
            Key.OemMinus => "Minus",
            Key.OemPlus => "Equal",
            Key.OemOpenBrackets => "BracketLeft",
            Key.OemCloseBrackets => "BracketRight",
            Key.OemSemicolon => "Semicolon",
            Key.OemQuotes => "Quote",
            Key.OemComma => "Comma",
            Key.OemPeriod => "Period",
            Key.OemQuestion => "Slash",
            Key.OemPipe => "Backslash",
            Key.OemBackslash => "IntlBackslash",
            Key.Space => "Space",
            Key.Tab => "Tab",
            Key.Enter => "Enter",
            Key.Back => "Backspace",
            Key.Insert => "Insert",
            Key.Delete => "Delete",
            Key.Home => "Home",
            Key.End => "End",
            Key.PageUp => "PageUp",
            Key.PageDown => "PageDown",
            Key.Left => "ArrowLeft",
            Key.Right => "ArrowRight",
            Key.Up => "ArrowUp",
            Key.Down => "ArrowDown",
            Key.Multiply => "NumpadMultiply",
            Key.Add => "NumpadAdd",
            Key.Subtract => "NumpadSubtract",
            Key.Divide => "NumpadDivide",
            Key.Decimal => "NumpadDecimal",
            _ => null,
        };
    }

    public static string KeyLabel(string code)
    {
        if (code.Length == 4 && code.StartsWith("Key", StringComparison.Ordinal)) return code[3..];
        if (code.StartsWith("Digit", StringComparison.Ordinal)) return code[5..];
        if (code.Length == 7 && code.StartsWith("Numpad", StringComparison.Ordinal)) return "Num " + code[6..];
        return code switch
        {
            "Backquote" => "`",
            "Minus" => "-",
            "Equal" => "=",
            "BracketLeft" => "[",
            "BracketRight" => "]",
            "Semicolon" => ";",
            "Quote" => "'",
            "Comma" => ",",
            "Period" => ".",
            "Slash" => "/",
            "Backslash" or "IntlBackslash" => "\\",
            "Backspace" => "Backspace",
            "Insert" => "Ins",
            "Delete" => "Del",
            "PageUp" => "PgUp",
            "PageDown" => "PgDn",
            "ArrowLeft" => "←",
            "ArrowRight" => "→",
            "ArrowUp" => "↑",
            "ArrowDown" => "↓",
            "NumpadMultiply" => "Num *",
            "NumpadAdd" => "Num +",
            "NumpadSubtract" => "Num -",
            "NumpadDivide" => "Num /",
            "NumpadDecimal" => "Num .",
            _ => code,
        };
    }

    /// <summary>Сочетания, которые нужны шеллу/редакторам в терминале — предупреждаем.</summary>
    public static bool StealsFromTerminal(Gesture g) =>
        g.Ctrl && !g.Shift && !g.Alt && g.Code.Length == 4 && g.Code.StartsWith("Key", StringComparison.Ordinal)
        && "ACDEKLRUZ".Contains(g.Code[3]);
}
