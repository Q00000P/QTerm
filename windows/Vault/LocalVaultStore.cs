using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using QTermWin.Models;

namespace QTermWin.Vault;

/// <summary>
/// Локальный вейлт: JSON SessionVault → DPAPI (CurrentUser) → vault.bin
/// в %APPDATA%\QTerm. Аналог связки Keychain+vault.dat на маке; обёртка
/// мастер-ключа под Windows Hello — отдельной волной, формат файла это
/// переживёт (поменяется только защита, читаем по заголовку).
/// </summary>
public sealed class LocalVaultStore
{
    private readonly string _dir;
    private string VaultPath => Path.Combine(_dir, "vault.bin");

    public LocalVaultStore(string? dirOverride = null)
    {
        _dir = dirOverride ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QTerm");
    }

    public bool IsInitialized => File.Exists(VaultPath);

    public SessionVault InitializeIfNeeded()
    {
        Directory.CreateDirectory(_dir);
        if (IsInitialized) return Load();
        var empty = new SessionVault();
        Save(empty);
        return empty;
    }

    public SessionVault Load()
    {
        var protectedBytes = File.ReadAllBytes(VaultPath);
        var plain = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
        try
        {
            return JsonSerializer.Deserialize<SessionVault>(plain, QtJson.Options)
                ?? throw new InvalidDataException("vault.bin пуст");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
    }

    public void Save(SessionVault vault)
    {
        Directory.CreateDirectory(_dir);
        vault.UpdatedAt = DateTime.UtcNow;
        var plain = JsonSerializer.SerializeToUtf8Bytes(vault, QtJson.Options);
        var protectedBytes = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
        CryptographicOperations.ZeroMemory(plain);

        // Атомарно: temp в той же папке + Move с перезаписью
        var tmp = VaultPath + ".tmp";
        File.WriteAllBytes(tmp, protectedBytes);
        File.Move(tmp, VaultPath, overwrite: true);
    }
}
