using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using Microsoft.Win32;
using Renci.SshNet;
using SshNet.Agent;
using Renci.SshNet.Common;
using QTermWin.Models;
using QTermWin.Vault;

namespace QTermWin.UI;

/// <summary>Экран ключей: отпечатки, authorized_keys, импорт файла, tombstone-удаление.
/// 🔒 = зашифрованный ключ, метаданные после passphrase (не сохраняется).</summary>
public partial class KeysWindow : Window
{
    private readonly VaultRepo _repo;

    private sealed record Row(Guid Id, string Name, string Type, string Fp, string? PubLine);

    public KeysWindow(VaultRepo repo)
    {
        InitializeComponent();
        _repo = repo;
        Refresh();
    }

    private static (string Type, string Fp, string Pub)? TryMeta(string keyText, string? passphrase, string name)
    {
        try
        {
            using var ms = new MemoryStream(Encoding.UTF8.GetBytes(keyText));
            var pk = passphrase is null ? new PrivateKeyFile(ms) : new PrivateKeyFile(ms, passphrase);
            var alg = pk.HostKeyAlgorithms.First();
            var blob = alg.Data;
            var fp = "SHA256:" + Convert.ToBase64String(SHA256.HashData(blob)).TrimEnd('=');
            return (alg.Name, fp, $"{alg.Name} {Convert.ToBase64String(blob)} {name}");
        }
        catch { return null; }
    }

    private void Refresh()
    {
        var rows = new List<Row>();
        foreach (var k in (_repo.Data.SshKeys ?? new()).Where(k => k.Deleted != true)
                     .OrderBy(k => k.Name, StringComparer.OrdinalIgnoreCase))
        {
            var meta = TryMeta(k.PrivateKey, null, k.Name);
            rows.Add(meta is { } m
                ? new Row(k.Id, k.Name, m.Type, m.Fp, m.Pub)
                : new Row(k.Id, k.Name, "🔒", "зашифрован — выбери и жми «Копировать…» для ввода passphrase", null));
        }
        KeyList.ItemsSource = rows;
    }

    private Row? Selected => KeyList.SelectedItem as Row;

    private Row? Unlock(Row row)
    {
        var key = _repo.Data.SshKeys?.FirstOrDefault(k => k.Id == row.Id);
        if (key is null) return null;
        var (pw, _) = PasswordDialog.AskEx(this, $"Passphrase ключа «{key.Name}»", withSave: false);
        if (pw is null) return null;
        var meta = TryMeta(key.PrivateKey, pw, key.Name);
        if (meta is not { } m) { Status.Text = "Passphrase не подошла"; return null; }
        return row with { Type = m.Type, Fp = m.Fp, PubLine = m.Pub };
    }

    private Row? Unlocked()
    {
        if (Selected is not { } row) return null;
        if (row.PubLine is not null) return row;
        return Unlock(row);
    }

    private void CopyPub_Click(object sender, RoutedEventArgs e)
    {
        if (Unlocked() is not { PubLine: { } pub }) return;
        try { Clipboard.SetText(pub); Status.Text = "authorized_keys в буфере"; } catch { }
    }

    private void CopyFp_Click(object sender, RoutedEventArgs e)
    {
        if (Unlocked() is not { } row) return;
        try { Clipboard.SetText(row.Fp); Status.Text = "Отпечаток в буфере"; } catch { }
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title = "Файл приватного ключа (OpenSSH/PEM/PPK)",
            Filter = "Ключи (*.ppk;*.pem;*.key;id_*)|*.ppk;*.pem;*.key;id_*|Все файлы (*.*)|*.*",
        };
        if (dlg.ShowDialog(this) != true) return;
        string text;
        try { text = File.ReadAllText(dlg.FileName); }
        catch (Exception ex) { Status.Text = ex.Message; return; }
        if (Security.PpkConverter.LooksLikePpk(text))
        {
            string? pass = null;
            if (text.Contains("Encryption: aes256-cbc"))
            {
                (pass, _) = PasswordDialog.AskEx(this,
                    $"Passphrase PPK «{Path.GetFileName(dlg.FileName)}»", withSave: false);
                if (pass is null) return;
            }
            try
            {
                text = Security.PpkConverter.Convert(text, pass);
                // Раунд-чек: результат обязан парситься SSH.NET
                if (TryMeta(text, null, "check") is null)
                    throw new Exception("конвертация неконсистентна (самопроверка)");
            }
            catch (Security.PpkConverter.BadPassphraseException)
            {
                Status.Text = "Passphrase не подошла (MAC не сошёлся)";
                return;
            }
            catch (Exception ex)
            {
                Status.Text = "PPK: " + ex.Message;
                return;
            }
            Status.Text = "PPK сконвертирован в OpenSSH";
        }
        var name = InputDialog.Ask(this, "Имя ключа:", Path.GetFileNameWithoutExtension(dlg.FileName));
        if (name is null) return;
        _repo.Data.SshKeys ??= new();
        _repo.Data.SshKeys.Add(new SSHKey
        {
            Name = name,
            PrivateKey = text,
            UpdatedAt = QtJson.NowIso(),
        });
        _repo.Persist();
        Refresh();
        Status.Text = $"Ключ «{name}» в вейлте (уедет синком)";
    }

    private void Paste_Click(object sender, RoutedEventArgs e)
    {
        if (KeyPasteDialog.Show(this, _repo) is not { } key) return;
        Refresh();
        Status.Text = $"Ключ «{key.Name}» в вейлте (уедет синком)";
    }

    private void ToAgent_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } row) return;
        var key = _repo.Data.SshKeys?.FirstOrDefault(k => k.Id == row.Id);
        if (key is null) return;
        try
        {
            using var ms = new MemoryStream(Encoding.UTF8.GetBytes(key.PrivateKey));
            var pk = new PrivateKeyFile(ms);
            new SshAgent().AddIdentity(pk);
            Status.Text = $"«{key.Name}» загружен в OpenSSH-agent";
        }
        catch (Renci.SshNet.Common.SshPassPhraseNullOrEmptyException)
        {
            var (pw, _) = PasswordDialog.AskEx(this, $"Passphrase «{key.Name}»", withSave: false);
            if (pw is null) return;
            try
            {
                using var ms = new MemoryStream(Encoding.UTF8.GetBytes(key.PrivateKey));
                new SshAgent().AddIdentity(new PrivateKeyFile(ms, pw));
                Status.Text = $"«{key.Name}» загружен в OpenSSH-agent";
            }
            catch (Exception ex) { Status.Text = "Агент: " + ex.Message; }
        }
        catch (Exception ex)
        {
            Status.Text = "Агент недоступен (запусти ssh-agent): " + ex.Message;
        }
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } row) return;
        var key = _repo.Data.SshKeys?.FirstOrDefault(k => k.Id == row.Id);
        if (key is null) return;
        var used = _repo.Data.Sessions.Count(s => s.Deleted != true && s.KeyID == key.Id);
        if (MessageBox.Show(this,
                $"Удалить ключ «{key.Name}»?" + (used > 0 ? $"\nИм пользуются нод: {used} — они уйдут на пароль." : "") +
                "\nУдаление уедет синком.",
                "QTerm", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                MessageBoxResult.No) != MessageBoxResult.Yes) return;
        key.Deleted = true;
        key.UpdatedAt = QtJson.NowIso();
        _repo.Persist();
        Refresh();
    }
}
