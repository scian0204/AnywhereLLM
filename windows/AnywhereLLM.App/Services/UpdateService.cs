using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using AnywhereLLM.Core;

namespace AnywhereLLM.Services;

/// In-app self-updater (no installer). Checks GitHub Releases, downloads the
/// self-contained exe zip, verifies its SHA256, then hands off to a helper .cmd
/// that waits for this process to exit, swaps the running exe, and relaunches.
/// Pure logic (version compare, JSON/checksum parsing) lives in Core.UpdateCheck.
/// Mirrors macOS UpdateService.swift.
public static class UpdateService
{
    private const string RepoOwner = "scian0204";
    private const string RepoName = "AnywhereLLM";
    private const string AssetSuffix = "-win-x64.zip";
    private const string ChecksumAsset = "SHA256SUMS.txt";

    public static string ReleasesPageUrl => $"https://github.com/{RepoOwner}/{RepoName}/releases/latest";

    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        // GitHub's REST API rejects requests without a User-Agent (HTTP 403).
        c.DefaultRequestHeaders.UserAgent.ParseAdd("AnywhereLLM-Updater");
        return c;
    }

    /// Running assembly version as M.m.p (drops the .0 revision), matching the tag.
    public static string CurrentVersion =>
        Assembly.GetExecutingAssembly().GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0.0.0";

    /// The newer release, or null if up-to-date or on any failure (auto-check must
    /// never surface network errors to the user).
    public static async Task<UpdateCheck.ReleaseInfo?> CheckAsync()
    {
        try
        {
            var url = $"https://api.github.com/repos/{RepoOwner}/{RepoName}/releases/latest";
            var json = await Http.GetStringAsync(url).ConfigureAwait(false);
            var rel = UpdateCheck.ParseLatestRelease(json);
            if (rel is null) return null;
            return UpdateCheck.IsNewer(CurrentVersion, rel.Tag) ? rel : null;
        }
        catch
        {
            return null;
        }
    }

    /// Download the win-x64 zip, verify its SHA256 against SHA256SUMS.txt, extract
    /// the new exe, then launch the swap+relaunch helper. Throws on network or
    /// verification failure (nothing is replaced). Returns false — after opening the
    /// releases page — when the exe folder is not writable (no admin elevation).
    /// On success (true) the caller must shut the app down so the helper can proceed.
    public static async Task<bool> DownloadAndApplyAsync(UpdateCheck.ReleaseInfo release, IProgress<string>? progress = null)
    {
        var asset = UpdateCheck.PickAsset(release.Assets, AssetSuffix);
        var sums = UpdateCheck.PickAsset(release.Assets, ChecksumAsset);
        if (asset is null || sums is null)
            throw new InvalidOperationException("release is missing the win-x64 zip or SHA256SUMS.txt");

        var exePath = Environment.ProcessPath
                      ?? throw new InvalidOperationException("cannot resolve the current exe path");
        if (!IsDirWritable(Path.GetDirectoryName(exePath)!))
        {
            OpenReleasesPage();
            return false;
        }

        var work = Directory.CreateTempSubdirectory("anywherellm-update").FullName;
        var zipPath = Path.Combine(work, asset.Name);

        progress?.Report("downloading");
        await DownloadFileAsync(asset.DownloadUrl, zipPath).ConfigureAwait(false);

        progress?.Report("verifying");
        var sumsText = await Http.GetStringAsync(sums.DownloadUrl).ConfigureAwait(false);
        var expected = UpdateCheck.ParseChecksums(sumsText).TryGetValue(asset.Name, out var h) ? h : null;
        var actual = Sha256Hex(zipPath);
        if (expected is null || !string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException($"checksum mismatch for {asset.Name}");

        progress?.Report("extracting");
        var extractDir = Path.Combine(work, "extracted");
        ZipFile.ExtractToDirectory(zipPath, extractDir);
        var newExe = Directory.EnumerateFiles(extractDir, "*.exe", SearchOption.AllDirectories).FirstOrDefault()
                     ?? throw new InvalidOperationException("no exe inside the downloaded zip");

        LaunchSwapAndRelaunch(exePath, newExe);
        return true;
    }

    /// Delete a leftover "<exe>.old" from a previous self-update (best-effort).
    public static void CleanupOldExe()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (exe is null) return;
            var old = exe + ".old";
            if (File.Exists(old)) File.Delete(old);
        }
        catch
        {
            // best-effort: a still-locked .old is retried on the next launch
        }
    }

    public static void OpenReleasesPage()
    {
        try { Process.Start(new ProcessStartInfo(ReleasesPageUrl) { UseShellExecute = true }); }
        catch { /* nothing else to do */ }
    }

    // MARK: - internals

    private static async Task DownloadFileAsync(string url, string dest)
    {
        using var resp = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        await using var fs = File.Create(dest);
        await resp.Content.CopyToAsync(fs).ConfigureAwait(false);
    }

    private static string Sha256Hex(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = SHA256.Create();
        return Convert.ToHexString(sha.ComputeHash(stream)).ToLowerInvariant();
    }

    private static bool IsDirWritable(string dir)
    {
        try
        {
            var probe = Path.Combine(dir, $".anywherellm-writetest-{Environment.ProcessId}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// A detached cmd that spins until our PID is gone, renames the running exe to
    /// ".old" (allowed while running — it's a mapped image), moves the new exe into
    /// place, relaunches, then deletes itself. ping is the sleep (timeout.exe needs a
    /// console this hidden process lacks).
    private static void LaunchSwapAndRelaunch(string oldExe, string newExe)
    {
        int pid = Environment.ProcessId;
        var cmdPath = Path.Combine(Path.GetTempPath(), $"anywherellm-update-{pid}.cmd");
        var script =
            "@echo off\r\n" +
            ":waitloop\r\n" +
            $"tasklist /fi \"PID eq {pid}\" 2>nul | find \"{pid}\" >nul\r\n" +
            "if not errorlevel 1 (\r\n" +
            "  ping 127.0.0.1 -n 2 >nul\r\n" +
            "  goto waitloop\r\n" +
            ")\r\n" +
            $"move /y \"{oldExe}\" \"{oldExe}.old\" >nul 2>&1\r\n" +
            $"move /y \"{newExe}\" \"{oldExe}\" >nul 2>&1\r\n" +
            $"start \"\" \"{oldExe}\"\r\n" +
            "del \"%~f0\"\r\n";
        File.WriteAllText(cmdPath, script);

        Process.Start(new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = $"/c \"{cmdPath}\"",
            CreateNoWindow = true,
            UseShellExecute = false,
            WindowStyle = ProcessWindowStyle.Hidden,
        });
    }
}
