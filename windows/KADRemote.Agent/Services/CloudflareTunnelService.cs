using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace KADRemote.Agent.Services;

public sealed partial class CloudflareTunnelService : IDisposable
{
    private const string CloudflaredDownloadUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe";
    private static readonly string LocalBinaryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KADRemote",
        "cloudflared.exe"
    );

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeleteFileW(string lpFileName);

    [GeneratedRegex(@"https://[a-zA-Z0-9\-]+\.trycloudflare\.com", RegexOptions.Compiled)]
    private static partial Regex TunnelUrlRegex();

    private readonly AgentConfigService _config;
    private readonly CancellationTokenSource _cts = new();
    private Process? _process;
    private Task? _runnerTask;

    public string? PublicUrl { get; private set; }
    public event Action<string?>? TunnelUrlChanged;

    public CloudflareTunnelService(AgentConfigService config)
    {
        _config = config;
    }

    public void Start()
    {
        if (!_config.Config.EnableCloudflareTunnel) return;
        _runnerTask ??= Task.Run(() => RunTunnelLoopAsync(_cts.Token));
    }

    private async Task RunTunnelLoopAsync(CancellationToken ct)
    {
        int failCount = 0;

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var exePath = await EnsureCloudflaredAsync(ct);
                if (exePath == null)
                {
                    failCount++;
                    await Task.Delay(Math.Min(60_000, 10_000 * failCount), ct);
                    continue;
                }

                await RunSingleTunnelProcessAsync(exePath, ct);
                failCount = 0;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                failCount++;
            }

            SetPublicUrl(null);
            int delayMs = Math.Min(30_000, 4000 + failCount * 3000);
            try { await Task.Delay(delayMs, ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task RunSingleTunnelProcessAsync(string exePath, CancellationToken ct)
    {
        var namedToken = _config.Config.CloudflareTunnelToken?.Trim();
        var namedUrl = _config.Config.CloudflareTunnelUrl?.Trim();

        string args;
        if (!string.IsNullOrEmpty(namedToken))
        {
            args = $"tunnel --no-autoupdate run --token {namedToken}";
            if (!string.IsNullOrEmpty(namedUrl))
                SetPublicUrl(namedUrl.TrimEnd('/'));
        }
        else
        {
            args = $"tunnel --no-autoupdate --url http://127.0.0.1:{_config.Config.AgentPort}";
        }

        var psi = new ProcessStartInfo
        {
            FileName = exePath,
            Arguments = args,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var proc = new Process { StartInfo = psi };
        _process = proc;
        proc.Start();

        using var reg = ct.Register(() =>
        {
            try { if (!proc.HasExited) proc.Kill(entireProcessTree: true); } catch { }
        });

        var errTask = ReadOutputAsync(proc.StandardError, ct);
        var outTask = ReadOutputAsync(proc.StandardOutput, ct);

        await proc.WaitForExitAsync(ct);
        await Task.WhenAll(errTask, outTask);
        _process = null;
    }

    private async Task ReadOutputAsync(StreamReader reader, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested && await reader.ReadLineAsync(ct) is { } line)
            {
                var match = TunnelUrlRegex().Match(line);
                if (match.Success)
                    SetPublicUrl(match.Value);
            }
        }
        catch { }
    }

    private void SetPublicUrl(string? url)
    {
        if (string.Equals(PublicUrl, url, StringComparison.Ordinal)) return;
        PublicUrl = url;
        TunnelUrlChanged?.Invoke(url);
    }

    private static async Task<string?> EnsureCloudflaredAsync(CancellationToken ct)
    {
        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathEnv.Split(Path.PathSeparator))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim(), "cloudflared.exe");
                if (File.Exists(candidate))
                    return candidate;
            }
            catch { }
        }

        if (File.Exists(LocalBinaryPath) && new FileInfo(LocalBinaryPath).Length > 1_000_000)
        {
            StripZoneIdentifier(LocalBinaryPath);
            return LocalBinaryPath;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(LocalBinaryPath)!);

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(4) };
        using var resp = await http.GetAsync(CloudflaredDownloadUrl, HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();

        var tempPath = LocalBinaryPath + ".tmp";
        await using (var src = await resp.Content.ReadAsStreamAsync(ct))
        await using (var dst = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true))
        {
            await src.CopyToAsync(dst, ct);
        }

        if (File.Exists(LocalBinaryPath))
            File.Delete(LocalBinaryPath);
        File.Move(tempPath, LocalBinaryPath);
        StripZoneIdentifier(LocalBinaryPath);

        return LocalBinaryPath;
    }

    private static void StripZoneIdentifier(string path)
    {
        try { DeleteFileW(path + ":Zone.Identifier"); } catch { }
    }

    public void Dispose()
    {
        _cts.Cancel();
        try
        {
            if (_process is { HasExited: false })
                _process.Kill(entireProcessTree: true);
        }
        catch { }
        _process?.Dispose();
        _cts.Dispose();
    }
}
