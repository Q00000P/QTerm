using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using ICSharpCode.AvalonEdit.Document;
using ICSharpCode.AvalonEdit.Editing;
using ICSharpCode.AvalonEdit.Rendering;

namespace QEditor;

/// <summary>Подсветка всех найденных совпадений (строка поиска).</summary>
public sealed class MatchRenderer : IBackgroundRenderer
{
    public List<TextSegment> Matches { get; } = new();
    private static readonly Brush Fill = Freeze(new SolidColorBrush(Color.FromArgb(0x70, 0x9E, 0x6A, 0x03)));
    private static readonly Pen Edge = FreezePen(new Pen(new SolidColorBrush(Color.FromArgb(0xC0, 0xD7, 0xBA, 0x7D)), 1));

    public KnownLayer Layer => KnownLayer.Selection;

    public void Draw(TextView textView, DrawingContext dc)
    {
        if (Matches.Count == 0 || !textView.VisualLinesValid) return;
        var lines = textView.VisualLines;
        if (lines.Count == 0) return;
        int from = lines[0].FirstDocumentLine.Offset;
        int to = lines[^1].LastDocumentLine.EndOffset;
        foreach (var m in Matches)
        {
            if (m.EndOffset < from) continue;
            if (m.StartOffset > to) break;
            foreach (var r in BackgroundGeometryBuilder.GetRectsForSegment(textView, m))
                dc.DrawRoundedRectangle(Fill, Edge, r, 2, 2);
        }
    }

    internal static Brush Freeze(Brush b) { b.Freeze(); return b; }
    internal static Pen FreezePen(Pen p) { p.Freeze(); return p; }
}

/// <summary>Закладки: маркер на полях + подсветка строки. Якоря TextAnchor
/// едут вместе с текстом при правках.</summary>
public sealed class Bookmarks : IBackgroundRenderer
{
    private readonly TextDocument _doc;
    public List<TextAnchor> Anchors { get; } = new();
    public event Action? Changed;
    private static readonly Brush LineFill = MatchRenderer.Freeze(new SolidColorBrush(Color.FromArgb(0x38, 0x4F, 0xA3, 0xE3)));

    public Bookmarks(TextDocument doc) { _doc = doc; }

    public KnownLayer Layer => KnownLayer.Background;

    public IEnumerable<int> Lines =>
        Anchors.Where(a => !a.IsDeleted).Select(a => a.Line).Distinct().OrderBy(l => l);

    public bool Has(int line) => Anchors.Any(a => !a.IsDeleted && a.Line == line);

    public void Toggle(int line)
    {
        var hit = Anchors.Where(a => !a.IsDeleted && a.Line == line).ToList();
        if (hit.Count > 0) foreach (var a in hit) Anchors.Remove(a);
        else
        {
            var anchor = _doc.CreateAnchor(_doc.GetLineByNumber(line).Offset);
            anchor.MovementType = AnchorMovementType.BeforeInsertion;
            Anchors.Add(anchor);
        }
        Changed?.Invoke();
    }

    public void Clear() { Anchors.Clear(); Changed?.Invoke(); }

    public void Draw(TextView textView, DrawingContext dc)
    {
        if (!textView.VisualLinesValid) return;
        var set = Lines.ToHashSet();
        if (set.Count == 0) return;
        foreach (var vl in textView.VisualLines)
        {
            if (!set.Contains(vl.FirstDocumentLine.LineNumber)) continue;
            var y = vl.VisualTop - textView.VerticalOffset;
            dc.DrawRectangle(LineFill, null, new Rect(0, y, textView.ActualWidth, vl.Height));
        }
    }
}

/// <summary>Поле закладок слева от номеров строк: клик ставит/снимает.</summary>
public sealed class BookmarkMargin : AbstractMargin
{
    private readonly Bookmarks _marks;
    private static readonly Brush Dot = MatchRenderer.Freeze(new SolidColorBrush(Color.FromRgb(0x4F, 0xA3, 0xE3)));

    public BookmarkMargin(Bookmarks marks)
    {
        _marks = marks;
        _marks.Changed += InvalidateVisual;
        Cursor = Cursors.Hand;
        ToolTip = "Закладка (Ctrl+F2)";
    }

    protected override Size MeasureOverride(Size availableSize) => new(16, 0);

    protected override void OnTextViewChanged(TextView? oldTextView, TextView? newTextView)
    {
        if (oldTextView is not null) oldTextView.VisualLinesChanged -= OnVisualLinesChanged;
        base.OnTextViewChanged(oldTextView, newTextView);
        if (newTextView is not null) newTextView.VisualLinesChanged += OnVisualLinesChanged;
        InvalidateVisual();
    }

    private void OnVisualLinesChanged(object? sender, EventArgs e) => InvalidateVisual();

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize)); // клики по всей ширине
        var tv = TextView;
        if (tv is null || !tv.VisualLinesValid) return;
        var set = _marks.Lines.ToHashSet();
        if (set.Count == 0) return;
        foreach (var vl in tv.VisualLines)
        {
            if (!set.Contains(vl.FirstDocumentLine.LineNumber)) continue;
            var y = vl.VisualTop - tv.VerticalOffset + vl.Height / 2;
            dc.DrawEllipse(Dot, null, new Point(8, y), 4.5, 4.5);
        }
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        var tv = TextView;
        if (tv is null) return;
        var y = e.GetPosition(tv).Y + tv.VerticalOffset;
        var vl = tv.GetVisualLineFromVisualTop(y);
        if (vl is null) return;
        _marks.Toggle(vl.FirstDocumentLine.LineNumber);
        e.Handled = true;
    }
}
