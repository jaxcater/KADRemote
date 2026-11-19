using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Agent.Models;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace KADRemote.Agent.Services;

public sealed class AgentApiServer : IAsyncDisposable
{
    private readonly AgentConfigService _config;
    private readonly SystemService _system;
    private readonly ScreenCaptureService _screen;
    private readonly InputSimulationService _input;
    private readonly PowerShellService _powershell;
    private readonly FileService _files;
    private readonly CloudflareTunnelService _tunnel;
    private readonly PeerDiscoveryService _peers;

    private WebApplication? _app;

    public AgentApiServer(
        AgentConfigService config,
        SystemService system,
        ScreenCaptureService screen,
        InputSimulationService input,
        PowerShellService powershell,
        FileService files,
        CloudflareTunnelService tunnel,
        PeerDiscoveryService peers)
    {
        _config = config;
        _system = system;
        _screen = screen;
        _input = input;
        _powershell = powershell;
        _files = files;
        _tunnel = tunnel;
        _peers = peers;
    }

    public async Task StartAsync()
    {
        if (_app != null) return;

        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();

        builder.Services.ConfigureHttpJsonOptions(opts =>
        {
            opts.SerializerOptions.TypeInfoResolverChain.Insert(0, AgentJsonContext.Default);
        });

        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            kestrel.Limits.MaxRequestBodySize = null;
            kestrel.ListenAnyIP(_config.Config.AgentPort);
        });

        builder.Services.Configure<FormOptions>(opts =>
        {
            opts.MultipartBodyLengthLimit = long.MaxValue;
        });

        var app = builder.Build();
        app.UseWebSockets(new WebSocketOptions
        {
            KeepAliveInterval = TimeSpan.FromSeconds(20)
        });

        app.MapGet("/api/health", () =>
        {
            _config.CheckExeHealthNow();
            return Results.Ok(new HealthResponse(
                "KADRemote",
                "1.4.0",
                "online",
                "headless-agent",
                _config.IsExeMissing,
                _config.ExeStatusMessage
            ));
        });

        app.MapPost("/api/agent/shutdown", (HttpContext ctx) =>
        {
            var remoteIp = ctx.Connection.RemoteIpAddress;
            bool isLoopback = remoteIp != null && System.Net.IPAddress.IsLoopback(remoteIp);
            if (!isLoopback && !IsAuthorized(ctx.Request))
                return Results.Unauthorized();

            AgentLog.Info("Lifecycle", "Received local shutdown request for self-upgrade/replacement.");
            _ = Task.Run(async () =>
            {
                await Task.Delay(150);
                _tunnel.Dispose();
                Environment.Exit(0);
            });
            return Results.Ok(new OkResponse(true, "Shutting down"));
        });

        app.Use(async (ctx, next) =>
        {
            if (ctx.Request.Path == "/api/health" || ctx.Request.Path == "/api/agent/shutdown")
            {
                await next();
                return;
            }

            if (!IsAuthorized(ctx.Request))
            {
                ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                await ctx.Response.WriteAsJsonAsync(new ErrorResponse("Unauthorized: Token không hợp lệ"), AgentJsonContext.Default.ErrorResponse);
                return;
            }

            await next();
        });

        app.MapGet("/api/ping", () =>
        {
            _config.CheckExeHealthNow();
            return Results.Ok(new PingResponse(
                true,
                _config.DeviceName,
                DateTimeOffset.UtcNow,
                _config.IsExeMissing,
                _config.ExeStatusMessage
            ));
        });

        app.MapGet("/api/peers", () => Results.Ok(_peers.GetPeers()));

        app.MapGet("/api/system/info", () =>
        {
            _config.CheckExeHealthNow();
            return Results.Ok(_system.GetSystemInfo(
                _config.DeviceName,
                _config.Config.AgentPort,
                _tunnel.PublicUrl,
                _config.MachineId,
                _config.IsExeMissing,
                _config.ExeStatusMessage,
                _config.PrimaryExePath
            ));
        });

        app.MapGet("/api/processes", () => Results.Ok(_system.GetProcesses()));

        app.MapPost("/api/processes/kill", (KillProcessRequest req) =>
        {
            var (ok, msg) = _system.KillProcess(req.Pid);
            return ok ? Results.Ok(new OkResponse(ok, msg)) : Results.BadRequest(new OkResponse(ok, msg));
        });

        app.MapPost("/api/system/power", (PowerActionRequest req) =>
        {
            var (ok, msg) = _system.ExecutePowerAction(req.Action);
            return ok ? Results.Ok(new OkResponse(ok, msg)) : Results.BadRequest(new OkResponse(ok, msg));
        });

        app.MapPost("/api/ps/exec", async (PsExecRequest req, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(req.Command))
                return Results.BadRequest(new ErrorResponse("Lệnh trống"));
            return Results.Ok(await _powershell.ExecuteAsync(req, ct));
        });

        app.Map("/ws/ps", async (HttpContext ctx) =>
        {
            if (!ctx.WebSockets.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 400;
                return;
            }
            using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
            await _powershell.HandleWebSocketAsync(ws, ctx.RequestAborted);
        });

        app.MapGet("/api/files/drives", () => Results.Ok(_files.GetQuickRoots()));

        app.MapGet("/api/files/list", (string? path) =>
        {
            try { return Results.Ok(_files.ListDirectory(path)); }
            catch (Exception ex) { return Results.BadRequest(new ErrorResponse(ex.Message)); }
        });

        app.MapGet("/api/files/download", (string path) =>
        {
            if (!File.Exists(path))
                return Results.NotFound(new ErrorResponse("Không tìm thấy file"));
            var fileName = Path.GetFileName(path);
            return Results.File(path, "application/octet-stream", fileName, enableRangeProcessing: true);
        });

        app.MapPost("/api/files/upload", async (HttpRequest req, CancellationToken ct) =>
        {
            var dir = req.Query["dir"].FirstOrDefault();
            if (string.IsNullOrWhiteSpace(dir))
                dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

            var savedPaths = new List<string>();
            if (req.HasFormContentType)
            {
                var form = await req.ReadFormAsync(ct);
                foreach (var file in form.Files)
                {
                    await using var stream = file.OpenReadStream();
                    savedPaths.Add(await _files.SaveUploadedFileAsync(dir, file.FileName, stream, ct));
                }
            }
            else
            {
                var fileName = req.Query["filename"].FirstOrDefault()
                    ?? req.Headers["X-File-Name"].FirstOrDefault()
                    ?? $"upload_{DateTime.Now:yyyyMMdd_HHmmss}.bin";
                fileName = Uri.UnescapeDataString(fileName);
                savedPaths.Add(await _files.SaveUploadedFileAsync(dir, fileName, req.Body, ct));
            }

            if (savedPaths.Count == 0)
                return Results.BadRequest(new ErrorResponse("Không có file nào được gửi lên"));

            return Results.Ok(new UploadResponse(true, savedPaths));
        });

        app.MapPost("/api/files/mkdir", (MkdirRequest req) =>
        {
            try { _files.CreateDirectory(req.Path); return Results.Ok(new OkResponse(true)); }
            catch (Exception ex) { return Results.BadRequest(new ErrorResponse(ex.Message)); }
        });

        app.MapPost("/api/files/delete", (DeletePathRequest req) =>
        {
            try { _files.DeletePath(req.Path); return Results.Ok(new OkResponse(true)); }
            catch (Exception ex) { return Results.BadRequest(new ErrorResponse(ex.Message)); }
        });

        app.MapPost("/api/files/rename", (RenamePathRequest req) =>
        {
            try { return Results.Ok(new OkResponse(true, Path: _files.RenamePath(req.Path, req.NewName))); }
            catch (Exception ex) { return Results.BadRequest(new ErrorResponse(ex.Message)); }
        });

        app.MapPost("/api/files/run", async (RunFileRequest req, CancellationToken ct) =>
        {
            var res = await _files.RunFileAsync(req, ct);
            return res.Started ? Results.Ok(res) : Results.BadRequest(res);
        });

        app.MapGet("/api/screen/monitors", () => Results.Ok(_screen.GetMonitors()));

        app.MapGet("/api/screen/snapshot", (int? monitor, int? quality, double? scale) =>
        {
            var bytes = _screen.CaptureJpeg(monitor ?? 0, quality ?? 70, scale ?? 0.75);
            return bytes.Length == 0
                ? Results.Problem("Không thể chụp màn hình")
                : Results.File(bytes, "image/jpeg");
        });

        app.Map("/ws/screen", async (HttpContext ctx) =>
        {
            if (!ctx.WebSockets.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 400;
                return;
            }

            int monitor = int.TryParse(ctx.Request.Query["monitor"], out var m) ? m : 0;
            int fps = int.TryParse(ctx.Request.Query["fps"], out var f) ? Math.Clamp(f, 1, 24) : 8;
            int quality = int.TryParse(ctx.Request.Query["quality"], out var q) ? Math.Clamp(q, 15, 95) : 55;
            double scale = double.TryParse(ctx.Request.Query["scale"], out var s) ? Math.Clamp(s, 0.25, 1.0) : 0.6;

            using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
            using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);

            var readTask = Task.Run(async () =>
            {
                var buf = new byte[16 * 1024];
                try
                {
                    while (ws.State == WebSocketState.Open && !sessionCts.IsCancellationRequested)
                    {
                        var result = await ws.ReceiveAsync(buf, sessionCts.Token);
                        if (result.MessageType == WebSocketMessageType.Close) break;

                        var text = Encoding.UTF8.GetString(buf, 0, result.Count);
                        var msg = JsonSerializer.Deserialize(text, AgentJsonContext.Default.ScreenInputMessage);
                        if (msg == null) continue;

                        if (string.Equals(msg.Type, "config", StringComparison.OrdinalIgnoreCase))
                        {
                            if (msg.Fps.HasValue) fps = Math.Clamp(msg.Fps.Value, 1, 24);
                            if (msg.Quality.HasValue) quality = Math.Clamp(msg.Quality.Value, 15, 95);
                            if (msg.Scale.HasValue) scale = Math.Clamp(msg.Scale.Value, 0.25, 1.0);
                            monitor = msg.Monitor;
                        }
                        else
                        {
                            _input.HandleInput(msg);
                        }
                    }
                }
                catch { }
                finally { sessionCts.Cancel(); }
            }, sessionCts.Token);

            try
            {
                while (ws.State == WebSocketState.Open && !sessionCts.IsCancellationRequested)
                {
                    var frameStart = Environment.TickCount64;
                    var jpeg = _screen.CaptureJpeg(monitor, quality, scale);
                    if (jpeg.Length > 0 && ws.State == WebSocketState.Open)
                        await ws.SendAsync(jpeg, WebSocketMessageType.Binary, true, sessionCts.Token);

                    int targetDelay = 1000 / Math.Max(1, fps);
                    int remaining = targetDelay - (int)(Environment.TickCount64 - frameStart);
                    if (remaining > 5)
                        await Task.Delay(remaining, sessionCts.Token);
                }
            }
            catch { }
            finally
            {
                sessionCts.Cancel();
                try { await readTask; } catch { }
            }
        });

        _app = app;
        await app.StartAsync();
    }

    private bool IsAuthorized(HttpRequest req)
    {
        // Local loopback relay from ControllerLinkService is trusted only with token
        var expected = _config.Config.ControllerToken;
        if (string.IsNullOrEmpty(expected)) return false;

        string? provided = null;
        if (req.Headers.TryGetValue("Authorization", out var authHeader))
        {
            var raw = authHeader.ToString();
            if (raw.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
                provided = raw["Bearer ".Length..].Trim();
        }

        provided ??= req.Query["token"].FirstOrDefault();
        if (string.IsNullOrEmpty(provided)) return false;

        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(expected),
            Encoding.UTF8.GetBytes(provided)
        );
    }

    public async ValueTask DisposeAsync()
    {
        if (_app == null) return;
        try
        {
            await _app.StopAsync();
            await _app.DisposeAsync();
        }
        catch { }
        finally { _app = null; }
    }
}
