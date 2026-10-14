using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace QTermShared;

/// <summary>
/// Зависшие копии QEditor. Живой QEditor своё окно не прячет никогда; копия без единого видимого окна —
/// это процесс, у которого WPF упал при закрытии окна (исключение в Application.CriticalShutdown, например
/// FileNotFoundException System.Diagnostics.Tracing из телеметрии WPF), а процесс остался жить вместе
/// с сервером канала. Такая копия перехватывает ВСЕ запуски редактора (вторая копия отдаёт ей файлы
/// и выходит, QTerm шлёт ей open) — снаружи «тупо ничего, ошибок нет».
/// Её убирают и QEditor при старте, и QTerm перед отправкой файла. Свежий процесс (моложе 30 с) не трогаем —
/// он может ещё не успеть показать окно.
/// </summary>
public static class EditorProcess
{
    public const string ExeName = "QEditor";
    private static readonly TimeSpan Grace = TimeSpan.FromSeconds(30);

    /// <summary>Журнал QEditor (падения, убитые зависшие копии) — общий для QEditor и QTerm.</summary>
    public static string LogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm", "editor-crash.log");

    public static void Note(string text)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {text}\n\n");
        }
        catch { }
    }

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    /// <summary>Есть ли у процесса хоть одно видимое окно верхнего уровня (свёрнутое и на другом рабочем столе — тоже видимое).</summary>
    public static bool HasVisibleWindow(int pid)
    {
        var found = false;
        EnumWindows((h, _) =>
        {
            GetWindowThreadProcessId(h, out var wp);
            if (wp != (uint)pid || !IsWindowVisible(h)) return true;
            found = true;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    /// <summary>Убить зависшие копии QEditor этого сеанса (кроме себя). Возвращает, сколько убито; каждое — в журнал.</summary>
    public static int KillZombies(string who)
    {
        var killed = 0;
        try
        {
            using var me = Process.GetCurrentProcess();
            foreach (var p in Process.GetProcessesByName(ExeName))
            {
                using (p)
                {
                    try
                    {
                        if (p.Id == me.Id || p.SessionId != me.SessionId) continue;
                        var started = p.StartTime;
                        if (DateTime.Now - started < Grace) continue;
                        if (HasVisibleWindow(p.Id)) continue;
                        p.Kill();
                        p.WaitForExit(3000);
                        killed++;
                        Note($"{who}: убита зависшая копия QEditor (pid {p.Id}, запущена {started:dd.MM HH:mm:ss}) — окна нет, " +
                             "а канал редактора держала она: запуски редактора уходили в пустоту");
                    }
                    catch (Exception ex) { Note($"{who}: копию QEditor pid {p.Id} убрать не вышло: {ex.Message}"); }
                }
            }
        }
        catch { /* список процессов недоступен — работаем как раньше */ }
        return killed;
    }
}
