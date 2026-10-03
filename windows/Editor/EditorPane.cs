using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ICSharpCode.AvalonEdit;
using ICSharpCode.AvalonEdit.Document;
using Microsoft.Win32;

namespace QEditor;

/// <summary>
/// Документ-вкладка на AvalonEdit: нумерация строк, подсветка, закладки,
/// кодировки/концы строк, операции над строками (канон MobaTextEditor).
/// Удалённый файл (нода) сохраняется через QTerm, локальный — на диск.
/// </summary>
public sealed class EditorPane : Grid
{
    public delegate Task<(bool Ok, string? Error, int Bytes)> RemoteSaver(byte[] data);
    public delegate Task<(byte[]? Data, string? Error)> RemoteLoader();

    private readonly RemoteSaver? _remoteSave;
    private readonly RemoteLoader? _remoteLoad;
    private byte[] _raw;                 // байты как на диске/ноде (для «открыть в кодировке»)
    private string _syntax = SyntaxRegistry.Plain;

    public TextEditor Editor { get; }
    public Bookmarks Marks { get; }
    public MatchRenderer Matches { get; } = new();

    public string? DocId { get; }
    public string? Node { get; }
    public string RemotePath { get; }
    public string? LocalPath { get; private set; }
    public bool IsLocal => _remoteSave is null;
    public bool IsReadOnlyView { get; }
    public TextCodec.Enc Encoding { get; private set; } = TextCodec.Utf8;
    public string Eol { get; private set; } = TextCodec.LF;
    public string Syntax => _syntax;
    public string Status { get; private set; } = "";

    public string FileName => LocalPath is { } lp ? Path.GetFileName(lp)
        : RemotePath[(RemotePath.LastIndexOf('/') + 1)..];
    public string Location => IsLocal ? (LocalPath ?? "не сохранён на диск") : $"{Node}: {RemotePath}";
    public bool Dirty => !Editor.Document.UndoStack.IsOriginalFile || _forceDirty;
    private bool _forceDirty;

    /// <summary>Что-то поменялось: грязность, имя, статус, кодировка — перерисовать вкладку/статус-бар.</summary>
    public event Action? StateChanged;

