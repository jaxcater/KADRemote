using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Agent.Models;

namespace KADRemote.Agent.Services;

/// <summary>
/// Publishes an AES-256-GCM encrypted server announcement (containing Tunnel URL, LAN URLs, and stats)
/// to a token-derived ntfy.sh topic AND listens for "KADREQ1:discover" requests from the iPhone app,
/// so the iPhone on 4G/Internet discovers the Windows PC in real time within seconds.
/// </summary>
public sealed class CloudSyncService : IDisposable
{
    private const string RelayEndpoint = "https://ntfy.sh";
    private readonly AgentConfigService _config;
    private readonly SystemService _system;
    private readonly CloudflareTunnelService _tunnel;
    private readonly HttpClient _http;
    private readonly HttpClient _streamHttp;
    private readonly string _topic;
    private readonly byte[] _encKey;
    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _wakeSignal = new(0, 1);

    private Task? _publishTask;
    private Task? _listenTask;

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
        _http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "KADRemote-Agent/1.3");

        _streamHttp = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        _streamHttp.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "KADRemote-Agent/1.3");

        _tunnel.TunnelUrlChanged += OnTunnelUrlChanged;
    }

    public void Start()
    {
        if (!_config.Config.EnableCloudSync) return;
        _publishTask ??= Task.Run(() => RunPublishLoopAsync(_cts.Token));
        _listenTask ??= Task.Run(() => RunListenLoopAsync(_cts.Token));
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

    private async Task RunPublishLoopAsync(CancellationToken ct)
    {
        // Publish immediately on startup so the iPhone sees the PC right away,
        // and publish again immediately as soon as cloudflared reports its Tunnel URL.
        int failCount = 0;
        while (!ct.IsCancellationRequested)
        {
            bool ok = await PublishAnnouncementAsync(ct);
            failCount = ok ? 0 : failCount + 1;

            int waitMs = ok
                ? (string.IsNullOrWhiteSpace(_tunnel.PublicUrl) && _config.Config.EnableCloudflareTunnel ? 15_000 : 5 * 60 * 1000)
                : Math.Min(60_000, 5_000 * failCount);

            try
            {
                await _wakeSignal.WaitAsync(waitMs, ct);
                await Task.Delay(400, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task RunListenLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, $"{RelayEndpoint}/{_topic}/json");
                using var resp = await _streamHttp.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
                resp.EnsureSuccessStatusCode();

                await using var stream = await resp.Content.ReadAsStreamAsync(ct);
                using var reader = new StreamReader(stream, Encoding.UTF8);

                while (!ct.IsCancellationRequested && await reader.ReadLineAsync(ct) is { } line)
                {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    if (!line.Contains("KADREQ1:discover", StringComparison.Ordinal)) continue;

                    AgentLog.Info("CloudSync", "Received discover request from iPhone -> publishing fresh status");
                    SignalWake();
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                // Reconnect stream after brief backoff
            }

            try { await Task.Delay(5000, ct); }
            catch (OperationCanceledException) { break; }
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
            req.Headers.TryAddWithoutValidation("Cache", "yes");

            using var resp = await _http.SendAsync(req, ct);
            if (resp.IsSuccessStatusCode)
            {
                AgentLog.Info("CloudSync", $"Published encrypted announcement (tunnel={dto.TunnelUrl ?? "pending"})");
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
        _streamHttp.Dispose();
        _wakeSignal.Dispose();
        _cts.Dispose();
    }
}
