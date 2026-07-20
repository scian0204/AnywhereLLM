using System.Runtime.InteropServices;
using System.Text;
using AnywhereLLM.Interop;

namespace AnywhereLLM.Services;

/// Windows Credential Manager storage for the LLM API key (Keychain analog).
/// Stored as a CRED_TYPE_GENERIC credential with a UTF-8 blob. Stateless statics.
public static class CredentialStore
{
    private const string Target = "kr.scian0204.AnywhereLLM:apiKey";

    public static string? Get()
    {
        if (!NativeMethods.CredRead(Target, NativeMethods.CRED_TYPE_GENERIC, 0, out var ptr))
            return null;
        try
        {
            var cred = Marshal.PtrToStructure<NativeMethods.CREDENTIAL>(ptr);
            if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize == 0) return null;
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally { NativeMethods.CredFree(ptr); }
    }

    /// Empty value deletes the entry — a local server (Ollama etc.) has no key,
    /// and a lingering entry would prompt on every read (mirrors the Swift store).
    public static bool Set(string value)
    {
        if (string.IsNullOrEmpty(value)) return Delete();

        var bytes = Encoding.UTF8.GetBytes(value);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var cred = new NativeMethods.CREDENTIAL
            {
                Type = NativeMethods.CRED_TYPE_GENERIC,
                TargetName = Target,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = NativeMethods.CRED_PERSIST_LOCAL_MACHINE,
                UserName = "apiKey",
            };
            return NativeMethods.CredWrite(ref cred, 0);
        }
        finally { Marshal.FreeHGlobal(blob); }
    }

    public static bool Delete()
    {
        if (NativeMethods.CredDelete(Target, NativeMethods.CRED_TYPE_GENERIC, 0)) return true;
        // ERROR_NOT_FOUND (1168) counts as success — nothing to remove.
        return Marshal.GetLastWin32Error() == 1168;
    }
}
