using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Agent.Models;

namespace KADRemote.Agent.Services;

/// <summary>
/// Exchanges lightweight authenticated LAN beacons among KADRemote agents sharing the same token,
/// monitors sibling servers in the LAN farm to detect if any running Windows server lost its Kad.exe,
/// and reports peer Tunnel URLs and ExeMissing alerts to the iPhone controller.
/// </summary>
public sealed class PeerDiscoveryService : IDisposable
{
    private readonly AgentConfigService _config;
    private readonly SystemService _system;
    private readonly CloudflareTunnelService _tunnel;
    private readonly string _tokenHash;
    private readonly int _peerPort;
    private readonly ConcurrentDictionary<string, PeerInfoDto> _peers = new();
    private readonly ConcurrentDictionary<string, int> _deadAgentChecks = new();
    private readonly HttpClient _probeHttp = new() { Timeout = TimeSpan.FromSeconds(1.6) };
    private readonly CancellationTokenSource _cts = new();

    private UdpClient? _listener;
    private Task? _listenTask;
    private Task? _broadcastTask;
    private Task? _watchdogTask;

    public event Action<PeerInfoDto>? PeerExeAlertDetected;

    public PeerDiscoveryService(AgentConfigService config, SystemService system, CloudflareTunnelService tunnel)
    {
        _config = config;
        _system = system;
        _tunnel = tunnel;
        _peerPort = Math.Clamp(config.Config.ControllerPort + 1, 1025, 65535);
        _tokenHash = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(config.Config.ControllerToken))
        ).ToLowerInvariant();

        LoadPersistedPeers();
    }

    public void Start()
    {
        if (_listenTask != null) return;
        _listenTask = Task.Run(() => ListenLoopAsync(_cts.Token));
        _broadcastTask = Task.Run(() => BroadcastLoopAsync(_cts.Token));
        _watchdogTask = Task.Run(() => WatchdogLoopAsync(_cts.Token));
        _tunnel.TunnelUrlChanged += OnTunnelUrlChanged;
        _config.ExeStatusChanged += OnSelfExeStatusChanged;
    }

    private void OnTunnelUrlChanged(string? url)
    {
        _ = Task.Run(() => SendBeaconAsync(_cts.Token));
    }

    private void OnSelfExeStatusChanged(bool missing, string? message)
    {
        _ = Task.Run(() => SendBeaconAsync(_cts.Token));
    }

    public List<PeerInfoDto> GetPeers()
    {
        var cutoff = DateTimeOffset.UtcNow.AddMinutes(-30);
        foreach (var kv in _peers)
        {
            if (kv.Value.LastSeenUtc < cutoff && !kv.Value.ExeMissing)
                _peers.TryRemove(kv.Key, out _);
        }

        _config.CheckExeHealthNow();
        var (tot, used) = _system.GetMemoryBytes();
        var self = new PeerInfoDto(
            MachineId: _config.MachineId,
            DeviceName: _config.DeviceName,
            AgentPort: _config.Config.AgentPort,
            LocalUrls: _system.GetLocalUrls(_config.Config.AgentPort),
            TunnelUrl: _tunnel.PublicUrl,
            CpuUsagePercent: _system.GetCpuUsagePercent(),
            TotalMemoryBytes: tot,
            UsedMemoryBytes: used,
            UptimeSeconds: Environment.TickCount64 / 1000,
            LastSeenUtc: DateTimeOffset.UtcNow,
            ExeMissing: _config.IsExeMissing,
            ExeStatusMessage: _config.ExeStatusMessage
        );

        var list = _peers.Values.Where(p => p.MachineId != _config.MachineId).ToList();
        list.Insert(0, self);
        return list;
    }

    private async Task ListenLoopAsync(CancellationToken ct)
    {
        try
        {
            _listener = new UdpClient();
            _listener.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _listener.Client.Bind(new IPEndPoint(IPAddress.Any, _peerPort));
        }
        catch
        {
            return;
        }

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var res = await _listener.ReceiveAsync(ct);
                using var doc = JsonDocument.Parse(res.Buffer);
                var root = doc.RootElement;
                var type = root.TryGetProperty("type", out var tp) ? tp.GetString() : null;

                if (type == "discover_agent")
                {
                    var tokenHash = root.TryGetProperty("tokenHash", out var th) ? th.GetString() : null;
                    if (string.Equals(tokenHash, _tokenHash, StringComparison.OrdinalIgnoreCase))
                    {
                        var replyBytes = BuildBeaconBytes();
                        await _listener.SendAsync(replyBytes, res.RemoteEndPoint, ct);
                        AgentLog.Info("PeerDiscovery", $"Replied to iPhone agent discovery from {res.RemoteEndPoint}");
                    }
                    continue;
                }

                if (type == "peer_uninstalled")
                {
                    var tokenHash = root.TryGetProperty("tokenHash", out var th) ? th.GetString() : null;
                    var machineId = root.TryGetProperty("machineId", out var mid) ? mid.GetString() : null;
                    if (string.Equals(tokenHash, _tokenHash, StringComparison.OrdinalIgnoreCase) &&
                        !string.IsNullOrWhiteSpace(machineId))
                    {
                        _peers.TryRemove(machineId, out _);
                        _deadAgentChecks.TryRemove(machineId, out _);
                        SavePersistedPeers();
                    }
                    continue;
                }

                if (type != "peer_beacon") continue;
                var pkt = JsonSerializer.Deserialize(res.Buffer, AgentJsonContext.Default.UdpPeerBeaconPacket);
                if (pkt == null) continue;
                if (!string.Equals(pkt.TokenHash, _tokenHash, StringComparison.OrdinalIgnoreCase)) continue;
                if (string.IsNullOrWhiteSpace(pkt.MachineId) || pkt.MachineId == _config.MachineId) continue;

                bool wasMissing = _peers.TryGetValue(pkt.MachineId, out var prev) && prev.ExeMissing;
                _deadAgentChecks[pkt.MachineId] = 0;

                var info = new PeerInfoDto(
                    MachineId: pkt.MachineId,
                    DeviceName: pkt.DeviceName,
                    AgentPort: pkt.AgentPort,
                    LocalUrls: pkt.LocalUrls ?? new List<string>(),
                    TunnelUrl: pkt.TunnelUrl,
                    CpuUsagePercent: pkt.CpuUsagePercent,
                    TotalMemoryBytes: pkt.TotalMemoryBytes,
                    UsedMemoryBytes: pkt.UsedMemoryBytes,
                    UptimeSeconds: pkt.UptimeSeconds,
                    LastSeenUtc: DateTimeOffset.UtcNow,
                    ExeMissing: pkt.ExeMissing,
                    ExeStatusMessage: pkt.ExeStatusMessage
                );
                _peers[pkt.MachineId] = info;
                SavePersistedPeers();

                if (pkt.ExeMissing && !wasMissing)
                {
                    PeerExeAlertDetected?.Invoke(info);
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch { }
        }
    }

    private async Task BroadcastLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            await SendBeaconAsync(ct);
            try { await Task.Delay(18_000, ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task WatchdogLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(10_000, ct); }
            catch (OperationCanceledException) { break; }

            var staleThreshold = DateTimeOffset.UtcNow.AddSeconds(-22);
            foreach (var kv in _peers)
            {
                if (ct.IsCancellationRequested) break;
                var peer = kv.Value;
                if (peer.MachineId == _config.MachineId) continue;
                if (peer.LastSeenUtc >= staleThreshold && !peer.ExeMissing) continue;

                await CheckPeerHealthAsync(peer, ct);
            }
        }
    }

    private async Task CheckPeerHealthAsync(PeerInfoDto peer, CancellationToken ct)
    {
        foreach (var rawUrl in peer.LocalUrls)
        {
            if (!Uri.TryCreate(rawUrl, UriKind.Absolute, out var uri)) continue;
            var host = uri.Host;
            var port = uri.Port > 0 ? uri.Port : peer.AgentPort;

            var (agentAlive, connectionRefused, healthDto) = await ProbePeerAgentAsync(host, port, ct);
            if (agentAlive)
            {
                _deadAgentChecks[peer.MachineId] = 0;
                var refreshed = peer with
                {
                    LastSeenUtc = DateTimeOffset.UtcNow,
                    ExeMissing = healthDto?.ExeMissing ?? false,
                    ExeStatusMessage = healthDto?.ExeStatusMessage
                };
                _peers[peer.MachineId] = refreshed;
                if (refreshed.ExeMissing && !peer.ExeMissing)
                    PeerExeAlertDetected?.Invoke(refreshed);
                return;
            }

            bool windowsHostOnline = connectionRefused || await IsWindowsHostAliveOnLanAsync(host, ct);
            if (windowsHostOnline)
            {
                int count = _deadAgentChecks.AddOrUpdate(peer.MachineId, 1, (_, c) => c + 1);
                if (count >= 2 && !peer.ExeMissing)
                {
                    var alertMsg = $"CẢNH BÁO: Máy chủ {peer.DeviceName} ({host}) vẫn đang bật nhưng mất tiến trình Kad.exe (file Kad.exe có thể đã bị mất hoặc bị Windows xóa)!";
                    var alerted = peer with
                    {
                        ExeMissing = true,
                        ExeStatusMessage = alertMsg
                    };
                    _peers[peer.MachineId] = alerted;
                    SavePersistedPeers();
                    AgentLog.Warn("PeerWatchdog", alertMsg);
                    PeerExeAlertDetected?.Invoke(alerted);
                }
                return;
            }
        }
    }

    private async Task<(bool alive, bool refused, HealthResponse? health)> ProbePeerAgentAsync(string host, int port, CancellationToken ct)
    {
        try
        {
            using var resp = await _probeHttp.GetAsync($"http://{host}:{port}/api/health", ct);
            if (resp.IsSuccessStatusCode)
            {
                await using var s = await resp.Content.ReadAsStreamAsync(ct);
                var health = await JsonSerializer.DeserializeAsync(s, AgentJsonContext.Default.HealthResponse, ct);
                return (true, false, health);
            }
            return (true, false, null);
        }
        catch (HttpRequestException ex) when (ex.InnerException is SocketException { SocketErrorCode: SocketError.ConnectionRefused })
        {
            // TCP RST from target IP proves the Windows OS is running, but Kad.exe is not listening on AgentPort!
            return (false, true, null);
        }
        catch
        {
            return (false, false, null);
        }
    }

    private static async Task<bool> IsWindowsHostAliveOnLanAsync(string host, CancellationToken ct)
    {
        try
        {
            using var ping = new Ping();
            var reply = await ping.SendPingAsync(host, 750);
            if (reply.Status == IPStatus.Success)
                return true;
        }
        catch { }

        return false;
    }

    private byte[] BuildBeaconBytes()
    {
        _config.CheckExeHealthNow();
        var (tot, used) = _system.GetMemoryBytes();
        var pkt = new UdpPeerBeaconPacket(
            Type: "peer_beacon",
            TokenHash: _tokenHash,
            MachineId: _config.MachineId,
            DeviceName: _config.DeviceName,
            AgentPort: _config.Config.AgentPort,
            LocalUrls: _system.GetLocalUrls(_config.Config.AgentPort),
            TunnelUrl: _tunnel.PublicUrl,
            CpuUsagePercent: _system.GetCpuUsagePercent(),
            TotalMemoryBytes: tot,
            UsedMemoryBytes: used,
            UptimeSeconds: Environment.TickCount64 / 1000,
            ExeMissing: _config.IsExeMissing,
            ExeStatusMessage: _config.ExeStatusMessage
        );
        return JsonSerializer.SerializeToUtf8Bytes(pkt, AgentJsonContext.Default.UdpPeerBeaconPacket);
    }

    public async Task BroadcastUninstalledAsync()
    {
        try
        {
            using var udp = new UdpClient();
            udp.EnableBroadcast = true;
            var safeMid = JsonEncodedText.Encode(_config.MachineId).Value;
            var payload = $"{{\"type\":\"peer_uninstalled\",\"tokenHash\":\"{_tokenHash}\",\"machineId\":\"{safeMid}\"}}";
            var bytes = Encoding.UTF8.GetBytes(payload);
            foreach (var target in GetBroadcastTargets())
            {
                try { await udp.SendAsync(bytes, new IPEndPoint(target, _peerPort)); }
                catch { }
            }
        }
        catch { }
    }

    private async Task SendBeaconAsync(CancellationToken ct)
    {
        if (_config.IsUninstalling) return;
        try
        {
            using var udp = new UdpClient();
            udp.EnableBroadcast = true;

            var bytes = BuildBeaconBytes();

            foreach (var target in GetBroadcastTargets())
            {
                try { await udp.SendAsync(bytes, new IPEndPoint(target, _peerPort), ct); }
                catch { }
            }
        }
        catch { }
    }

    private static IEnumerable<IPAddress> GetBroadcastTargets()
    {
        var targets = new HashSet<IPAddress> { IPAddress.Broadcast };
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var ipBytes = ua.Address.GetAddressBytes();
                    var maskBytes = ua.IPv4Mask?.GetAddressBytes();
                    if (maskBytes is { Length: 4 })
                    {
                        var bcast = new byte[4];
                        for (int i = 0; i < 4; i++)
                            bcast[i] = (byte)(ipBytes[i] | ~maskBytes[i]);
                        targets.Add(new IPAddress(bcast));
                    }
                }
            }
        }
        catch { }
        return targets;
    }

    private static string GetPeersStorePath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KADRemote",
        "peers.json"
    );

    private void LoadPersistedPeers()
    {
        try
        {
            var path = GetPeersStorePath();
            if (!File.Exists(path)) return;
            var list = JsonSerializer.Deserialize(File.ReadAllText(path), AgentJsonContext.Default.ListPeerInfoDto);
            if (list == null) return;
            foreach (var p in list)
            {
                if (!string.IsNullOrWhiteSpace(p.MachineId) && p.MachineId != _config.MachineId)
                    _peers[p.MachineId] = p;
            }
        }
        catch { }
    }

    private void SavePersistedPeers()
    {
        try
        {
            var path = GetPeersStorePath();
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var list = _peers.Values.ToList();
            var bytes = JsonSerializer.SerializeToUtf8Bytes(list, AgentJsonContext.Default.ListPeerInfoDto);
            File.WriteAllBytes(path, bytes);
        }
        catch { }
    }

    public void Dispose()
    {
        _tunnel.TunnelUrlChanged -= OnTunnelUrlChanged;
        _config.ExeStatusChanged -= OnSelfExeStatusChanged;
        _cts.Cancel();
        _listener?.Dispose();
        _probeHttp.Dispose();
        _cts.Dispose();
    }
}
