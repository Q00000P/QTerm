namespace QTermWin;

/// <summary>Маркер волны — инкрементится в каждой поставке.
/// Заголовок окна не совпал с волной из чата = код не встал.</summary>
public static class WaveMarker
{
    public const string Wave = "32";

    public static string Version =>
        System.Reflection.Assembly.GetExecutingAssembly().GetName().Version is { } v
            ? $"{v.Major}.{v.Minor}.{v.Build}" : "?";
}
