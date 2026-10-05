using System.IO;
using System.IO.Pipes;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using QTermShared;

namespace QEditor;

public partial class App : Application
{
    /// <summary>Главное окно закрывается — дальше процесс должен только завершиться.</summary>
    public static bool Exiting { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Windows-1251 / KOI8-R / CP866 в .NET — через провайдер кодовых страниц
        System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
        // Телеметрия WPF грузит System.Diagnostics.Tracing на выходе (Application.CriticalShutdown). Если к этому
        // моменту exe подменили обновлением, сборка не читается из бандла → исключение посреди выхода. Грузим сразу.
        _ = typeof(System.Diagnostics.Tracing.EventSource).Assembly;

        var fromQTerm = e.Args.Contains("--from-qterm");
        var files = e.Args.Where(a => !a.StartsWith("--") && File.Exists(a))
                          .Select(Path.GetFullPath).ToList();

        // Копия без окна (упала при закрытии, но жива и держит канал) съедала бы все запуски — убрать
        EditorProcess.KillZombies("QEditor при запуске");

        // Одна копия: если QEditor уже жив — отдать ему файлы/просьбу и выйти
        if (TryHandOff(fromQTerm ? "activate" : files.Count > 0 ? "" : "new", files)) { Shutdown(); return; }

        DispatcherUnhandledException += (_, a) =>
        {
            Log(a.Exception);
            if (Exiting)
            {
                // Падение посреди выхода (CriticalShutdown не довёл дело): «обработать и жить дальше» = процесс
                // без окна, который держит канал и глотает все следующие запуски. Только завершиться.
                Environment.Exit(0);
            }
            MessageBox.Show(a.Exception.Message, "QEditor", MessageBoxButton.OK, MessageBoxImage.Error);
            a.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, a) => { Log(a.Exception); a.SetObserved(); };
        AppDomain.CurrentDomain.UnhandledException += (_, a) => { if (a.ExceptionObject is Exception ex) Log(ex); };

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

    /// <summary>Главное окно закрылось (вкладки закрыты, настройки сохранены): процесс обязан завершиться.
    /// Если выход WPF где-то застрянет или упадёт — сторож через 10 с завершит процесс сам.</summary>
    public static void BeginExit()
    {
        if (Exiting) return;
        Exiting = true;
        new Thread(() =>
        {
            Thread.Sleep(10_000);
            EditorProcess.Note("QEditor: выход не завершился за 10 с после закрытия окна — завершаю процесс принудительно");
            Environment.Exit(0);
        }) { IsBackground = true, Name = "QEditor exit watchdog" }.Start();
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

    private static void Log(Exception ex) => EditorProcess.Note(ex.ToString());
}
