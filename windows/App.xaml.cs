using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace QTermWin;

public partial class App : Application
{
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr FindWindow(string? lpClassName, string? lpWindowName);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    private static string CrashLog => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "QTerm", "crash.log");

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Тема (как в Windows / тёмная / светлая) — до первого окна
        QTermShared.ThemeManager.Init(Security.AppSettings.Load().Theme);

        // Заголовок под тему каждому окну приложения (диалоги включительно)
        EventManager.RegisterClassHandler(typeof(Window), Window.LoadedEvent,
            new RoutedEventHandler((sender, _) =>
            {
                if (sender is Window w)
                {
                    QTermShared.ThemeManager.ApplyChrome(w);
                    var st = Security.AppSettings.Load();
                    w.FontFamily = new System.Windows.Media.FontFamily(
                        st.UiFontFamily is { Length: > 0 } f
                            ? f + ", Segoe UI"
                            : "Segoe UI Variable Text, Segoe UI");
                    w.FontSize = st.UiFontSize ?? 14;
                    // Дефолтный Ideal рендерит UI-текст размыто и тонко;
                    // Display+ClearType = чёткие штрихи как в нативных окнах
                    TextOptions.SetTextFormattingMode(w, TextFormattingMode.Display);
                    TextOptions.SetTextRenderingMode(w, TextRenderingMode.ClearType);
                    w.UseLayoutRounding = true;
                    w.SnapsToDevicePixels = true;
                }
            }));

        // Окна под любой набор мониторов: влезают в экран, растягиваются под содержимое,
        // открываются на мониторе владельца, помнят размер/положение (после шрифта — меряем с ним)
        QTermShared.WindowFit.Register("QTerm");

        DispatcherUnhandledException += (_, args) =>
        {
            Report(args.Exception);
            args.Handled = true; // не даём умереть молча
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex) Report(ex, fatal: true);
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            // Фоновый шум (напр. SSH.NET после disposal при реконнекте) —
            // в лог без диалога
            LogOnly(args.Exception);
            args.SetObserved();
        };

        // Гейт-окно закрывается ДО открытия главного — при дефолтном
        // OnLastWindowClose это убивало приложение («после авторизации ничего
        // нет»). Явный режим до конца старта:
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        // Hello-гейт ДО главного окна. Окно НЕ topmost (лезло поверх самого
        // диалога Hello) — переднего плана процессу даёт Activate()
        if (Security.AppSettings.Load().HelloRequired)
        {
            // Невидимое окно за экраном: процессу нужен только передний план,
            // видимая плашка закрывала поле ввода PIN в диалоге Hello
            var gate = new Window
            {
                Width = 1, Height = 1,
                Left = -10000, Top = -10000,
                WindowStyle = WindowStyle.None,
                AllowsTransparency = true,
                Opacity = 0,
                ShowInTaskbar = false,
                ShowActivated = true,
            };
            gate.Show();
            gate.Activate();
            var verify = Security.HelloGate.VerifyAsync();
            // Диалог Hello всплывает без фокуса — дожимаем SetForegroundWindow
            _ = Task.Run(async () =>
            {
                for (int i = 0; i < 40; i++)
                {
                    var h = FindWindow("Credential Dialog Xaml Host", null);
                    if (h != IntPtr.Zero) { SetForegroundWindow(h); return; }
                    await Task.Delay(100);
                }
            });
            var ok = await verify;
            gate.Close();
            if (!ok) { Shutdown(); return; }
        }

        var mw = new UI.MainWindow();
        MainWindow = mw;
        ShutdownMode = ShutdownMode.OnMainWindowClose;
        mw.Show();
        mw.Activate();
    }

    private static void LogOnly(Exception ex)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CrashLog)!);
            File.AppendAllText(CrashLog,
                $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] UNOBSERVED {ex}\n\n");
        }
        catch { }
    }

    private static void Report(Exception ex, bool fatal = false)
    {
        var text = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {(fatal ? "FATAL " : "")}{ex}\n\n";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CrashLog)!);
            File.AppendAllText(CrashLog, text);
        }
        catch { /* хотя бы покажем */ }

        MessageBox.Show(
            ex.ToString() + "\n\nЗаписано в " + CrashLog,
            "QTerm — необработанная ошибка",
            MessageBoxButton.OK, MessageBoxImage.Error);
    }
}
