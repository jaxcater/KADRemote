using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization.Metadata;
using KADRemote.Agent.Models;

namespace KADRemote.Agent.Services;

public sealed class ControllerLinkService : IAsyncDisposable
{
    private readonly AgentConfigService _config;
    private readonly SystemService _system;
    private readonly CloudflareTunnelService _tunnel;
    private readonly HttpClient _localHttp;
    private readonly ConcurrentDictionary<string, ClientWebSocket> _relayedSockets = new();
    private readonly CancellationTokenSource _cts = new();
    private SemaphoreSlim? _networkWakeSignal;
    private SemaphoreSlim? _heartbeatWakeSignal;

    private Task? _loopTask;
    private string? _activeHost;

    public ControllerLinkService(AgentConfigService config, SystemService system, CloudflareTunnelService tunnel)
    {
        _config = config;
        _system = system;
        _tunnel = tunnel;
        _activeHost = config.GetCandidateControllerHosts().FirstOrDefault();
        _networkWakeSignal = new SemaphoreSlim(0, 1);
        _heartbeatWakeSignal = new SemaphoreSlim(0, 1);
        _localHttp = new HttpClient
        {
            BaseAddress = new Uri($"http://127.0.0.1:{config.Config.AgentPort}"),
            Timeout = TimeSpan.FromSeconds(120)
        };

        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
        _tunnel.TunnelUrlChanged += OnTunnelUrlChanged;
    }

    private void OnTunnelUrlChanged(string? _)
    {
        try
        {
            if (_heartbeatWakeSignal is { CurrentCount: 0 } sem)
                sem.Release();
        }
        catch { }
    }