    private EditorPane(string remotePath, byte[] raw, string? docId, string? node,
        RemoteSaver? save, RemoteLoader? load, string? localPath, bool readOnly)
    {
        DocId = docId;
        Node = node;
        RemotePath = remotePath;
        LocalPath = localPath;
        _remoteSave = save;
        _remoteLoad = load;
        _raw = raw;
        IsReadOnlyView = readOnly;

        Editor = new TextEditor();
        Marks = new Bookmarks(Editor.Document);
        ApplyLook();
        Children.Add(Editor);

        var (text, enc) = TextCodec.Decode(raw);
        Encoding = enc;
        LoadText(text);
        SetSyntax(SyntaxRegistry.Detect(localPath ?? remotePath, text));
        Editor.IsReadOnly = readOnly;

        Editor.Document.UndoStack.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(UndoStack.IsOriginalFile)) StateChanged?.Invoke();
        };
        Editor.TextArea.TextView.BackgroundRenderers.Add(Marks);
        Editor.TextArea.TextView.BackgroundRenderers.Add(Matches);
        Editor.TextArea.LeftMargins.Insert(0, new BookmarkMargin(Marks));
        Marks.Changed += () => Editor.TextArea.TextView.InvalidateLayer(ICSharpCode.AvalonEdit.Rendering.KnownLayer.Background);
    }

    public static EditorPane Remote(string docId, string node, string path, byte[] raw,
        RemoteSaver save, RemoteLoader load) =>
        new(path, raw, docId, node, save, load, null, false);

    public static EditorPane Local(string? localPath, byte[] raw, string untitledName) =>
        new(untitledName, raw, null, null, null, null, localPath, false);

    public static EditorPane View(string title, string text, string syntax)
    {
        var p = new EditorPane(title, new UTF8Encoding(false).GetBytes(text), null, null, null, null, null, true);
        p.SetSyntax(syntax);
        return p;
    }

    // ── Внешний вид (тёмная тема, как всё приложение) ──
    private void ApplyLook()
    {
        var e = Editor;
        e.FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New");
        e.FontSize = EditorSettings.Current.FontSize;
        e.Padding = new Thickness(4, 2, 0, 0);
        e.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        e.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        var ta = e.TextArea;
        ta.SelectionForeground = null;       // цвета подсветки внутри выделения сохраняются
        ta.SelectionBorder = null;
        ta.SelectionCornerRadius = 2;
        ApplyThemeColors();
        e.Options.EnableHyperlinks = true;
        e.Options.RequireControlModifierForHyperlinkClick = true;
        e.Options.EnableRectangularSelection = true;   // Alt+мышь — столбцом, как в мобе
        e.Options.AllowScrollBelowDocument = true;
        e.Options.CutCopyWholeLine = true;
        ApplySettings(EditorSettings.Current);
        // Ctrl+колесо — масштаб
        e.PreviewMouseWheel += (_, a) =>
        {
            if (Keyboard.Modifiers != ModifierKeys.Control) return;
            Zoom(a.Delta > 0 ? 1 : -1);
            a.Handled = true;
        };
    }

    private static SolidColorBrush C(byte r, byte g, byte b, byte a = 0xFF) => new(Color.FromArgb(a, r, g, b));

    /// <summary>Цвета текстовой области под тему (тёмная — как VS Code Dark+, светлая — Light+).</summary>
    private void ApplyThemeColors()
    {
        var light = QTermShared.ThemeManager.IsLight;
        var e = Editor;
        var ta = e.TextArea;
        var tv = ta.TextView;
        if (light)
        {
            e.Background = C(0xFF, 0xFF, 0xFF);
            e.Foreground = C(0x1F, 0x1F, 0x1F);
            e.LineNumbersForeground = C(0x8A, 0x90, 0x99);
            ta.SelectionBrush = C(0xAD, 0xD6, 0xFF);
            ta.Caret.CaretBrush = C(0x00, 0x67, 0xC0);
            tv.CurrentLineBackground = C(0xF2, 0xF6, 0xFA);
            tv.CurrentLineBorder = new Pen(C(0xE4, 0xE8, 0xEC), 1);
            tv.NonPrintableCharacterBrush = C(0xB8, 0xBC, 0xC2);
            tv.LinkTextForegroundBrush = C(0x00, 0x67, 0xC0);
            tv.ColumnRulerPen = new Pen(C(0xE0, 0xE3, 0xE7), 1);
        }
        else
        {
            e.Background = C(0x1E, 0x1F, 0x22);
            e.Foreground = C(0xD4, 0xD4, 0xD4);
            e.LineNumbersForeground = C(0x6E, 0x76, 0x81);
            ta.SelectionBrush = C(0x26, 0x4F, 0x78, 0xB0);
            ta.Caret.CaretBrush = C(0x4F, 0xA3, 0xE3);
            tv.CurrentLineBackground = C(0x3A, 0x3F, 0x47, 0x40);
            tv.CurrentLineBorder = new Pen(C(0x3A, 0x3F, 0x47, 0x60), 1);
            tv.NonPrintableCharacterBrush = C(0x4A, 0x50, 0x58);
            tv.LinkTextForegroundBrush = C(0x4F, 0xA3, 0xE3);
            tv.ColumnRulerPen = new Pen(C(0x34, 0x37, 0x3D), 1);
        }
    }

    /// <summary>Тема сменилась: цвета текста + подсветка синтаксиса в варианте темы.</summary>
    public void ApplyTheme()
    {
        ApplyThemeColors();
        Editor.SyntaxHighlighting = SyntaxRegistry.Get(_syntax);
        Editor.TextArea.TextView.Redraw();
    }

    public void ApplySettings(EditorSettings s)
    {
        Editor.ShowLineNumbers = s.LineNumbers;
        Editor.WordWrap = s.WordWrap;
        var o = Editor.Options;
        o.ShowSpaces = s.ShowWhitespace;
        o.ShowTabs = s.ShowWhitespace;
        o.ShowEndOfLine = s.ShowEol;
        o.HighlightCurrentLine = s.HighlightLine;
        o.ShowColumnRuler = s.ColumnRuler;
        o.ColumnRulerPosition = 80;
        o.IndentationSize = s.TabSize;
        o.ConvertTabsToSpaces = s.UseSpaces;
    }

    public void Zoom(int step)
    {
        var size = step == 0 ? 13.5 : Math.Clamp(Editor.FontSize + step, 8, 40);
        Editor.FontSize = size;
        EditorSettings.Current.FontSize = size;
        EditorSettings.Save();
        StateChanged?.Invoke();
    }

    private void LoadText(string text)
    {
        Eol = TextCodec.DetectEol(text);
        Editor.Document.Text = text;
        Editor.Document.UndoStack.ClearAll();
        Editor.Document.UndoStack.MarkAsOriginalFile();
        _forceDirty = false;
        Editor.ScrollToHome();
        Editor.TextArea.Caret.Offset = 0;
    }

    public void SetSyntax(string name)
    {
        _syntax = name;
        Editor.SyntaxHighlighting = SyntaxRegistry.Get(name);
        StateChanged?.Invoke();
    }

    public void FocusEditor() => Editor.TextArea.Focus();

    private void SetStatus(string s) { Status = s; StateChanged?.Invoke(); }

    // ── Сохранение ──
    /// <summary>Концы строк при сохранении приводятся к выбранным (Eol): AvalonEdit
    /// в однострочном/пустом документе ставит Windows-перевод, а на ноду он
    /// уехать не должен — конфиги с CRLF ломаются.</summary>
    private byte[] BytesForSave() =>
        TextCodec.Encode(TextCodec.NormalizeEol(Editor.Document.Text, Eol), Encoding);

    private bool _saving;

    public async Task<bool> SaveAsync()
    {
        if (IsReadOnlyView || _saving) return false;
        if (IsLocal)
        {
            if (LocalPath is null) return SaveAs();
            return WriteLocal(LocalPath);
        }
        _saving = true;
        SetStatus("Сохранение на ноду…");
        var data = BytesForSave();
        var (ok, err, bytes) = await _remoteSave!(data);
        _saving = false;
        if (!ok) { SetStatus("Ошибка: " + err); return false; }
        _raw = data;
        Editor.Document.UndoStack.MarkAsOriginalFile();
        _forceDirty = false;
        SetStatus($"Сохранено {DateTime.Now:HH:mm:ss} · {bytes} байт");
        return true;
    }

    /// <summary>Локальный — привязать к файлу; удалённый — КОПИЯ на диск без отвязки от ноды.</summary>
    public bool SaveAs()
    {
        var dlg = new SaveFileDialog
        {
            Title = IsLocal ? "Сохранить на диск" : "Сохранить копию на диск",
            FileName = FileName.StartsWith("Без имени") ? "snippet.txt" : FileName,
            Filter = "Все файлы (*.*)|*.*|Текст (*.txt)|*.txt",
        };
        if (dlg.ShowDialog(Window.GetWindow(this)) != true) return false;
        if (IsLocal)
        {
            LocalPath = dlg.FileName;
            if (_syntax == SyntaxRegistry.Plain) SetSyntax(SyntaxRegistry.Detect(LocalPath, Editor.Document.Text));
            var ok = WriteLocal(LocalPath);
            EditorSettings.AddRecent(LocalPath);
            return ok;
        }
        try
        {
            File.WriteAllBytes(dlg.FileName, BytesForSave());
            SetStatus($"Копия записана: {dlg.FileName}");
            return true;
        }
        catch (Exception ex) { SetStatus("Ошибка: " + ex.Message); return false; }
    }

    private bool WriteLocal(string path)
    {
        try
        {
            var data = BytesForSave();
            File.WriteAllBytes(path, data);
            _raw = data;
            Editor.Document.UndoStack.MarkAsOriginalFile();
            _forceDirty = false;
            SetStatus($"Записано {DateTime.Now:HH:mm:ss}");
            return true;
        }
        catch (Exception ex) { SetStatus("Ошибка: " + ex.Message); return false; }
    }

    /// <summary>Перечитать: локальный — с диска, удалённый — с ноды через QTerm.</summary>
    public async Task ReloadAsync()
    {
        if (IsReadOnlyView) return;
        if (Dirty && !Confirm($"«{FileName}»: несохранённые правки пропадут. Перечитать?")) return;
        byte[]? data = null;
        if (IsLocal)
        {
            if (LocalPath is null) return;
            try { data = File.ReadAllBytes(LocalPath); }
            catch (Exception ex) { SetStatus("Ошибка: " + ex.Message); return; }
        }
        else
        {
            SetStatus("Перечитываю с ноды…");
            var (d, err) = await _remoteLoad!();
            if (d is null) { SetStatus("Ошибка: " + err); return; }
            data = d;
        }
        var line = Editor.TextArea.Caret.Line;
        _raw = data;
        var (text, enc) = TextCodec.Decode(data);
        Encoding = enc;
        LoadText(text);
        GoToLine(Math.Min(line, Editor.Document.LineCount));
        SetStatus($"Перечитано {DateTime.Now:HH:mm:ss}");
    }

    /// <summary>Откат к сохранённому (Ctrl+Alt+Z).</summary>
    public void Revert()
    {
        if (!Dirty) return;
        LoadText(TextCodec.DecodeAs(_raw, Encoding));
        SetStatus("Изменения отменены");
    }

    // ── Кодировка / концы строк ──
    public void ReopenAs(TextCodec.Enc enc)
    {
        if (Dirty && !Confirm("Несохранённые правки пропадут. Открыть заново в другой кодировке?")) return;
        Encoding = enc;
        LoadText(TextCodec.DecodeAs(_raw, enc));
        SetStatus($"Открыто как {enc.Name}");
    }

    public void SaveEncoding(TextCodec.Enc enc)
    {
        Encoding = enc;
        _forceDirty = true;
        SetStatus($"Будет сохранено в {enc.Name}");
    }

    public void ConvertEol(string eol)
    {
        var doc = Editor.Document;
        var text = TextCodec.NormalizeEol(doc.Text, eol);
        if (text == doc.Text) { Eol = eol; StateChanged?.Invoke(); return; }
        doc.Replace(0, doc.TextLength, text); // одна операция — один шаг отмены
        Eol = eol;
        SetStatus($"Концы строк: {TextCodec.EolName(eol)}");
    }

    // ── Навигация и закладки ──
    public void GoToLine(int line)
    {
        line = Math.Clamp(line, 1, Editor.Document.LineCount);
        var dl = Editor.Document.GetLineByNumber(line);
        Editor.TextArea.Caret.Offset = dl.Offset;
        Editor.ScrollToLine(line);
        FocusEditor();
    }

    public int CaretLine => Editor.TextArea.Caret.Line;

    public void ToggleBookmark() => Marks.Toggle(CaretLine);

    public void NextBookmark(bool back)
    {
        var lines = Marks.Lines.ToList();
        if (lines.Count == 0) return;
        var cur = CaretLine;
        int target = back
            ? lines.LastOrDefault(l => l < cur, lines[^1])
            : lines.FirstOrDefault(l => l > cur, lines[0]);
        GoToLine(target);
    }

    public string LinePreview(int line)
    {
        var dl = Editor.Document.GetLineByNumber(line);
        var t = Editor.Document.GetText(dl).Trim();
        return t.Length > 60 ? t[..60] + "…" : t;
    }

    // ── Операции над строками ──
    private (int First, int Last) SelectedLines()
    {
        var doc = Editor.Document;
        var ta = Editor.TextArea;
        if (ta.Selection.IsEmpty) return (ta.Caret.Line, ta.Caret.Line);
        var start = doc.GetLineByOffset(Editor.SelectionStart).LineNumber;
        var endOff = Editor.SelectionStart + Editor.SelectionLength;
        var endLine = doc.GetLineByOffset(endOff);
        var last = endLine.LineNumber;
        // выделение, закончившееся в начале строки, эту строку не захватывает
        if (last > start && endOff == endLine.Offset) last--;
        return (start, last);
    }

    private void EditLines(Func<List<string>, List<string>> transform)
    {
        var doc = Editor.Document;
        var (a, b) = SelectedLines();
        var first = doc.GetLineByNumber(a);
        var last = doc.GetLineByNumber(b);
        var start = first.Offset;
        var len = last.EndOffset - start;
        var lines = Enumerable.Range(a, b - a + 1).Select(n => doc.GetText(doc.GetLineByNumber(n))).ToList();
        var outLines = transform(lines);
        var text = string.Join(Eol, outLines);
        doc.Replace(start, len, text);
        Editor.Select(start, text.Length);
    }

    private string IndentUnit => EditorSettings.Current.UseSpaces ? new string(' ', EditorSettings.Current.TabSize) : "\t";

    public void Indent() => EditLines(ls => ls.Select(l => l.Length == 0 ? l : IndentUnit + l).ToList());

    public void Unindent() => EditLines(ls => ls.Select(l =>
    {
        if (l.StartsWith('\t')) return l[1..];
        int n = 0;
        while (n < l.Length && n < EditorSettings.Current.TabSize && l[n] == ' ') n++;
        return l[n..];
    }).ToList());

    /// <summary>Закомментировать строки префиксом (для &lt;!-- — обернуть блок).</summary>
    public void Comment(string prefix)
    {
        if (prefix == "<!--")
        {
            EditLines(ls => { ls[0] = "<!-- " + ls[0]; ls[^1] = ls[^1] + " -->"; return ls; });
            return;
        }
        EditLines(ls =>
        {
            var indent = ls.Where(l => l.Trim().Length > 0)
                .Select(l => l.Length - l.TrimStart().Length).DefaultIfEmpty(0).Min();
            return ls.Select(l => l.Trim().Length == 0 ? l : l[..indent] + prefix + " " + l[indent..]).ToList();
        });
    }

    public void Uncomment(string prefix)
    {
        if (prefix == "<!--")
        {
            EditLines(ls =>
            {
                ls[0] = Regex.Replace(ls[0], @"<!--\s?", "");
                ls[^1] = Regex.Replace(ls[^1], @"\s?-->", "");
                return ls;
            });
            return;
        }
        var rx = new Regex(@"^(\s*)" + Regex.Escape(prefix) + @" ?");
        EditLines(ls => ls.Select(l => rx.Replace(l, "$1", 1)).ToList());
    }

    /// <summary>Ctrl+/ — все выделенные строки закомментированы → снять, иначе поставить.</summary>
    public void ToggleComment()
    {
        var prefix = SyntaxRegistry.CommentPrefix(_syntax);
        var (a, b) = SelectedLines();
        var doc = Editor.Document;
        var all = Enumerable.Range(a, b - a + 1)
            .Select(n => doc.GetText(doc.GetLineByNumber(n)).TrimStart())
            .Where(t => t.Length > 0)
            .All(t => t.StartsWith(prefix));
        if (all) Uncomment(prefix); else Comment(prefix);
    }

    public void DuplicateLines()
    {
        var doc = Editor.Document;
        var (a, b) = SelectedLines();
        var first = doc.GetLineByNumber(a);
        var last = doc.GetLineByNumber(b);
        var block = doc.GetText(first.Offset, last.EndOffset - first.Offset);
        doc.Insert(last.EndOffset, Eol + block);
        Editor.TextArea.Caret.Line = b + 1 + (Editor.TextArea.Caret.Line - a);
    }

    public void DeleteLines()
    {
        var doc = Editor.Document;
        var (a, b) = SelectedLines();
        var first = doc.GetLineByNumber(a);
        var last = doc.GetLineByNumber(b);
        int start = first.Offset, end = last.EndOffset + last.DelimiterLength;
        if (last.DelimiterLength == 0 && a > 1) // последняя строка — съесть перевод перед ней
        {
            var prev = doc.GetLineByNumber(a - 1);
            start = prev.EndOffset;
        }
        doc.Remove(start, end - start);
    }

    public void MoveLines(bool up)
    {
        var doc = Editor.Document;
        var (a, b) = SelectedLines();
        if (up && a == 1 || !up && b == doc.LineCount) return;
        using (doc.RunUpdate())
        {
            var first = doc.GetLineByNumber(a);
            var last = doc.GetLineByNumber(b);
            var block = doc.GetText(first.Offset, last.EndOffset - first.Offset);
            if (up)
            {
                var prev = doc.GetLineByNumber(a - 1);
                var prevText = doc.GetText(prev);
                doc.Replace(prev.Offset, last.EndOffset - prev.Offset, block + Eol + prevText);
                var nf = doc.GetLineByNumber(a - 1);
                Editor.Select(nf.Offset, block.Length);
            }
            else
            {
                var next = doc.GetLineByNumber(b + 1);
                var nextText = doc.GetText(next);
                doc.Replace(first.Offset, next.EndOffset - first.Offset, nextText + Eol + block);
                var nf = doc.GetLineByNumber(a + 1);
                Editor.Select(nf.Offset, block.Length);
            }
        }
    }

    public void SortLines(bool desc) => EditLines(ls =>
    {
        var s = ls.OrderBy(l => l, StringComparer.CurrentCultureIgnoreCase).ToList();
        if (desc) s.Reverse();
        return s;
    });

    public void UniqueLines() => EditLines(ls => ls.Distinct().ToList());
    public void TrimTrailing() => EditLines(ls => ls.Select(l => l.TrimEnd()).ToList());
    public void JoinLines() => EditLines(ls => new List<string> { string.Join(" ", ls.Select(l => l.Trim())) });
    public void TabsToSpaces() => EditLines(ls => ls.Select(l => l.Replace("\t", new string(' ', EditorSettings.Current.TabSize))).ToList());
    public void SpacesToTabs()
    {
        var unit = new string(' ', EditorSettings.Current.TabSize);
        EditLines(ls => ls.Select(l =>
        {
            int i = 0; var sb = new StringBuilder();
            while (l.Length - i >= unit.Length && l.Substring(i, unit.Length) == unit) { sb.Append('\t'); i += unit.Length; }
            return sb + l[i..];
        }).ToList());
    }

    /// <summary>Преобразовать выделение (или весь текст, если выделения нет).</summary>
    public void TransformSelection(Func<string, string> f, string what)
    {
        var doc = Editor.Document;
        int start = Editor.SelectionLength > 0 ? Editor.SelectionStart : 0;
        int len = Editor.SelectionLength > 0 ? Editor.SelectionLength : doc.TextLength;
        string res;
        try { res = f(doc.GetText(start, len)); }
        catch (Exception ex) { SetStatus($"{what}: {ex.Message}"); return; }
        doc.Replace(start, len, res);
        Editor.Select(start, res.Length);
        SetStatus(what);
    }

    public string SelectionOrAll() =>
        Editor.SelectionLength > 0 ? Editor.SelectedText : Editor.Document.Text;

    public void InsertAtCaret(string s)
    {
        Editor.Document.Replace(Editor.SelectionStart, Editor.SelectionLength, s);
        FocusEditor();
    }

    // ── Спец-инструменты ──
    public static string ToBase64(string s) => Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(s));
    public static string FromBase64(string s) =>
        System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(Regex.Replace(s, @"\s", "")));
    public static string JsonPretty(string s) =>
        JsonSerializer.Serialize(JsonDocument.Parse(s).RootElement,
            new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    public static string JsonMinify(string s) =>
        JsonSerializer.Serialize(JsonDocument.Parse(s).RootElement,
            new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    public static string Hash(string s, string alg)
    {
        var b = System.Text.Encoding.UTF8.GetBytes(s);
        byte[] h = alg switch
        {
            "MD5" => MD5.HashData(b),
            "SHA-1" => SHA1.HashData(b),
            "SHA-512" => SHA512.HashData(b),
            _ => SHA256.HashData(b),
        };
        return Convert.ToHexString(h).ToLowerInvariant();
    }

    public bool TryClose() =>
        IsReadOnlyView || !Dirty || Confirm(IsLocal
            ? $"«{FileName}»: не сохранён. Закрыть без сохранения?"
            : $"«{FileName}» ({Node}): есть несохранённые правки. Закрыть без сохранения?");

    private bool Confirm(string text) =>
        MessageBox.Show(Window.GetWindow(this), text, "QEditor", MessageBoxButton.YesNo,
            MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;
}
