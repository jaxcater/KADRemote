using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Agent.Models;

namespace KADRemote.Agent.Services;

/// <summary>
/// Publishes an AES-256-GCM encrypted server announcement (containing Tunnel URL, LAN URLs, and stats)
/// to a token-derived ntfy.sh topic so the iPhone app can automatically discover remote Windows Servers
/// across 4G/Internet/NAT without requiring inbound connections to the iPhone.
/// </summary>
public sealed class CloudSyncService : IDisposable
{
    private const string RelayEndpoint = "https://ntfy.sh";
    private readonly AgentConfigService _config;
    private readonly SystemService _system;
    private readonly CloudflareTunnelService _tunnel;
    private readonly HttpClient _http;
    private readonly string _topic;
    private readonly byte[] _encKey;
    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _wakeSignal = new(0, 1);

    private Task? _loopTask;

    public CloudSyncService(AgentConfigService config, SystemService system, CloudflareTunnelService tunnel)
    {
        _config = config;
        _system = system;
        _tunnel = tunnel;

        var token = config.Config.ControllerToken;
        var topicHash = SHA256.HashData(Encoding.UTF8.GetBytes("kad-rendezvous-topic-v1:" + token));
        _topic = "kad_" + Convert.ToHexString(topicHash).ToLowerInvariant()[..24];
        _encKey = SHA256.HashData(Encoding.UTF8.GetBytes("kad-rendezvous-key-v1:" + token));

        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        _http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "KADRemote-Agent/1.1");

        _tunnel.TunnelUrlChanged += OnTunnelUrlChanged;
    }

    public void Start()
    {
        if (!_config.Config.EnableCloudSync) return;
        _loopTask ??= Task.Run(() => RunLoopAsync(_cts.Token));
    }

    private void OnTunnelUrlChanged(string? url)
    {
        if (!string.IsNullOrWhiteSpace(url))
            SignalWake();
    }

    private void SignalWake()
    {
        try
        {
            if (_wakeSignal.CurrentCount == 0)
                _wakeSignal.Release();
        }
        catch { }
    }

    private async Task RunLoopAsync(CancellationToken ct)
    {
        // Give cloudflared a brief window (~8s) on startup so the very first cloud announcement
        // already carries the Tunnel URL if available.
        if (_config.Config.EnableCloudflareTunnel && string.IsNullOrWhiteSpace(_tunnel.PublicUrl))
        {
            try { await _wakeSignal.WaitAsync(8000, ct); }
            catch (OperationCanceledException) { return; }
        }

        int failCount = 0;
        while (!ct.IsCancellationRequested)
        {
            bool ok = await PublishAnnouncementAsync(ct);
            failCount = ok ? 0 : failCount + 1;

            int waitMs = ok
                ? 8 * 60 * 1000
                : Math.Min(120_000, 10_000 * failCount);

            try
            {
                await _wakeSignal.WaitAsync(waitMs, ct);
                // Small coalesce delay in case multiple updates fire together
                await Task.Delay(500, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task<bool> PublishAnnouncementAsync(CancellationToken ct)
    {
        try
        {
            var (tot, used) = _system.GetMemoryBytes();
            var dto = new CloudAnnouncementDto(
                Type: "agent_announce",
                MachineId: _config.MachineId,
                DeviceName: _config.DeviceName,
                AgentPort: _config.Config.AgentPort,
                LocalUrls: _system.GetLocalUrls(_config.Config.AgentPort),
                TunnelUrl: _tunnel.PublicUrl,
                CpuUsagePercent: _system.GetCpuUsagePercent(),
                TotalMemoryBytes: tot,
                UsedMemoryBytes: used,
                UptimeSeconds: Environment.TickCount64 / 1000,
                TimestampUtc: DateTimeOffset.UtcNow
            );

            var plaintext = JsonSerializer.SerializeToUtf8Bytes(dto, AgentJsonContext.Default.CloudAnnouncementDto);
            var sealedPayload = EncryptPayload(plaintext);

            using var content = new StringContent(sealedPayload, Encoding.UTF8, "text/plain");
            using var req = new HttpRequestMessage(HttpMethod.Post, $"{RelayEndpoint}/{_topic}")
            {
                Content = content
            };
            req.Headers.TryAddWithoutValidation("Title", "kad");

            using var resp = await _http.SendAsync(req, ct);
            if (resp.IsSuccessStatusCode)
            {
                AgentLog.Info("CloudSync", $"Published encrypted announcement (tunnel={!string.IsNullOrEmpty(dto.TunnelUrl)})");
                return true;
            }

            AgentLog.Warn("CloudSync", $"Publish returned HTTP {(int)resp.StatusCode}");
            return false;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            return false;
        }
        catch (Exception ex)
        {
            AgentLog.Warn("CloudSync", $"Publish error: {ex.Message}");
            return false;
        }
    }

    private string EncryptPayload(byte[] plaintext)
    {
        Span<byte> nonce = stackalloc byte[12];
        RandomNumberGenerator.Fill(nonce);

        var combined = new byte[12 + plaintext.Length + 16];
        nonce.CopyTo(combined.AsSpan(0, 12));

        var ciphertextSpan = combined.AsSpan(12, plaintext.Length);
        var tagSpan = combined.AsSpan(12 + plaintext.Length, 16);

        using var aes = new AesGcm(_encKey, 16);
        aes.Encrypt(nonce, plaintext, ciphertextSpan, tagSpan);

        return "KADENC1:" + Convert.ToBase64String(combined);
    }

    public void Dispose()
    {
        _tunnel.TunnelUrlChanged -= OnTunnelUrlChanged;
        _cts.Cancel();
        _http.Dispose();
        _wakeSignal.Dispose();
        _cts.Dispose();
    }
}
