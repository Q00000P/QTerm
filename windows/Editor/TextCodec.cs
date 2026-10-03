using System.Text;
using System.Text.RegularExpressions;

namespace QEditor;

/// <summary>Кодировки и концы строк (меню «Кодировка» / «Формат» как у мобы).</summary>
public static class TextCodec
{
    public sealed record Enc(string Name, int CodePage, bool Bom);

    public static readonly Enc[] All =
    {
        new("UTF-8", 65001, false),
        new("UTF-8 с BOM", 65001, true),
        new("Windows-1251", 1251, false),
        new("KOI8-R", 20866, false),
        new("CP866 (DOS)", 866, false),
        new("Windows-1252", 1252, false),
        new("UTF-16 LE", 1200, true),
        new("UTF-16 BE", 1201, true),
    };

    public static Enc Utf8 => All[0];

    public static Encoding Get(Enc e) => e.CodePage switch
    {
        65001 => new UTF8Encoding(false),
        1200 => new UnicodeEncoding(false, false),
        1201 => new UnicodeEncoding(true, false),
        _ => Encoding.GetEncoding(e.CodePage),
    };

    /// <summary>BOM → строгий UTF-8 → Windows-1251 (типичный «не UTF-8» у нас).</summary>
    public static (string Text, Enc Enc) Decode(byte[] b)
    {
        if (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF)
            return (new UTF8Encoding(false).GetString(b, 3, b.Length - 3), All[1]);
        if (b.Length >= 2 && b[0] == 0xFF && b[1] == 0xFE)
            return (new UnicodeEncoding(false, false).GetString(b, 2, b.Length - 2), All[6]);
        if (b.Length >= 2 && b[0] == 0xFE && b[1] == 0xFF)
            return (new UnicodeEncoding(true, false).GetString(b, 2, b.Length - 2), All[7]);
        try { return (new UTF8Encoding(false, true).GetString(b), All[0]); }
        catch (DecoderFallbackException) { return (Encoding.GetEncoding(1251).GetString(b), All[2]); }
    }

    public static string DecodeAs(byte[] b, Enc e)
    {
        var enc = Get(e);
        var pre = enc.GetPreamble();
        int skip = 0;
        if (e.CodePage == 65001 && b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) skip = 3;
        else if (pre.Length > 0 && b.Length >= pre.Length && b.AsSpan(0, pre.Length).SequenceEqual(pre.AsSpan())) skip = pre.Length;
        else if (e.CodePage is 1200 or 1201 && b.Length >= 2 && (b[0] == 0xFF || b[0] == 0xFE)) skip = 2;
        return enc.GetString(b, skip, b.Length - skip);
    }

    public static byte[] Encode(string text, Enc e)
    {
        var body = Get(e).GetBytes(text);
        if (!e.Bom) return body;
        byte[] bom = e.CodePage switch
        {
            65001 => new byte[] { 0xEF, 0xBB, 0xBF },
            1200 => new byte[] { 0xFF, 0xFE },
            1201 => new byte[] { 0xFE, 0xFF },
            _ => Array.Empty<byte>(),
        };
        var outp = new byte[bom.Length + body.Length];
        bom.CopyTo(outp, 0);
        body.CopyTo(outp, bom.Length);
        return outp;
    }

    // ── Концы строк ──
    public const string LF = "\n", CRLF = "\r\n", CR = "\r";

    public static string DetectEol(string text)
    {
        int crlf = 0, lf = 0, cr = 0;
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '\r')
            {
                if (i + 1 < text.Length && text[i + 1] == '\n') { crlf++; i++; }
                else cr++;
            }
            else if (text[i] == '\n') lf++;
        }
        if (crlf == 0 && lf == 0 && cr == 0) return LF; // новый/однострочный — юникс
        if (crlf >= lf && crlf >= cr) return CRLF;
        return lf >= cr ? LF : CR;
    }

    public static string EolName(string eol) => eol switch { CRLF => "CRLF", CR => "CR", _ => "LF" };

    public static string NormalizeEol(string text, string eol) =>
        Regex.Replace(text, "\r\n|\r|\n", eol);
}
