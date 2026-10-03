using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace QTermShared;

/// <summary>
/// Тема QTerm и QEditor: «dark» (по умолчанию) / «light» / «system» (как в Windows).
/// Меняет палитру приложения на лету (все цвета в XAML — DynamicResource),
/// перекрашивает заголовки окон (DWM) и следит за сменой темы Windows.
/// </summary>
public static class ThemeManager
{
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private static string _mode = "dark";
    private static bool _hooked;

    public static readonly (string Mode, string Title)[] Modes =
    {
        ("dark", "Тёмная"),
        ("light", "Светлая"),
        ("system", "Как в Windows"),
    };

    public static string Mode => _mode;
    public static bool IsLight { get; private set; }

    /// <summary>Тема применилась (в т.ч. смена темы Windows в режиме «system»).</summary>
    public static event Action? Changed;

    public static void Init(string? mode) => Apply(string.IsNullOrEmpty(mode) ? "dark" : mode);

    /// <summary>Слежение за темой Windows — только в режиме «Как в Windows»
    /// (в тёмной/светлой системные broadcast-сообщения не трогаем вовсе).</summary>
    private static void HookSystem(bool on)
    {
        if (on == _hooked) return;
        _hooked = on;
        if (on) SystemEvents.UserPreferenceChanged += OnSystemPref;
        else SystemEvents.UserPreferenceChanged -= OnSystemPref;
    }

    private static void OnSystemPref(object? sender, UserPreferenceChangedEventArgs e)
    {
        if (_mode != "system" || e.Category != UserPreferenceCategory.General) return;
        // асинхронно: не держим отправителя WM_SETTINGCHANGE
        Application.Current?.Dispatcher.InvokeAsync(() =>
        {
            if (_mode == "system" && SystemIsLight() != IsLight) Apply("system");
        });
    }

    public static void Apply(string mode)
    {
        _mode = mode is "light" or "system" ? mode : "dark";
        IsLight = _mode == "light" || _mode == "system" && SystemIsLight();
        HookSystem(_mode == "system");
        var app = Application.Current;
        if (app is null) return;
        var dicts = app.Resources.MergedDictionaries;
        var src = new Uri(IsLight ? "Themes/Colors.Light.xaml" : "Themes/Colors.Dark.xaml", UriKind.Relative);
        var idx = dicts.ToList().FindIndex(d => d.Source?.OriginalString.Contains("Themes/Colors.") == true);
        var fresh = new ResourceDictionary { Source = src };
        if (idx >= 0) dicts[idx] = fresh; else dicts.Insert(0, fresh);
        foreach (Window w in app.Windows) ApplyChrome(w);
        Changed?.Invoke();
    }

    /// <summary>Светлая ли тема приложений в Windows (Параметры → Персонализация → Цвета).</summary>
    public static bool SystemIsLight()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return k?.GetValue("AppsUseLightTheme") is int v && v == 1;
        }
        catch { return false; }
    }

    /// <summary>Тёмный/светлый системный заголовок окна (DWMWA_USE_IMMERSIVE_DARK_MODE).</summary>
    public static void ApplyChrome(Window w)
    {
        var h = new WindowInteropHelper(w).Handle;
        if (h == IntPtr.Zero) return;
        int dark = IsLight ? 0 : 1;
        _ = DwmSetWindowAttribute(h, 20, ref dark, sizeof(int));
    }

    public static Brush Brush(string key) =>
        Application.Current?.TryFindResource(key) as Brush ?? Brushes.Gray;
}
