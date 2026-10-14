using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace QTermShared;

/// <summary>
/// Окна под любой набор мониторов (разные размеры, разрешения и масштабы; процесс — Per-Monitor V2, см. app.manifest).
/// Одним обработчиком на все окна приложения (QTerm и QEditor):
/// · окно, у которого содержимое не влезло (кнопки внизу/справа обрезаны), растягивается под содержимое;
/// · окно не больше рабочей области своего монитора (с подгонкой MinWidth/MinHeight), диалог «по высоте содержимого»
///   на маленьком экране получает прокрутку вместо обрезанных кнопок;
/// · диалог открывается по центру окна-владельца на ЕГО мониторе (а не где придётся при разном DPI);
/// · главные окна без владельца — на мониторе главного окна QTerm (или под курсором);
/// · размер/положение (и «развёрнуто») запоминаются в %APPDATA%\QTerm\windows.json; если того монитора больше нет —
///   окно возвращается в видимую область;
/// · пропорции внутри окна — ширины/высоты колонок и строк у сеток с GridSplitter — запоминаются там же
///   (при отпускании разделителя и при закрытии) и восстанавливаются при открытии.
/// Координаты — в пикселях через Win32: WPF-овские Left/Top в DIP на мониторах с разным масштабом врут.
/// </summary>
public static class WindowFit
{
    // ── Win32 ──

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int L, T, R, B;
        public int W => R - L;
        public int H => B - T;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor, rcWork;
        public int dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WINDOWPLACEMENT
    {
        public int length, flags, showCmd;
        public POINT ptMin, ptMax;
        public RECT rcNormal;
    }

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10;
    private const int SW_SHOWNORMAL = 1, SW_SHOWMAXIMIZED = 3, DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr hmon, ref MONITORINFO mi);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool GetWindowPlacement(IntPtr hwnd, ref WINDOWPLACEMENT wp);
    [DllImport("user32.dll")] private static extern bool SetWindowPlacement(IntPtr hwnd, ref WINDOWPLACEMENT wp);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);

    // ── хранилище ──

    private sealed class Place
    {
        public int L { get; set; }
        public int T { get; set; }
        public int R { get; set; }
        public int B { get; set; }
        public bool Max { get; set; }
        public double W { get; set; }
        public double H { get; set; }
        /// <summary>Сетки с разделителями: имя (или #номер) → «C:300,*1.5;R:*1,200».</summary>
        public Dictionary<string, string>? Splits { get; set; }
    }

    private static readonly string StorePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm", "windows.json");

    private static string _app = "QTerm";

    private static Dictionary<string, Place> ReadStore()
    {
        try
        {
            if (File.Exists(StorePath))
                return JsonSerializer.Deserialize<Dictionary<string, Place>>(File.ReadAllText(StorePath)) ?? new();
        }
        catch { /* битый файл — с нуля */ }
        return new();
    }

    private static void WriteStore(string key, Place p)
    {
        try
        {
            // перечитываем: QTerm и QEditor пишут один файл
            var all = ReadStore();
            all[key] = p;
            Directory.CreateDirectory(Path.GetDirectoryName(StorePath)!);
            File.WriteAllText(StorePath, JsonSerializer.Serialize(all, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* не критично */ }
    }

    // ── подключение ──

    private sealed class Anchor { public Rect Px; public double TopDip; }
    private static readonly ConditionalWeakTable<Window, Anchor> Anchors = new();
    private static readonly ConditionalWeakTable<Window, object> Done = new();

    /// <summary>Один раз на старте приложения — ПОСЛЕ обработчика, ставящего шрифт окнам (меряем с итоговым шрифтом).</summary>
    public static void Register(string app)
    {
        _app = app;
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent,
            new RoutedEventHandler((s, _) => { if (s is Window w) Attach(w); }));
    }

    /// <summary>Поставить окно над прямоугольником экрана (в пикселях устройства) — по центру по горизонтали,
    /// на topDip ниже его верхнего края. Пример: палитра над областью терминала.</summary>
    public static void PlaceOver(Window w, Rect devicePx, double topDip)
    {
        w.WindowStartupLocation = WindowStartupLocation.Manual;
        Anchors.AddOrUpdate(w, new Anchor { Px = devicePx, TopDip = topDip });
    }

    private static bool Skip(Window w) =>
        w.WindowStyle == WindowStyle.None && w.AllowsTransparency || // служебные (гейт Hello и т.п.)
        w.Width is > 0 and < 8 || w.Left < -5000;

    private static string? KeyOf(Window w) => w.GetType() == typeof(Window) ? null : _app + "." + w.GetType().Name;

    private static void Attach(Window w)
    {
        if (Skip(w) || Done.TryGetValue(w, out _)) return;
        Done.Add(w, new object());
        try { Fit(w); }
        catch { /* раскладка окна важнее — молча */ }
    }

    private static IntPtr Hwnd(Window w) => new WindowInteropHelper(w).Handle;

    private static void Fit(Window w)
    {
        var hwnd = Hwnd(w);
        if (hwnd == IntPtr.Zero) return;
        var key = KeyOf(w);
        var owned = w.Owner is not null;
        var resizable = w.ResizeMode is ResizeMode.CanResize or ResizeMode.CanResizeWithGrip &&
                        w.SizeToContent == SizeToContent.Manual;
        var restored = false;

        if (resizable && key is not null)
        {
            if (ReadStore().TryGetValue(key, out var pl))
            {
                if (!owned && pl.R > pl.L && pl.B > pl.T) restored = Restore(hwnd, pl);
                else if (owned && pl.W > 50 && pl.H > 50) { w.Width = pl.W; w.Height = pl.H; }
            }
            w.Closing += (_, _) => Remember(w, key, owned);
        }
        if (key is not null) HookSplits(w, key, resizable, owned);

        w.UpdateLayout();
        // растягиваем только диалоги: у главных окон (QTerm, «Ноды 3x-ui», QEditor) размер свой/запомненный,
        // а широкие тулбары там обрезаются штатно
        if (w.WindowState != WindowState.Maximized && (owned || w.SizeToContent != SizeToContent.Manual)) Grow(w);
        Position(w, hwnd, owned, restored);

        if (w.SizeToContent != SizeToContent.Manual)
            w.SizeChanged += (_, _) => w.Dispatcher.InvokeAsync(() => Clamp(w, center: null), DispatcherPriority.Background);
    }

    // ── запомнить / восстановить ──

    private static void Remember(Window w, string key, bool owned)
    {
        var p = new Place { Splits = CaptureSplits(w) };
        var rb = w.RestoreBounds;
        if (!rb.IsEmpty && rb.Width > 0) { p.W = rb.Width; p.H = rb.Height; }
        else { p.W = w.ActualWidth; p.H = w.ActualHeight; }
        if (!owned)
        {
            var wp = new WINDOWPLACEMENT { length = Marshal.SizeOf<WINDOWPLACEMENT>() };
            if (GetWindowPlacement(Hwnd(w), ref wp))
            {
                p.L = wp.rcNormal.L; p.T = wp.rcNormal.T; p.R = wp.rcNormal.R; p.B = wp.rcNormal.B;
                p.Max = wp.showCmd == SW_SHOWMAXIMIZED || w.WindowState == WindowState.Maximized;
            }
        }
        if (ReadStore().TryGetValue(key, out var old) && old.Splits is { } prevSplits)
        {
            var merged = new Dictionary<string, string>(prevSplits);
            foreach (var (gk, enc) in p.Splits ?? new())
                merged[gk] = prevSplits.TryGetValue(gk, out var pv) ? MergeKeepNonZero(pv, enc) : enc;
            p.Splits = merged;
        }
        WriteStore(key, p);
    }

    // ── пропорции: сетки с GridSplitter ──

    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        var n = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < n; i++)
        {
            var c = VisualTreeHelper.GetChild(root, i);
            if (c is T t) yield return t;
            foreach (var d in Descendants<T>(c)) yield return d;
        }
    }

    private static List<(string Key, Grid Grid)> SplitGrids(Window w)
    {
        var grids = Descendants<GridSplitter>(w)
            .Select(s => VisualTreeHelper.GetParent(s) as Grid)
            .Where(g => g is not null).Distinct().Cast<Grid>().ToList();
        return grids.Select((g, i) => (string.IsNullOrEmpty(g.Name) ? "#" + i : g.Name, g)).ToList();
    }

    private static string Enc(GridLength l) =>
        l.IsAuto ? "a" : (l.IsStar ? "*" : "") + l.Value.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);

    private static GridLength? Dec(string s)
    {
        if (s == "a" || s.Length == 0) return null;
        var star = s[0] == '*';
        return double.TryParse(star ? s[1..] : s, System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var v)
            ? new GridLength(v, star ? GridUnitType.Star : GridUnitType.Pixel) : null;
    }

    private static Dictionary<string, string>? CaptureSplits(Window w)
    {
        var grids = SplitGrids(w);
        if (grids.Count == 0) return null;
        return grids.ToDictionary(x => x.Key, x =>
            "C:" + string.Join(",", x.Grid.ColumnDefinitions.Select(c => Enc(c.Width))) +
            ";R:" + string.Join(",", x.Grid.RowDefinitions.Select(r => Enc(r.Height))));
    }

    /// <summary>Восстановить и следить. Колонки/строки, которые окно прячет само (ширина 0) или которые «авто»,
    /// не трогаем ни при восстановлении, ни поверх запомненного.</summary>
    private static void HookSplits(Window w, string key, bool resizable, bool owned)
    {
        var grids = SplitGrids(w);
        if (grids.Count == 0) return;
        if (ReadStore().TryGetValue(key, out var pl) && pl.Splits is { } saved)
        {
            foreach (var (gk, g) in grids)
            {
                if (!saved.TryGetValue(gk, out var enc)) continue;
                var parts = enc.Split(';');
                if (parts.Length != 2) continue;
                var cols = parts[0].StartsWith("C:") ? parts[0][2..].Split(',') : Array.Empty<string>();
                var rows = parts[1].StartsWith("R:") ? parts[1][2..].Split(',') : Array.Empty<string>();
                if (cols.Length == g.ColumnDefinitions.Count)
                    for (var i = 0; i < cols.Length; i++)
                    {
                        var cur = g.ColumnDefinitions[i].Width;
                        if (Dec(cols[i]) is { } v && v.Value > 0 && !cur.IsAuto && cur.Value > 0) g.ColumnDefinitions[i].Width = v;
                    }
                if (rows.Length == g.RowDefinitions.Count)
                    for (var i = 0; i < rows.Length; i++)
                    {
                        var cur = g.RowDefinitions[i].Height;
                        if (Dec(rows[i]) is { } v && v.Value > 0 && !cur.IsAuto && cur.Value > 0) g.RowDefinitions[i].Height = v;
                    }
            }
        }
        // отпустил разделитель — сразу в файл (не только при закрытии: окно могли убить)
        foreach (var s in Descendants<GridSplitter>(w))
            s.DragCompleted += (_, _) => SaveSplits(w, key);
        if (!resizable) w.Closing += (_, _) => SaveSplits(w, key);
    }

    private static void SaveSplits(Window w, string key)
    {
        try
        {
            var all = ReadStore();
            var p = all.TryGetValue(key, out var old) ? old : new Place();
            var now = CaptureSplits(w);
            if (now is null) return;
            p.Splits ??= new();
            foreach (var (gk, enc) in now)
            {
                // спрятанная колонка (0) не затирает запомненную ширину
                if (p.Splits.TryGetValue(gk, out var prev)) p.Splits[gk] = MergeKeepNonZero(prev, enc);
                else p.Splits[gk] = enc;
            }
            WriteStore(key, p);
        }
        catch { /* не критично */ }
    }

    private static string MergeKeepNonZero(string prev, string now)
    {
        static string[] Part(string s, string tag) =>
            s.Split(';').FirstOrDefault(x => x.StartsWith(tag)) is { } x ? x[tag.Length..].Split(',') : Array.Empty<string>();
        string Merge(string tag)
        {
            var a = Part(prev, tag);
            var b = Part(now, tag);
            if (a.Length != b.Length) return string.Join(",", b);
            return string.Join(",", b.Select((v, i) => v is "0" or "*0" ? a[i] : v));
        }
        return "C:" + Merge("C:") + ";R:" + Merge("R:");
    }

    private static bool Restore(IntPtr hwnd, Place pl)
    {
        var wp = new WINDOWPLACEMENT { length = Marshal.SizeOf<WINDOWPLACEMENT>() };
        if (!GetWindowPlacement(hwnd, ref wp)) return false;
        wp.flags = 0;
        wp.showCmd = pl.Max ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
        wp.rcNormal = new RECT { L = pl.L, T = pl.T, R = pl.R, B = pl.B };
        // Дважды: первый вызов переносит окно на монитор (если у него другой масштаб, WPF по WM_DPICHANGED
        // пересчитывает размер), второй ставит точный прямоугольник уже в новом масштабе.
        // Монитора больше нет — Windows сама вернёт окно в видимую область, Clamp подожмёт по размеру.
        SetWindowPlacement(hwnd, ref wp);
        SetWindowPlacement(hwnd, ref wp);
        return true;
    }

    // ── растянуть под содержимое ──

    /// <summary>Если элементы управления (вне прокручиваемых областей) не влезли — растянуть окно на недостающее.</summary>
    private static void Grow(Window w)
    {
        if (VisualTreeHelper.GetChildrenCount(w) == 0 || VisualTreeHelper.GetChild(w, 0) is not FrameworkElement root) return;
        double clientW = root.ActualWidth, clientH = root.ActualHeight;
        if (clientW <= 0 || clientH <= 0) return;
        double maxR = 0, maxB = 0;
        Walk(root, w, ref maxR, ref maxB);
        const double pad = 12;
        var dx = maxR > clientW + 1 ? maxR - clientW + pad : 0;
        var dy = maxB > clientH + 1 ? maxB - clientH + pad : 0;
        var stc = w.SizeToContent;
        if (dx > 0 && stc is not (SizeToContent.Width or SizeToContent.WidthAndHeight)) w.Width = w.ActualWidth + dx;
        if (dy > 0 && stc is not (SizeToContent.Height or SizeToContent.WidthAndHeight)) w.Height = w.ActualHeight + dy;
        if (dx > 0 || dy > 0) w.UpdateLayout();
    }

    private static void Walk(DependencyObject node, Window w, ref double maxR, ref double maxB)
    {
        var n = VisualTreeHelper.GetChildrenCount(node);
        for (var i = 0; i < n; i++)
        {
            var c = VisualTreeHelper.GetChild(node, i);
            if (c is UIElement { IsVisible: false }) continue;
            if (c is ScrollViewer) continue; // прокручиваемое содержимое обрезано законно
            if (c is Control ctl && ctl.ActualWidth > 0 && ctl.ActualHeight > 0)
            {
                try
                {
                    var b = ctl.TransformToAncestor(w).TransformBounds(new Rect(ctl.RenderSize));
                    if (b.Right > maxR) maxR = b.Right;
                    if (b.Bottom > maxB) maxB = b.Bottom;
                }
                catch { /* не в дереве окна */ }
                // внутрь шаблонов кнопок/полей не лезем — хватает их собственных границ
                if (c is not (ContentControl or ItemsControl or UserControl)) continue;
            }
            Walk(c, w, ref maxR, ref maxB);
        }
    }

    // ── мониторы и положение ──

    private static RECT Work(IntPtr mon)
    {
        var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        return GetMonitorInfo(mon, ref mi) ? mi.rcWork : new RECT { L = 0, T = 0, R = 1280, B = 720 };
    }

    private static IntPtr CursorMonitor()
    {
        GetCursorPos(out var p);
        return MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
    }

    private static POINT Center(RECT r) => new() { X = r.L + r.W / 2, Y = r.T + r.H / 2 };

    private static void Position(Window w, IntPtr hwnd, bool owned, bool restored)
    {
        if (w.WindowState == WindowState.Maximized) { Clamp(w, center: null); return; }
        POINT? center = null;
        if (Anchors.TryGetValue(w, out _))
        {
            // палитра над терминалом — точку считает Clamp
        }
        else if (owned && w.WindowStartupLocation == WindowStartupLocation.CenterOwner && Hwnd(w.Owner!) is var oh && oh != IntPtr.Zero)
        {
            GetWindowRect(oh, out var or);
            center = Center(or);
        }
        else if (!owned && !restored && w.WindowStartupLocation == WindowStartupLocation.CenterScreen)
        {
            var main = Application.Current?.MainWindow;
            var mon = main is not null && main != w && main.IsLoaded && Hwnd(main) is var mh && mh != IntPtr.Zero
                ? MonitorFromWindow(mh, MONITOR_DEFAULTTONEAREST)
                : CursorMonitor();
            center = Center(Work(mon));
        }
        if (center is { } c)
        {
            // сначала переносим на нужный монитор (там окно получит свой DPI), потом подгоняем размер и точку
            GetWindowRect(hwnd, out var r);
            SetWindowPos(hwnd, IntPtr.Zero, c.X - r.W / 2, c.Y - r.H / 2, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
        Clamp(w, center);
        // второй проход после того, как WPF доразложит окно в новом масштабе
        w.Dispatcher.InvokeAsync(() => Clamp(w, center), DispatcherPriority.Background);
    }

    /// <summary>Окно целиком в рабочей области своего монитора: размер не больше её, видимая рамка внутри.</summary>
    private static void Clamp(Window w, POINT? center)
    {
        var hwnd = Hwnd(w);
        if (hwnd == IntPtr.Zero || !w.IsVisible) return;
        var anchored = Anchors.TryGetValue(w, out var an);
        IntPtr mon;
        if (anchored)
            mon = MonitorFromPoint(new POINT { X = (int)(an!.Px.X + an.Px.Width / 2), Y = (int)(an.Px.Y + 10) }, MONITOR_DEFAULTTONEAREST);
        else if (center is { } cc)
            mon = MonitorFromPoint(cc, MONITOR_DEFAULTTONEAREST);
        else
            mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        var work = Work(mon);
        var dpi = VisualTreeHelper.GetDpi(w);
        double wDip = work.W / dpi.DpiScaleX, hDip = work.H / dpi.DpiScaleY;

        if (w.WindowState == WindowState.Maximized) return;

        if (w.MinWidth > wDip) w.MinWidth = wDip;
        if (w.MinHeight > hDip) w.MinHeight = hDip;
        if (w.SizeToContent == SizeToContent.Manual)
        {
            if (w.ActualWidth > wDip + 0.5) w.Width = wDip;
            if (w.ActualHeight > hDip + 0.5) w.Height = hDip;
        }
        else
        {
            // «по содержимому» выше экрана — прокрутка вместо обрезанных кнопок
            if (w.ActualHeight > hDip + 0.5 && w.Content is UIElement el and not ScrollViewer)
            {
                w.Content = null;
                w.Content = new ScrollViewer
                {
                    Content = el, Focusable = false,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                };
            }
            if (Math.Abs(w.MaxWidth - wDip) > 0.5) w.MaxWidth = wDip;
            if (Math.Abs(w.MaxHeight - hDip) > 0.5) w.MaxHeight = hDip;
        }
        w.UpdateLayout();

        if (!GetWindowRect(hwnd, out var r)) return;
        // невидимые рамки ресайза (Win10/11): выравниваем по видимой части
        int il = 0, it = 0, ir = 0, ib = 0;
        if (DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out var vis, Marshal.SizeOf<RECT>()) == 0)
        {
            il = vis.L - r.L; it = vis.T - r.T; ir = r.R - vis.R; ib = r.B - vis.B;
        }
        int x = r.L, y = r.T;
        if (anchored)
        {
            x = (int)(an!.Px.X + an.Px.Width / 2) - r.W / 2;
            y = (int)(an.Px.Y + an.TopDip * dpi.DpiScaleY) - it;
        }
        else if (center is { } c)
        {
            x = c.X - r.W / 2;
            y = c.Y - r.H / 2;
        }
        var minX = work.L - il;
        var minY = work.T - it;
        x = Math.Max(minX, Math.Min(x, work.R - r.W + ir));
        y = Math.Max(minY, Math.Min(y, work.B - r.H + ib));
        if (x != r.L || y != r.T)
            SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
}
