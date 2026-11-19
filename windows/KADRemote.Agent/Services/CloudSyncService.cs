using System.Collections.Concurrent;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Agent.Models;

namespace KADRemote.Agent.Services;

/// <summary>
/// Publishes an AES-256-GCM encrypted server announcement (containing Tunnel URL, LAN URLs, stats, and Kad.exe missing alerts)
/// to a token-derived ntfy.sh topic AND listens for "KADREQ1:discover" requests from the iPhone app,
/// so the iPhone on 4G/Internet discovers the Windows PC and receives Kad.exe missing notifications in real time.
/// </summary>
public sealed class CloudSyncService : IDisposable
{
    private const string RelayEndpoint = "https://ntfy.sh";
    private readonly AgentConfigService _config;
    private readonly SystemService _system;
    private readonly CloudflareTunnelService _tunnel;
    private readonly PeerDiscoveryService _peers;
    private readonly HttpClient _http;
    private readonly HttpClient _streamHttp;
    private readonly string _topic;
    private readonly byte[] _encKey;
    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _wakeSignal = new(0, 1);
    private readonly ConcurrentQueue<PeerInfoDto> _pendingPeerAlerts = new();

    private Task? _publishTask;
    private Task? _listenTask;

    public CloudSyncService(
        AgentConfigService config,
        SystemService system,
        CloudflareTunnelService tunnel,
        PeerDiscoveryService peers)
    {
        _config = config;
        _system = system;
        _tunnel = tunnel;
        _peers = peers;

        var token = config.Config.ControllerToken;
        var topicHash = SHA256.HashData(Encoding.UTF8.GetBytes("kad-rendezvous-topic-v1:" + token));
        _topic = "kad_" + Convert.ToHexString(topicHash).ToLowerInvariant()[..24];
        _encKey = SHA256.HashData(Encoding.UTF8.GetBytes("kad-rendezvous-key-v1:" + token));

        _http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        _http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "KADRemote-Agent/1.4");

        _streamHttp = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        _streamHttp.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "KADRemote-Agent/1.4");

        _tunnel.TunnelUrlChanged += OnTunnelUrlChanged;
        _config.ExeStatusChanged += OnExeStatusChanged;
        _peers.PeerExeAlertDetected += OnPeerExeAlertDetected;
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

    private void OnExeStatusChanged(bool missing, string? message)
    {
        SignalWake();
    }

    private void OnPeerExeAlertDetected(PeerInfoDto peer)
    {
        _pendingPeerAlerts.Enqueue(peer);
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
        int failCount = 0;
        while (!ct.IsCancellationRequested)
        {
            while (_pendingPeerAlerts.TryDequeue(out var peerAlert))
            {
                await PublishPeerAlertAsync(peerAlert, ct);
            }

            bool ok = await PublishAnnouncementAsync(ct);
            failCount = ok ? 0 : failCount + 1;

            int waitMs = ok
                ? (string.IsNullOrWhiteSpace(_tunnel.PublicUrl) && _config.Config.EnableCloudflareTunnel ? 15_000 : 5 * 60 * 1000)
                : Math.Min(60_000, 5_000 * failCount);

            try
            {
                await _wakeSignal.WaitAsync(waitMs, ct);
                await Task.Delay(250, ct);
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
                    // Also re-enqueue any peers currently flagged with ExeMissing
                    foreach (var p in _peers.GetPeers().Where(p => p.MachineId != _config.MachineId && p.ExeMissing))
                    {
                        _pendingPeerAlerts.Enqueue(p);
                    }
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
            _config.CheckExeHealthNow();
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
                TimestampUtc: DateTimeOffset.UtcNow,
                ExeMissing: _config.IsExeMissing,
                ExeStatusMessage: _config.ExeStatusMessage
            );

            return await SendEncryptedDtoAsync(dto, ct);
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

    private async Task PublishPeerAlertAsync(PeerInfoDto peer, CancellationToken ct)
    {
        try
        {
            var dto = new CloudAnnouncementDto(
                Type: "peer_exe_alert",
                MachineId: peer.MachineId,
                DeviceName: peer.DeviceName,
                AgentPort: peer.AgentPort,
                LocalUrls: peer.LocalUrls,
                TunnelUrl: peer.TunnelUrl,
                CpuUsagePercent: peer.CpuUsagePercent,
                TotalMemoryBytes: peer.TotalMemoryBytes,
                UsedMemoryBytes: peer.UsedMemoryBytes,
                UptimeSeconds: peer.UptimeSeconds,
                TimestampUtc: DateTimeOffset.UtcNow,
                ExeMissing: peer.ExeMissing,
                ExeStatusMessage: peer.ExeStatusMessage
            );
            await SendEncryptedDtoAsync(dto, ct);
        }
        catch { }
    }

    private async Task<bool> SendEncryptedDtoAsync(CloudAnnouncementDto dto, CancellationToken ct)
    {
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(dto, AgentJsonContext.Default.CloudAnnouncementDto);
        var sealedPayload = EncryptPayload(plaintext);

        using var content = new StringContent(sealedPayload, Encoding.UTF8, "text/plain");
        using var req = new HttpRequestMessage(HttpMethod.Post, $"{RelayEndpoint}/{_topic}")
        {
            Content = content
        };
        req.Headers.TryAddWithoutValidation("Title", "kad");
        req.Headers.TryAddWithoutValidation("Cache", "yes");
        if (dto.ExeMissing)
            req.Headers.TryAddWithoutValidation("Priority", "high");

        using var resp = await _http.SendAsync(req, ct);
        if (resp.IsSuccessStatusCode)
        {
            AgentLog.Info("CloudSync", $"Published encrypted announcement for {dto.DeviceName} (tunnel={dto.TunnelUrl ?? "pending"}, exeMissing={dto.ExeMissing})");
            return true;
        }

        AgentLog.Warn("CloudSync", $"Publish returned HTTP {(int)resp.StatusCode}");
        return false;
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
        _config.ExeStatusChanged -= OnExeStatusChanged;
        _peers.PeerExeAlertDetected -= OnPeerExeAlertDetected;
        _cts.Cancel();
        _http.Dispose();
        _streamHttp.Dispose();
        _wakeSignal.Dispose();
        _cts.Dispose();
    }
}
