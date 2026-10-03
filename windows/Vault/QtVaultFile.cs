using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using QTermWin.Models;

namespace QTermWin.Vault;

/// <summary>
/// Формат .qtvault (канон mac/android):
///   "QTV1"(4) + salt(16) + nonce(12) + AES-256-GCM(ciphertext + tag16)
/// Ключ = PBKDF2-HMAC-SHA256(пароль UTF-8, salt, 300_000 итераций, 32 байта).
/// </summary>
public static class QtVaultFile
{
    private static readonly byte[] Magic = "QTV1"u8.ToArray();
    private const int SaltLen = 16;
    private const int NonceLen = 12;
    private const int TagLen = 16;
    private const int Iterations = 300_000;

    public sealed class BadPasswordOrCorruptException : Exception
    {
        public BadPasswordOrCorruptException(Exception inner)
            : base("Неверный пароль или повреждённый файл", inner) { }
    }

    public static SessionVault Decrypt(byte[] blob, string password)
    {
        if (blob.Length < Magic.Length + SaltLen + NonceLen + TagLen ||
            !blob.AsSpan(0, 4).SequenceEqual(Magic))
            throw new InvalidDataException("Не .qtvault: нет заголовка QTV1");

        int off = Magic.Length;
        var salt  = blob.AsSpan(off, SaltLen).ToArray();  off += SaltLen;
        var nonce = blob.AsSpan(off, NonceLen).ToArray(); off += NonceLen;
        var ct    = blob.AsSpan(off, blob.Length - off - TagLen).ToArray();
        var tag   = blob.AsSpan(blob.Length - TagLen, TagLen).ToArray();

        var key = DeriveKey(password, salt);
        var plain = new byte[ct.Length];
        try
        {
            using var gcm = new AesGcm(key, TagLen);
            gcm.Decrypt(nonce, ct, tag, plain);
        }
        catch (AuthenticationTagMismatchException e)
        {
            throw new BadPasswordOrCorruptException(e);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
        }

        return JsonSerializer.Deserialize<SessionVault>(plain, QtJson.Options)
            ?? throw new InvalidDataException("Пустой payload вейлта");
    }

    public static byte[] Encrypt(SessionVault vault, string password)
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(vault, QtJson.Options);
        var salt  = RandomNumberGenerator.GetBytes(SaltLen);
        var nonce = RandomNumberGenerator.GetBytes(NonceLen);
        var ct    = new byte[plain.Length];
        var tag   = new byte[TagLen];

        var key = DeriveKey(password, salt);
        try
        {
            using var gcm = new AesGcm(key, TagLen);
            gcm.Encrypt(nonce, plain, ct, tag);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(key);
            CryptographicOperations.ZeroMemory(plain);
        }

        using var ms = new MemoryStream();
        ms.Write(Magic); ms.Write(salt); ms.Write(nonce); ms.Write(ct); ms.Write(tag);
        return ms.ToArray();
    }

    private static byte[] DeriveKey(string password, byte[] salt) =>
        Rfc2898DeriveBytes.Pbkdf2(
            Encoding.UTF8.GetBytes(password), salt, Iterations,
            HashAlgorithmName.SHA256, 32);
}
