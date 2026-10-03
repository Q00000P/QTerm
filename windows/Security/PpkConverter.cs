using System.IO;
using System.Security.Cryptography;
using System.Text;
using Konscious.Security.Cryptography;

namespace QTermWin.Security;

/// <summary>
/// Нативный PPK→OpenSSH конвертер (канон мака — «конвертни сам в PuTTY» не наш путь).
/// PPK2: ключ SHA1(seq+pass), MAC HMAC-SHA1(SHA1("putty-private-key-file-mac-key"+pass)).
/// PPK3: Argon2(id/i/d) с параметрами ИЗ ФАЙЛА → 80 байт (32 ключ + 16 IV + 32 MAC),
/// MAC HMAC-SHA256. MAC считается по blob(alg,enc,comment,pub,priv-plain) —
/// неверная passphrase = MAC mismatch, тихой порчи не бывает.
/// Выход — незашифрованный openssh-key-v1 (кладётся в шифрованный вейлт).
/// </summary>
public static class PpkConverter
{
    public sealed class PpkException : Exception
    {
        public PpkException(string m) : base(m) { }
    }
    public sealed class BadPassphraseException : Exception { }

    public static bool LooksLikePpk(string text) => text.Contains("PuTTY-User-Key-File");

    public static string Convert(string ppkText, string? passphrase)
    {
        var (version, alg, encryption, comment, headers, pub, privEnc, macHex) = Parse(ppkText);
        if (alg is not ("ssh-ed25519" or "ssh-rsa"))
            throw new PpkException($"Алгоритм {alg} не поддержан (ed25519/RSA)");

        byte[] priv;
        byte[] macKey;
        if (encryption == "none")
        {
            priv = privEnc;
            macKey = version == 2
                ? SHA1.HashData(Encoding.ASCII.GetBytes("putty-private-key-file-mac-key"))
                : Array.Empty<byte>();
        }
        else if (encryption == "aes256-cbc")
        {
            var pass = passphrase ?? throw new BadPassphraseException();
            byte[] cipherKey, iv;
            if (version == 2)
            {
                cipherKey = new byte[32];
                var h1 = SHA1.HashData(Cat(new byte[] { 0, 0, 0, 0 }, Encoding.UTF8.GetBytes(pass)));
                var h2 = SHA1.HashData(Cat(new byte[] { 0, 0, 0, 1 }, Encoding.UTF8.GetBytes(pass)));
                Buffer.BlockCopy(h1, 0, cipherKey, 0, 20);
                Buffer.BlockCopy(h2, 0, cipherKey, 20, 12);
                iv = new byte[16];
                macKey = SHA1.HashData(Cat(
                    Encoding.ASCII.GetBytes("putty-private-key-file-mac-key"),
                    Encoding.UTF8.GetBytes(pass)));
            }
            else
            {
                var mem = int.Parse(headers.GetValueOrDefault("Argon2-Memory", "8192"));
                var passes = int.Parse(headers.GetValueOrDefault("Argon2-Passes", "21"));
                var par = int.Parse(headers.GetValueOrDefault("Argon2-Parallelism", "1"));
                var salt = FromHex(headers.GetValueOrDefault("Argon2-Salt", "")
                    ?? throw new PpkException("Нет Argon2-Salt"));
                var kdf = headers.GetValueOrDefault("Key-Derivation", "Argon2id");
                var pwBytes = Encoding.UTF8.GetBytes(pass);
                Argon2 argon = kdf switch
                {
                    "Argon2id" => new Argon2id(pwBytes),
                    "Argon2i" => new Argon2i(pwBytes),
                    "Argon2d" => new Argon2d(pwBytes),
                    _ => throw new PpkException("KDF " + kdf + " не поддержан"),
                };
                using (argon)
                {
                    argon.Salt = salt;
                    argon.MemorySize = mem;
                    argon.Iterations = passes;
                    argon.DegreeOfParallelism = par;
                    var derived = argon.GetBytes(80);
                    cipherKey = derived[..32];
                    iv = derived[32..48];
                    macKey = derived[48..80];
                }
            }
            using var aes = Aes.Create();
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.None;
            aes.Key = cipherKey;
            aes.IV = iv;
            priv = aes.CreateDecryptor().TransformFinalBlock(privEnc, 0, privEnc.Length);
        }
        else throw new PpkException("Шифрование " + encryption + " не поддержано");

        // MAC-проверка
        var macBlob = BuildMacBlob(alg, encryption, comment, pub, priv);
        byte[] mac = version == 2
            ? new HMACSHA1(macKey).ComputeHash(macBlob)
            : new HMACSHA256(macKey).ComputeHash(macBlob);
        if (!System.Convert.ToHexString(mac).Equals(macHex, StringComparison.OrdinalIgnoreCase))
            throw encryption == "none"
                ? new PpkException("MAC не сошёлся — файл повреждён")
                : new BadPassphraseException();

        return BuildOpenSsh(alg, pub, priv, comment);
    }

    // ── парс ──

