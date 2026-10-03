using System.IO;
using System.Security.Cryptography;
using Konscious.Security.Cryptography;

namespace QTermWin.Sync;

/// <summary>
/// Облачный блоб — контракт мак/андроид/винда:
/// "QTS1"(4)+t(1)+p(1)+m_kib(4 LE)+salt(16)+nonce(12)+AES-256-GCM(ct+tag).
/// Ключ = Argon2id(пароль UTF-8, salt, t=3, m=65536KiB, p=2, len=32);
/// параметры читаются ИЗ ЗАГОЛОВКА — стороны не зависят от дефолтов библиотек.
/// </summary>
public static class Qts1
{
    private static readonly byte[] Magic = "QTS1"u8.ToArray();
    private const byte TCost = 3;
    private const byte PCost = 2;
    private const uint MKib = 65536;

    public sealed class DecryptException : Exception
    {
        public DecryptException() : base("Не расшифровалось — проверь пароль шифрования") { }
    }

    private static byte[] DeriveKey(string password, byte[] salt, byte t, uint mKib, byte p)
    {
        using var argon = new Argon2id(System.Text.Encoding.UTF8.GetBytes(password))
        {
            Salt = salt,
            Iterations = t,
            MemorySize = (int)mKib,     // КиБ
            DegreeOfParallelism = p,
        };
        return argon.GetBytes(32);
    }

    public static byte[] Pack(byte[] payload, string password)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var key = DeriveKey(password, salt, TCost, MKib, PCost);
        var ct = new byte[payload.Length];
        var tag = new byte[16];
        try
        {
            using var gcm = new AesGcm(key, 16);
            gcm.Encrypt(nonce, payload, ct, tag);
        }
        finally { CryptographicOperations.ZeroMemory(key); }

        using var ms = new MemoryStream();
        ms.Write(Magic);
        ms.WriteByte(TCost);
        ms.WriteByte(PCost);
        ms.Write(BitConverter.GetBytes(MKib)); // LE на x86/arm64-Windows
        ms.Write(salt);
        ms.Write(nonce);
        ms.Write(ct);
        ms.Write(tag);
        return ms.ToArray();
    }

    public static byte[] Unpack(byte[] blob, string password)
    {
        const int hdr = 4 + 1 + 1 + 4 + 16 + 12;
        if (blob.Length <= hdr + 16)
            throw new InvalidDataException("Блоб повреждён (обрезан)");
        if (!blob.AsSpan(0, 4).SequenceEqual(Magic))
            throw new InvalidDataException("Файл на сервере — не QTS1-блоб (чужой файл по этому URL?)");

        int i = 4;
        byte t = blob[i++];
        byte p = blob[i++];
        uint m = BitConverter.ToUInt32(blob, i); i += 4;
        var salt = blob.AsSpan(i, 16).ToArray(); i += 16;
        var nonce = blob.AsSpan(i, 12).ToArray(); i += 12;
        var ct = blob.AsSpan(i, blob.Length - i - 16).ToArray();
        var tag = blob.AsSpan(blob.Length - 16, 16).ToArray();

        var key = DeriveKey(password, salt, t, m, p);
        var plain = new byte[ct.Length];
        try
        {
            using var gcm = new AesGcm(key, 16);
            gcm.Decrypt(nonce, ct, tag, plain);
        }
        catch (AuthenticationTagMismatchException)
        {
            throw new DecryptException();
        }
        finally { CryptographicOperations.ZeroMemory(key); }
        return plain;
    }
}
