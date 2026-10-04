using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using QTermWin.Models;
using QTermWin.Vault;

namespace QTermWin.UI;

/// <summary>
/// Ключ текстом из буфера → в вейлт (файл не нужен): имя + сам ключ. PPK конвертируется в OpenSSH,
/// одинаковый ключ второй раз не заводится. Уезжает синком, как импорт из файла.
/// </summary>
public static class KeyPasteDialog
{
    /// <summary>Похоже на приватный ключ (OpenSSH/PEM/PPK)?</summary>
    public static bool LooksLikeKey(string? text) =>
        !string.IsNullOrWhiteSpace(text) &&
        (text.Contains("PRIVATE KEY-----") || Security.PpkConverter.LooksLikePpk(text));

    /// <summary>Текст ключа → OpenSSH/PEM для вейлта (PPK — конвертация с passphrase). null — отказ, причина в error.</summary>
    public static string? Normalize(Window owner, string raw, string label, out string? error)
    {
        error = null;
        var text = raw.Replace("\r\n", "\n").Replace('\r', '\n').Trim() + "\n";
        if (Security.PpkConverter.LooksLikePpk(text))
        {
            string? pass = null;
            if (!text.Contains("Encryption: none"))
            {
                (pass, _) = PasswordDialog.AskEx(owner, $"Passphrase PPK «{label}»", withSave: false);
                if (pass is null) { error = "отменено"; return null; }
            }
            try { return Security.PpkConverter.Convert(text, pass); }
            catch (Security.PpkConverter.BadPassphraseException) { error = "passphrase не подошла (MAC не сошёлся)"; return null; }
            catch (Exception ex) { error = "PPK: " + ex.Message; return null; }
        }
        if (Regex.IsMatch(text, @"^\S+\s+AAAA[0-9A-Za-z+/]{20}", RegexOptions.Multiline) ||
            text.Contains("BEGIN SSH2 PUBLIC KEY") || text.Contains("PUBLIC KEY-----"))
        {
            error = "Это ПУБЛИЧНЫЙ ключ (строка «ssh-ed25519 AAAA…» — она лежит на сервере в authorized_keys). Для входа нужен ПРИВАТНЫЙ: файл без .pub (id_ed25519), текст от «-----BEGIN OPENSSH PRIVATE KEY-----» до «-----END OPENSSH PRIVATE KEY-----».";
            return null;
        }
        if (!text.Contains("PRIVATE KEY-----"))
        {
            error = "это не приватный ключ: нужен текст от «-----BEGIN … PRIVATE KEY-----» до «-----END … PRIVATE KEY-----» (или .ppk)";
            return null;
        }
        return text;
    }

    /// <summary>Окно «имя + ключ». Возвращает ключ в вейлте (новый или уже лежавший такой же) или null.</summary>
    public static SSHKey? Show(Window owner, VaultRepo repo, string defaultName = "")
    {
        SSHKey? result = null;
        var w = new Window
        {
            Title = "Ключ из буфера", Owner = owner, Width = 560, SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        w.SetResourceReference(Window.BackgroundProperty, "BgBrush");
        w.SetResourceReference(Window.ForegroundProperty, "FgBrush");

        TextBlock Cap(string t)
        {
            var c = new TextBlock { Text = t, Margin = new Thickness(0, 8, 0, 3), TextWrapping = TextWrapping.Wrap };
            c.SetResourceReference(TextBlock.ForegroundProperty, "DimBrush");
            return c;
        }

        var root = new StackPanel { Margin = new Thickness(18) };
        root.Children.Add(Cap("Имя ключа"));
        var nameBox = new TextBox { Padding = new Thickness(6), Text = defaultName };
        root.Children.Add(nameBox);
        root.Children.Add(Cap("Приватный ключ (OpenSSH / PEM / PuTTY .ppk) — вставь текст целиком"));
        var keyBox = new TextBox
        {
            Padding = new Thickness(6), AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Height = 220,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
        };
        try { var clip = Clipboard.GetText(); if (LooksLikeKey(clip)) keyBox.Text = clip.Trim(); } catch { }
        root.Children.Add(keyBox);
        var status = new TextBox
        {
            IsReadOnly = true, BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0),
            Text = keyBox.Text.Length > 0 ? "Ключ взят из буфера." : "В буфере ключа нет — вставь его в поле (Ctrl+V).",
        };
        status.SetResourceReference(Control.ForegroundProperty, "DimBrush");
        root.Children.Add(status);

        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        var paste = new Button { Content = "Вставить из буфера", MinWidth = 140, Margin = new Thickness(0, 0, 8, 0) };
        var save = new Button { Content = "Сохранить в вейлт", MinWidth = 140, IsDefault = true };
        var cancel = new Button { Content = "Отмена", MinWidth = 100, Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        paste.Click += (_, _) =>
        {
            try { keyBox.Text = Clipboard.GetText().Trim(); status.Text = LooksLikeKey(keyBox.Text) ? "Ключ взят из буфера." : "В буфере не ключ."; }
            catch (Exception ex) { status.Text = ex.Message; }
        };
        save.Click += (_, _) =>
        {
            var name = nameBox.Text.Trim();
            if (name.Length == 0) { status.Text = "Нужно имя ключа"; nameBox.Focus(); return; }
            var text = Normalize(w, keyBox.Text, name, out var err);
            if (text is null) { status.Text = "✗ " + err; return; }
            repo.Data.SshKeys ??= new();
            var same = repo.Data.SshKeys.FirstOrDefault(k => k.Deleted != true && k.PrivateKey.Trim() == text.Trim());
            if (same is not null)
            {
                MessageBox.Show(w, $"Такой ключ уже в вейлте: «{same.Name}» — выбран он.", "QTerm");
                result = same;
                w.Close();
                return;
            }
            var key = new SSHKey { Name = name, PrivateKey = text, UpdatedAt = QtJson.NowIso() };
            repo.Data.SshKeys.Add(key);
            repo.Persist();
            result = key;
            w.Close();
        };
        cancel.Click += (_, _) => w.Close();
        row.Children.Add(paste);
        row.Children.Add(save);
        row.Children.Add(cancel);
        root.Children.Add(row);
        w.Content = root;
        w.Loaded += (_, _) => { if (nameBox.Text.Length == 0) nameBox.Focus(); else keyBox.Focus(); };
        w.ShowDialog();
        return result;
    }
}
