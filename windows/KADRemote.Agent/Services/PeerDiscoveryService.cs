using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Agent.Models;

namespace KADRemote.Agent.Services;

/// <summary>
/// Exchanges lightweight authenticated LAN beacons among KADRemote agents sharing the same token,
/// so any single reachable agent over Cloudflare Tunnel can report fresh Tunnel URLs for rebooted LAN peers.
/// </summary>
public sealed class PeerDiscoveryService : IDisposable
{
    private readonly AgentConfigService _config;
    private readonly SystemService _system;
    private readonly CloudflareTunnelService _tunnel;
    private readonly string _tokenHash;
    private readonly int _peerPort;
    private readonly ConcurrentDictionary<string, PeerInfoDto> _peers = new();
    private readonly CancellationTokenSource _cts = new();

    private UdpClient? _listener;
    private Task? _listenTask;
    private Task? _broadcastTask;

    public PeerDiscoveryService(AgentConfigService config, SystemService system, CloudflareTunnelService tunnel)
    {
        _config = config;
        _system = system;
        _tunnel = tunnel;
        _peerPort = Math.Clamp(config.Config.ControllerPort + 1, 1025, 65535);
        _tokenHash = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(config.Config.ControllerToken))
        ).ToLowerInvariant();
    }

    public void Start()
    {
        if (_listenTask != null) return;
        _listenTask = Task.Run(() => ListenLoopAsync(_cts.Token));
        _broadcastTask = Task.Run(() => BroadcastLoopAsync(_cts.Token));
        _tunnel.TunnelUrlChanged += OnTunnelUrlChanged;
    }

    private void OnTunnelUrlChanged(string? url)
    {
        _ = Task.Run(() => SendBeaconAsync(_cts.Token));
    }

    public List<PeerInfoDto> GetPeers()
    {
        var cutoff = DateTimeOffset.UtcNow.AddSeconds(-120);
        foreach (var kv in _peers)
        {
            if (kv.Value.LastSeenUtc < cutoff)
                _peers.TryRemove(kv.Key, out _);
        }

        // Always include self with freshest info
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
            LastSeenUtc: DateTimeOffset.UtcNow
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

                if (type != "peer_beacon") continue;
                var pkt = JsonSerializer.Deserialize(res.Buffer, AgentJsonContext.Default.UdpPeerBeaconPacket);
                if (pkt == null) continue;
                if (!string.Equals(pkt.TokenHash, _tokenHash, StringComparison.OrdinalIgnoreCase)) continue;
                if (string.IsNullOrWhiteSpace(pkt.MachineId) || pkt.MachineId == _config.MachineId) continue;

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
                    LastSeenUtc: DateTimeOffset.UtcNow
                );
                _peers[pkt.MachineId] = info;
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
            try { await Task.Delay(20_000, ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    private byte[] BuildBeaconBytes()
    {
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
            UptimeSeconds: Environment.TickCount64 / 1000
        );
        return JsonSerializer.SerializeToUtf8Bytes(pkt, AgentJsonContext.Default.UdpPeerBeaconPacket);
    }

    private async Task SendBeaconAsync(CancellationToken ct)
    {
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

    public void Dispose()
    {
        _tunnel.TunnelUrlChanged -= OnTunnelUrlChanged;
        _cts.Cancel();
        _listener?.Dispose();
        _cts.Dispose();
    }
}