    private void OnNetworkChanged(object? sender, EventArgs e) => SignalNetworkWake();
    private void OnNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        if (e.IsAvailable) SignalNetworkWake();
    }

    private void SignalNetworkWake()
    {
        try
        {
            if (_networkWakeSignal is { CurrentCount: 0 } sem)
                sem.Release();
        }
        catch { }
    }

    public void Start()
    {
        _loopTask ??= Task.Run(() => RunLoopAsync(_cts.Token));
    }

    private async Task RunLoopAsync(CancellationToken ct)
    {
        int failCount = 0;

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var candidates = new List<string>();
                if (!string.IsNullOrWhiteSpace(_activeHost))
                    candidates.Add(_activeHost);
                foreach (var h in _config.GetCandidateControllerHosts())
                {
                    if (!candidates.Contains(h, StringComparer.OrdinalIgnoreCase))
                        candidates.Add(h);
                }

                bool connectedAny = false;
                foreach (var host in candidates)
                {
                    if (ct.IsCancellationRequested) break;
                    try
                    {
                        await ConnectAndServeAsync(host, _config.Config.ControllerPort, ct);
                        _activeHost = host;
                        failCount = 0;
                        connectedAny = true;
                        break;
                    }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception ex)
                    {
                        AgentLog.Warn("HubLink", $"Connect to {host}:{_config.Config.ControllerPort} failed: {ex.Message}");
                    }
                }

                if (!connectedAny && _config.Config.UdpDiscovery)
                {
                    var discovered = await DiscoverControllerIpAsync(ct);
                    if (!string.IsNullOrWhiteSpace(discovered))
                    {
                        AgentLog.Info("HubLink", $"UDP discovered controller at {discovered}");
                        _activeHost = discovered;
                        await ConnectAndServeAsync(discovered, _config.Config.ControllerPort, ct);
                        failCount = 0;
                        connectedAny = true;
                    }
                }

                if (!connectedAny)
                    failCount++;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                failCount++;
                AgentLog.Warn("HubLink", $"Hub loop error: {ex.Message}");
            }

            int delayMs = Math.Min(8000, 1500 + failCount * 1000);
            try
            {
                if (_networkWakeSignal != null)
                    await _networkWakeSignal.WaitAsync(delayMs, ct);
                else
                    await Task.Delay(delayMs, ct);
            }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task ConnectAndServeAsync(string host, int port, CancellationToken ct)
    {
        using var ws = new ClientWebSocket();
        ws.Options.KeepAliveInterval = TimeSpan.FromSeconds(15);

        using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        connectCts.CancelAfter(TimeSpan.FromSeconds(3));

        var uri = new Uri($"ws://{host}:{port}/ws/agent");
        await ws.ConnectAsync(uri, connectCts.Token);
        AgentLog.Info("HubLink", $"Connected to Hub {uri}");

        using var sendLock = new SemaphoreSlim(1, 1);

        async Task SendRawAsync(byte[] bytes, CancellationToken token)
        {
            if (ws.State != WebSocketState.Open) return;
            await sendLock.WaitAsync(token);
            try
            {
                if (ws.State == WebSocketState.Open)
                    await ws.SendAsync(bytes, WebSocketMessageType.Text, true, token);
            }
            catch { }
            finally
            {
                sendLock.Release();
            }
        }

        Task SendTypedAsync<T>(T payload, JsonTypeInfo<T> typeInfo, CancellationToken token) =>
            SendRawAsync(JsonSerializer.SerializeToUtf8Bytes(payload, typeInfo), token);

        var (totalMem, usedMem) = _system.GetMemoryBytes();
        var reg = new AgentRegisterMessage(
            Type: "register",
            Token: _config.Config.ControllerToken,
            MachineId: _config.MachineId,
            DeviceName: _config.DeviceName,
            OsVersion: Environment.OSVersion.VersionString,
            AgentPort: _config.Config.AgentPort,
            LocalUrls: _system.GetLocalUrls(_config.Config.AgentPort),
            TunnelUrl: _tunnel.PublicUrl,
            CpuUsagePercent: _system.GetCpuUsagePercent(),
            TotalMemoryBytes: totalMem,
            UsedMemoryBytes: usedMem,
            UptimeSeconds: Environment.TickCount64 / 1000
        );
        await SendTypedAsync(reg, AgentJsonContext.Default.AgentRegisterMessage, ct);

        using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(ct);

        var hbTask = Task.Run(async () =>
        {
            while (!sessionCts.IsCancellationRequested && ws.State == WebSocketState.Open)
            {
                try
                {
                    if (_heartbeatWakeSignal != null)
                        await _heartbeatWakeSignal.WaitAsync(15000, sessionCts.Token);
                    else
                        await Task.Delay(15000, sessionCts.Token);

                    var (tot, used) = _system.GetMemoryBytes();
                    var hb = new AgentHeartbeatMessage(
                        Type: "heartbeat",
                        MachineId: _config.MachineId,
                        LocalUrls: _system.GetLocalUrls(_config.Config.AgentPort),
                        TunnelUrl: _tunnel.PublicUrl,
                        CpuUsagePercent: _system.GetCpuUsagePercent(),
                        TotalMemoryBytes: tot,
                        UsedMemoryBytes: used,
                        UptimeSeconds: Environment.TickCount64 / 1000
                    );
                    await SendTypedAsync(hb, AgentJsonContext.Default.AgentHeartbeatMessage, sessionCts.Token);
                }
                catch (OperationCanceledException) { break; }
                catch { break; }
            }
        }, sessionCts.Token);

        var buf = new byte[64 * 1024];
        using var ms = new MemoryStream();
        try
        {
            while (ws.State == WebSocketState.Open && !sessionCts.IsCancellationRequested)
            {
                ms.SetLength(0);
                WebSocketReceiveResult result;
                do
                {
                    result = await ws.ReceiveAsync(buf, sessionCts.Token);
                    if (result.MessageType == WebSocketMessageType.Close)
                        return;
                    ms.Write(buf, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType != WebSocketMessageType.Text) continue;

                var text = Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
                _ = Task.Run(() => DispatchControllerMessageAsync(text, SendRawAsync, sessionCts.Token), sessionCts.Token);
            }
        }
        finally
        {
            sessionCts.Cancel();
            foreach (var kv in _relayedSockets)
            {
                if (_relayedSockets.TryRemove(kv.Key, out var rws))
                    rws.Dispose();
            }
            try { await hbTask; } catch { }
        }
    }

    private async Task DispatchControllerMessageAsync(
        string jsonText,
        Func<byte[], CancellationToken, Task> sendRaw,
        CancellationToken ct)
    {
        try
        {
            using var doc = JsonDocument.Parse(jsonText);
            var root = doc.RootElement;
            var msgType = root.TryGetProperty("type", out var tp) ? tp.GetString() : null;

            switch (msgType)
            {
                case "http_req":
                    await HandleHttpRelayAsync(root, sendRaw, ct);
                    break;

                case "ws_open":
                    await HandleWsOpenAsync(root, sendRaw, ct);
                    break;

                case "ws_msg":
                    await HandleWsMsgAsync(root, ct);
                    break;

                case "ws_close":
                    HandleWsClose(root);
                    break;
            }
        }
        catch { }
    }

    private async Task HandleHttpRelayAsync(JsonElement root, Func<byte[], CancellationToken, Task> sendRaw, CancellationToken ct)
    {
        var reqId = root.GetProperty("id").GetString() ?? "";
        var method = root.TryGetProperty("method", out var mp) ? (mp.GetString() ?? "GET") : "GET";
        var pathAndQuery = root.TryGetProperty("path", out var pp) ? (pp.GetString() ?? "/") : "/";
        var contentType = root.TryGetProperty("contentType", out var cp) ? cp.GetString() : "application/json";
        var bodyB64 = root.TryGetProperty("bodyBase64", out var bp) ? bp.GetString() : null;

        try
        {
            using var req = new HttpRequestMessage(new HttpMethod(method), pathAndQuery);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _config.Config.ControllerToken);

            if (!string.IsNullOrEmpty(bodyB64))
            {
                var rawBody = Convert.FromBase64String(bodyB64);
                req.Content = new ByteArrayContent(rawBody);
                if (!string.IsNullOrWhiteSpace(contentType))
                    req.Content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
            }

            using var resp = await _localHttp.SendAsync(req, ct);
            var respBytes = await resp.Content.ReadAsByteArrayAsync(ct);
            var respCt = resp.Content.Headers.ContentType?.ToString() ?? "application/json";

            var res = new RelayHttpResponse(
                Type: "http_res",
                Id: reqId,
                StatusCode: (int)resp.StatusCode,
                ContentType: respCt,
                BodyBase64: Convert.ToBase64String(respBytes)
            );
            await sendRaw(JsonSerializer.SerializeToUtf8Bytes(res, AgentJsonContext.Default.RelayHttpResponse), ct);
        }
        catch (Exception ex)
        {
            var errBytes = Encoding.UTF8.GetBytes(ex.Message);
            var res = new RelayHttpResponse("http_res", reqId, 502, "text/plain", Convert.ToBase64String(errBytes));
            await sendRaw(JsonSerializer.SerializeToUtf8Bytes(res, AgentJsonContext.Default.RelayHttpResponse), ct);
        }
    }

    private async Task HandleWsOpenAsync(JsonElement root, Func<byte[], CancellationToken, Task> sendRaw, CancellationToken ct)
    {
        var streamId = root.GetProperty("streamId").GetString() ?? "";
        var pathAndQuery = root.TryGetProperty("path", out var pp) ? (pp.GetString() ?? "/") : "/";
        if (string.IsNullOrEmpty(streamId)) return;

        var sep = pathAndQuery.Contains('?') ? "&" : "?";
        var localWsUri = new Uri($"ws://127.0.0.1:{_config.Config.AgentPort}{pathAndQuery}{sep}token={Uri.EscapeDataString(_config.Config.ControllerToken)}");

        var localWs = new ClientWebSocket();
        try
        {
            await localWs.ConnectAsync(localWsUri, ct);
            _relayedSockets[streamId] = localWs;

            _ = Task.Run(async () =>
            {
                var buf = new byte[128 * 1024];
                using var ms = new MemoryStream();
                try
                {
                    while (localWs.State == WebSocketState.Open && !ct.IsCancellationRequested)
                    {
                        ms.SetLength(0);
                        WebSocketReceiveResult r;
                        do
                        {
                            r = await localWs.ReceiveAsync(buf, ct);
                            if (r.MessageType == WebSocketMessageType.Close) return;
                            ms.Write(buf, 0, r.Count);
                        } while (!r.EndOfMessage);

                        bool isBin = r.MessageType == WebSocketMessageType.Binary;
                        string data = isBin
                            ? Convert.ToBase64String(ms.GetBuffer(), 0, (int)ms.Length)
                            : Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);

                        var ev = new RelayWsEvent("ws_msg", streamId, isBin, data, null);
                        await sendRaw(JsonSerializer.SerializeToUtf8Bytes(ev, AgentJsonContext.Default.RelayWsEvent), ct);
                    }
                }
                catch { }
                finally
                {
                    if (_relayedSockets.TryRemove(streamId, out var removed))
                        removed.Dispose();
                    var closed = new RelayWsEvent("ws_close", streamId, false, null, null);
                    try { await sendRaw(JsonSerializer.SerializeToUtf8Bytes(closed, AgentJsonContext.Default.RelayWsEvent), CancellationToken.None); } catch { }
                }
            }, ct);
        }
        catch (Exception ex)
        {
            localWs.Dispose();
            var ev = new RelayWsEvent("ws_close", streamId, false, null, ex.Message);
            await sendRaw(JsonSerializer.SerializeToUtf8Bytes(ev, AgentJsonContext.Default.RelayWsEvent), ct);
        }
    }

    private async Task HandleWsMsgAsync(JsonElement root, CancellationToken ct)
    {
        var streamId = root.GetProperty("streamId").GetString() ?? "";
        if (!_relayedSockets.TryGetValue(streamId, out var localWs) || localWs.State != WebSocketState.Open)
            return;

        bool isBin = root.TryGetProperty("isBinary", out var bp) && bp.GetBoolean();
        var data = root.TryGetProperty("data", out var dp) ? (dp.GetString() ?? "") : "";
        var bytes = isBin ? Convert.FromBase64String(data) : Encoding.UTF8.GetBytes(data);
        await localWs.SendAsync(bytes, isBin ? WebSocketMessageType.Binary : WebSocketMessageType.Text, true, ct);
    }

    private void HandleWsClose(JsonElement root)
    {
        var streamId = root.GetProperty("streamId").GetString() ?? "";
        if (_relayedSockets.TryRemove(streamId, out var localWs))
            localWs.Dispose();
    }

    private async Task<string?> DiscoverControllerIpAsync(CancellationToken ct)
    {
        try
        {
            using var udp = new UdpClient();
            udp.EnableBroadcast = true;

            var tokenHash = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(_config.Config.ControllerToken))
            ).ToLowerInvariant();

            var pkt = new UdpDiscoverPacket("discover", tokenHash, _config.MachineId, _config.DeviceName);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(pkt, AgentJsonContext.Default.UdpDiscoverPacket);

            int port = _config.Config.ControllerPort;
            var targets = new HashSet<IPAddress> { IPAddress.Broadcast };

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

            foreach (var target in targets)
            {
                try { await udp.SendAsync(bytes, new IPEndPoint(target, port), ct); }
                catch { }
            }

            using var waitCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            waitCts.CancelAfter(1500);
            var resp = await udp.ReceiveAsync(waitCts.Token);
            var text = Encoding.UTF8.GetString(resp.Buffer);
            using var doc = JsonDocument.Parse(text);
            if (doc.RootElement.TryGetProperty("type", out var t) && t.GetString() == "here")
                return resp.RemoteEndPoint.Address.ToString();
        }
        catch { }

        return null;
    }

    public async ValueTask DisposeAsync()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
        _tunnel.TunnelUrlChanged -= OnTunnelUrlChanged;
        _cts.Cancel();
        if (_loopTask != null)
        {
            try { await _loopTask; } catch { }
        }
        foreach (var kv in _relayedSockets)
        {
            if (_relayedSockets.TryRemove(kv.Key, out var rws))
                rws.Dispose();
        }
        _localHttp.Dispose();
        _networkWakeSignal?.Dispose();
        _networkWakeSignal = null;
        _heartbeatWakeSignal?.Dispose();
        _heartbeatWakeSignal = null;
        _cts.Dispose();
    }
}
