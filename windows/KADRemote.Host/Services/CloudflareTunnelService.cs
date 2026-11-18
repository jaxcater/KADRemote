using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.RegularExpressions;

namespace KADRemote.Host.Services;

public sealed partial class CloudflareTunnelService : IDisposable
{
    private const string CloudflaredDownloadUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe";
    private static readonly string LocalBinaryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KADRemote",
        "cloudflared.exe"
    );

    [GeneratedRegex(@"https://[a-zA-Z0-9\-]+\.trycloudflare\.com", RegexOptions.Compiled)]
    private static partial Regex TunnelUrlRegex();

    private readonly LogService _log;
    private Process? _process;
    private CancellationTokenSource? _cts;

    public string? PublicUrl { get; private set; }
    public string StatusText { get; private set; } = "Chưa bật";
    public bool IsRunning => _process is { HasExited: false } || _isStarting;
    private bool _isStarting;

    public event Action? StateChanged;

    public CloudflareTunnelService(LogService log)
    {
        _log = log;
    }

    public async Task StartAsync(int port)
    {
        if (IsRunning) return;
        _isStarting = true;
        _cts = new CancellationTokenSource();
        PublicUrl = null;
        UpdateStatus("Đang kiểm tra cloudflared...");

        try
        {
            var exePath = await EnsureCloudflaredAsync(_cts.Token);
            if (exePath == null)
            {
                _isStarting = false;
                UpdateStatus("Không thể tải cloudflared");
                return;
            }

            UpdateStatus("Đang mở Cloudflare Tunnel...");
            _log.Add("Tunnel", $"Khởi động cloudflared -> http://127.0.0.1:{port}");

            var psi = new ProcessStartInfo
            {
                FileName = exePath,
                Arguments = $"tunnel --no-autoupdate --url http://127.0.0.1:{port}",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            _process = new Process { StartInfo = psi, EnableRaisingEvents = true };
            _process.Exited += (_, _) =>
            {
                _isStarting = false;
                PublicUrl = null;
                UpdateStatus("Tunnel đã dừng");
            };

            _process.Start();
            _isStarting = false;

            _ = Task.Run(() => ReadOutputAsync(_process.StandardError, _cts.Token));
            _ = Task.Run(() => ReadOutputAsync(_process.StandardOutput, _cts.Token));
        }
        catch (Exception ex)
        {
            _isStarting = false;
            _log.Add("Tunnel", $"Lỗi khởi động tunnel: {ex.Message}");
            UpdateStatus($"Lỗi: {ex.Message}");
        }
    }

    public void Stop()
    {
        try
        {
            _cts?.Cancel();
            if (_process is { HasExited: false })
            {
                _process.Kill(entireProcessTree: true);
            }
        }
        catch { }
        finally
        {
            _process?.Dispose();
            _process = null;
            _isStarting = false;
            PublicUrl = null;
            UpdateStatus("Đã tắt");
            _log.Add("Tunnel", "Đã tắt Cloudflare Tunnel");
        }
    }

    private async Task ReadOutputAsync(StreamReader reader, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested && await reader.ReadLineAsync(ct) is { } line)
            {
                var match = TunnelUrlRegex().Match(line);
                if (match.Success && PublicUrl != match.Value)
                {
                    PublicUrl = match.Value;
                    _log.Add("Tunnel", $"Đã có URL từ xa: {PublicUrl}");
                    UpdateStatus("Đang hoạt động (4G/Internet sẵn sàng)");
                }
            }
        }
        catch { }
    }

    private async Task<string?> EnsureCloudflaredAsync(CancellationToken ct)
    {
        // Check PATH first
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
            return LocalBinaryPath;

        Directory.CreateDirectory(Path.GetDirectoryName(LocalBinaryPath)!);
        UpdateStatus("Đang tải cloudflared (~40MB)...");
        _log.Add("Tunnel", "Đang tải Cloudflare Tunnel client...");

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
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

        _log.Add("Tunnel", "Đã tải xong cloudflared.exe");
        return LocalBinaryPath;
    }

    private void UpdateStatus(string text)
    {
        StatusText = text;
        StateChanged?.Invoke();
    }

    public void Dispose()
    {
        Stop();
    }
}