    private static (int Ver, string Alg, string Enc, string Comment,
        Dictionary<string, string> Headers, byte[] Pub, byte[] Priv, string Mac)
        Parse(string text)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n');
        var headers = new Dictionary<string, string>();
        int ver = 0;
        string alg = "", enc = "", comment = "";
        byte[] pub = Array.Empty<byte>(), priv = Array.Empty<byte>();
        string mac = "";
        for (int i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            if (line.Length == 0) continue;
            var colon = line.IndexOf(": ", StringComparison.Ordinal);
            if (colon < 0) continue;
            var key = line[..colon];
            var val = line[(colon + 2)..].Trim();
            switch (key)
            {
                case "PuTTY-User-Key-File-2": ver = 2; alg = val; break;
                case "PuTTY-User-Key-File-3": ver = 3; alg = val; break;
                case "PuTTY-User-Key-File-1":
                    throw new PpkException("PPK1 — древний формат, не поддержан");
                case "Encryption": enc = val; break;
                case "Comment": comment = val; break;
                case "Public-Lines":
                    pub = ReadB64(lines, ref i, int.Parse(val));
                    break;
                case "Private-Lines":
                    priv = ReadB64(lines, ref i, int.Parse(val));
                    break;
                case "Private-MAC": mac = val; break;
                default: headers[key] = val; break;
            }
        }
        if (ver == 0) throw new PpkException("Не PPK-файл");
        return (ver, alg, enc, comment, headers, pub, priv, mac);
    }

    private static byte[] ReadB64(string[] lines, ref int i, int count)
    {
        var sb = new StringBuilder();
        for (int k = 0; k < count; k++) sb.Append(lines[++i].Trim());
        return System.Convert.FromBase64String(sb.ToString());
    }

    // ── сборка ──

    private static byte[] Cat(params byte[][] parts)
    {
        var total = parts.Sum(p => p.Length);
        var outp = new byte[total];
        int off = 0;
        foreach (var p in parts) { Buffer.BlockCopy(p, 0, outp, off, p.Length); off += p.Length; }
        return outp;
    }

    private static void WStr(BinaryWriter w, byte[] data)
    {
        Span<byte> len = stackalloc byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(len, (uint)data.Length);
        w.Write(len);
        w.Write(data);
    }
    private static void WStr(BinaryWriter w, string s) => WStr(w, Encoding.UTF8.GetBytes(s));

    private static void WMpint(BinaryWriter w, byte[] raw)
    {
        int i = 0;
        while (i < raw.Length - 1 && raw[i] == 0) i++;
        var v = raw[i..];
        if ((v[0] & 0x80) != 0) v = Cat(new byte[] { 0 }, v);
        WStr(w, v);
    }

    private static byte[] BuildMacBlob(string alg, string enc, string comment, byte[] pub, byte[] priv)
    {
        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        WStr(w, alg);
        WStr(w, enc);
        WStr(w, comment);
        WStr(w, pub);
        WStr(w, priv);
        w.Flush();
        return ms.ToArray();
    }

    private sealed class Reader
    {
        private readonly byte[] _d;
        private int _p;
        public Reader(byte[] d) { _d = d; }
        public byte[] Str()
        {
            var len = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(_d.AsSpan(_p));
            _p += 4;
            var v = _d[_p..(_p + len)];
            _p += len;
            return v;
        }
    }

    private static string BuildOpenSsh(string alg, byte[] pub, byte[] priv, string comment)
    {
        using var privMs = new MemoryStream();
        using var pw = new BinaryWriter(privMs);
        var check = RandomNumberGenerator.GetBytes(4);
        pw.Write(check);
        pw.Write(check);

        if (alg == "ssh-ed25519")
        {
            var pr = new Reader(pub);
            var pubAlg = pr.Str(); // "ssh-ed25519"
            var pub32 = pr.Str();
            var sr = new Reader(priv);
            var priv32 = sr.Str();
            WStr(pw, alg);
            WStr(pw, pub32);
            WStr(pw, Cat(priv32, pub32)); // openssh: priv||pub 64 байта
            WStr(pw, comment);
        }
        else // ssh-rsa
        {
            var pr = new Reader(pub);
            pr.Str(); // "ssh-rsa"
            var e = pr.Str();
            var n = pr.Str();
            var sr = new Reader(priv);
            var d = sr.Str();
            var p = sr.Str();
            var q = sr.Str();
            var iqmp = sr.Str();
            WStr(pw, alg);
            WMpint(pw, n);
            WMpint(pw, e);
            WMpint(pw, d);
            WMpint(pw, iqmp);
            WMpint(pw, p);
            WMpint(pw, q);
            WStr(pw, comment);
        }
        // паддинг 1,2,3… до кратности 8 (cipher none)
        pw.Flush();
        byte padByte = 1;
        while (privMs.Length % 8 != 0) { privMs.WriteByte(padByte++); }
        var privSection = privMs.ToArray();

        using var ms = new MemoryStream();
        using var w = new BinaryWriter(ms);
        w.Write(Encoding.ASCII.GetBytes("openssh-key-v1\0"));
        WStr(w, "none"); // cipher
        WStr(w, "none"); // kdf
        WStr(w, Array.Empty<byte>()); // kdf options
        Span<byte> one = stackalloc byte[4];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(one, 1);
        w.Write(one); // nkeys
        WStr(w, pub);
        WStr(w, privSection);
        w.Flush();

        var b64 = System.Convert.ToBase64String(ms.ToArray());
        var sb = new StringBuilder("-----BEGIN OPENSSH PRIVATE KEY-----\n");
        for (int i = 0; i < b64.Length; i += 70)
            sb.Append(b64, i, Math.Min(70, b64.Length - i)).Append('\n');
        sb.Append("-----END OPENSSH PRIVATE KEY-----\n");
        return sb.ToString();
    }

    private static byte[] FromHex(string hex) => System.Convert.FromHexString(hex);
}
