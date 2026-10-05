using System.IO;
using System.IO.Pipes;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using QTermShared;

namespace QEditor;

public partial class App : Application
{
    private static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm", "editor-crash.log");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Windows-1251 / KOI8-R / CP866 в .NET — через провайдер кодовых страниц
        System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);

        var fromQTerm = e.Args.Contains("--from-qterm");
        var files = e.Args.Where(a => !a.StartsWith("--") && File.Exists(a))
                          .Select(Path.GetFullPath).ToList();

        // Одна копия: если QEditor уже жив — отдать ему файлы/просьбу и выйти
        if (TryHandOff(fromQTerm ? "activate" : files.Count > 0 ? "" : "new", files)) { Shutdown(); return; }

        DispatcherUnhandledException += (_, a) =>
        {
            Log(a.Exception);
            MessageBox.Show(a.Exception.Message, "QEditor", MessageBoxButton.OK, MessageBoxImage.Error);
            a.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, a) => { Log(a.Exception); a.SetObserved(); };

        // Тема QEditor (своя настройка: Вид → Тема) — до первого окна
        ThemeManager.Init(EditorSettings.Current.Theme);

        // Заголовок под тему и шрифт UI из общих настроек QTerm
        var (family, size) = ReadUiFont();
        EventManager.RegisterClassHandler(typeof(Window), Window.LoadedEvent,
            new RoutedEventHandler((sender, args) =>
            {
                if (sender is not Window w) return;
                ThemeManager.ApplyChrome(w);
                w.FontFamily = new FontFamily(family);
                w.FontSize = size;
                TextOptions.SetTextFormattingMode(w, TextFormattingMode.Display);
                TextOptions.SetTextRenderingMode(w, TextRenderingMode.ClearType);
                w.UseLayoutRounding = true;
            }));

        // Окна под любой набор мониторов (общий с QTerm механизм, своя запись в windows.json)
        WindowFit.Register("QEditor");

        var link = new HostLink(Dispatcher);
        var win = new EditorHostWindow(link);
        MainWindow = win;
        ShutdownMode = ShutdownMode.OnMainWindowClose;
        link.Start();
        win.Show();
        // проводник: «Открыть в QEditor», «Открыть с помощью», файлы без расширения (authorized_keys…)
        Task.Run(ShellAssoc.Ensure);
        // «Открыть с помощью» / перетаскивание на exe — эти файлы; руками — чистый
        // скрапбук; из QTerm — ждём open по каналу
        foreach (var f in files) win.OpenLocalFile(f);
        if (!fromQTerm && files.Count == 0) win.NewLocalDocument();
    }

    private static bool TryHandOff(string op, List<string> files)
    {
        try
        {
            using var c = new NamedPipeClientStream(".", EditorProtocol.PipeName, PipeDirection.InOut);
            c.Connect(250);
            using var w = EditorProtocol.Writer(c);
            foreach (var f in files) w.WriteLine(EditorProtocol.Encode(new EditorMsg { Op = "openlocal", Path = f }));
            if (op.Length > 0) w.WriteLine(EditorProtocol.Encode(new EditorMsg { Op = op }));
            else w.WriteLine(EditorProtocol.Encode(new EditorMsg { Op = "activate" }));
            return true;
        }
        catch { return false; } // сервера нет — мы первая копия
    }

    private static (string Family, double Size) ReadUiFont()
    {
        try
        {
            var p = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "QTerm", "settings.json");
            if (File.Exists(p))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(p));
                var r = doc.RootElement;
                var fam = r.TryGetProperty("UiFontFamily", out var f) && f.ValueKind == JsonValueKind.String
                    ? f.GetString() : null;
                var sz = r.TryGetProperty("UiFontSize", out var z) && z.ValueKind == JsonValueKind.Number
                    ? z.GetDouble() : 14;
                return ((fam is { Length: > 0 } ? fam + ", " : "") + "Segoe UI Variable Text, Segoe UI", sz);
            }
        }
        catch { }
        return ("Segoe UI Variable Text, Segoe UI", 14);
    }

    private static void Log(Exception ex)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {ex}\n\n");
        }
        catch { }
    }
}
