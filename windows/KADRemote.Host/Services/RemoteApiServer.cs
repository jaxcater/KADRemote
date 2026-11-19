using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Host.Models;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace KADRemote.Host.Services;

public sealed class RemoteApiServer : IAsyncDisposable
{
    private readonly ConfigService _config;
    private readonly LogService _log;
    private readonly SystemService _system;
    private readonly ScreenCaptureService _screen;
    private readonly InputSimulationService _input;
    private readonly PowerShellService _powershell;
    private readonly FileService _files;
    private readonly CloudflareTunnelService _tunnel;

    private WebApplication? _app;
    private int _activeSockets;

    public int ActiveClients => _activeSockets;
    public bool IsRunning => _app != null;

    public event Action? ClientsChanged;

    public RemoteApiServer(
        ConfigService config,
        LogService log,
        SystemService system,
        ScreenCaptureService screen,
        InputSimulationService input,
        PowerShellService powershell,
        FileService files,
        CloudflareTunnelService tunnel)
    {
        _config = config;
        _log = log;
        _system = system;
        _screen = screen;
        _input = input;
        _powershell = powershell;
        _files = files;
        _tunnel = tunnel;
    }

    public async Task StartAsync()
    {
        if (_app != null) return;

        var builder = WebApplication.CreateBuilder();
        builder.Logging.ClearProviders();

        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            kestrel.Limits.MaxRequestBodySize = null;
            kestrel.ListenAnyIP(_config.Current.Port);
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

        // Public health probe (no secrets)
        app.MapGet("/api/health", () =>
        {
            var exePath = Environment.ProcessPath;
            bool exeMissing = !string.IsNullOrWhiteSpace(exePath) && !File.Exists(exePath);
            string? exeMsg = exeMissing
                ? $"CẢNH BÁO: File Kad.exe trên máy {_config.Current.DeviceName} đã bị mất hoặc bị Windows xóa tại: {exePath}"
                : null;
            return Results.Ok(new
            {
                app = "KADRemote",
                version = "1.4.0",
                status = "online",
                exeMissing,
                exeStatusMessage = exeMsg
            });
        });

        // Token authentication middleware for all other routes
        app.Use(async (ctx, next) =>
        {
            if (ctx.Request.Path == "/api/health")
            {
                await next();
                return;
            }

            if (!IsAuthorized(ctx.Request))
            {
                ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                await ctx.Response.WriteAsJsonAsync(new { error = "Unauthorized: Token không hợp lệ" });
                return;
            }

            await next();
        });

        // Verify token + handshake
        app.MapGet("/api/ping", () =>
        {
            var exePath = Environment.ProcessPath;
            bool exeMissing = !string.IsNullOrWhiteSpace(exePath) && !File.Exists(exePath);
            string? exeMsg = exeMissing
                ? $"CẢNH BÁO: File Kad.exe trên máy {_config.Current.DeviceName} đã bị mất hoặc bị Windows xóa tại: {exePath}"
                : null;
            return Results.Ok(new
            {
                ok = true,
                deviceName = _config.Current.DeviceName,
                timestamp = DateTimeOffset.UtcNow,
                exeMissing,
                exeStatusMessage = exeMsg
            });
        });

        app.MapPost("/api/agent/uninstall", () =>
        {
            _log.Add("Lifecycle", "Nhận lệnh gỡ bỏ hoàn toàn KAD từ iPhone.");
            _ = Task.Run(async () =>
            {
                await Task.Delay(500);
                _tunnel.Dispose();
                ConfigService.LaunchSelfWipeAndExit();
            });
            return Results.Ok(new { ok = true, message = "Đang xóa toàn bộ file KAD trên máy..." });
        });

        // System Info & Processes & Power
        app.MapGet("/api/system/info", () =>
            Results.Ok(_system.GetSystemInfo(_config.Current.DeviceName, _config.Current.Port, _tunnel.PublicUrl)));

        app.MapGet("/api/processes", () => Results.Ok(_system.GetProcesses()));

        app.MapPost("/api/processes/kill", (KillProcessRequest req) =>
        {
            var (ok, msg) = _system.KillProcess(req.Pid);
            _log.Add("Process", msg);
            return ok ? Results.Ok(new { ok, message = msg }) : Results.BadRequest(new { ok, message = msg });
        });

        app.MapPost("/api/system/power", (PowerActionRequest req) =>
        {
            var (ok, msg) = _system.ExecutePowerAction(req.Action);
            _log.Add("Power", msg);
            return ok ? Results.Ok(new { ok, message = msg }) : Results.BadRequest(new { ok, message = msg });
        });

        // PowerShell One-Shot & Interactive WebSocket
        app.MapPost("/api/ps/exec", async (PsExecRequest req, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(req.Command))
                return Results.BadRequest(new { error = "Lệnh trống" });
            var res = await _powershell.ExecuteAsync(req, ct);
            return Results.Ok(res);
        });

        app.Map("/ws/ps", async (HttpContext ctx) =>
        {
            if (!ctx.WebSockets.IsWebSocketRequest)
            {
                ctx.Response.StatusCode = 400;
                return;
            }

            using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
            TrackSocket(+1);
            try
            {
                await _powershell.HandleWebSocketAsync(ws, ctx.RequestAborted);
            }
            finally
            {
                TrackSocket(-1);
            }
        });

        // File Management & Bidirectional Transfer & Remote Run
        app.MapGet("/api/files/drives", () => Results.Ok(_files.GetQuickRoots()));

        app.MapGet("/api/files/list", (string? path) =>
        {
            try
            {
                return Results.Ok(_files.ListDirectory(path));
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { error = ex.Message });
            }
        });

        app.MapGet("/api/files/download", (string path) =>
        {
            if (!File.Exists(path))
                return Results.NotFound(new { error = "Không tìm thấy file" });

            _log.Add("File", $"Tải về điện thoại: {path}");
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
                    var saved = await _files.SaveUploadedFileAsync(dir, file.FileName, stream, ct);
                    savedPaths.Add(saved);
                }
            }
            else
            {
                var fileName = req.Query["filename"].FirstOrDefault()
                    ?? req.Headers["X-File-Name"].FirstOrDefault()
                    ?? $"upload_{DateTime.Now:yyyyMMdd_HHmmss}.bin";
                fileName = Uri.UnescapeDataString(fileName);
                var saved = await _files.SaveUploadedFileAsync(dir, fileName, req.Body, ct);
                savedPaths.Add(saved);
            }

            if (savedPaths.Count == 0)
                return Results.BadRequest(new { error = "Không có file nào được gửi lên" });

            return Results.Ok(new { ok = true, savedPaths });
        });

        app.MapPost("/api/files/mkdir", (MkdirRequest req) =>
        {
            try
            {
                _files.CreateDirectory(req.Path);
                return Results.Ok(new { ok = true });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { error = ex.Message });
            }
        });

        app.MapPost("/api/files/delete", (DeletePathRequest req) =>
        {
            try
            {
                _files.DeletePath(req.Path);
                return Results.Ok(new { ok = true });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { error = ex.Message });
            }
        });

        app.MapPost("/api/files/rename", (RenamePathRequest req) =>
        {
            try
            {
                var dest = _files.RenamePath(req.Path, req.NewName);
                return Results.Ok(new { ok = true, path = dest });
            }
            catch (Exception ex)
            {
                return Results.BadRequest(new { error = ex.Message });
            }
        });

        app.MapPost("/api/files/run", async (RunFileRequest req, CancellationToken ct) =>
        {
            var res = await _files.RunFileAsync(req, ct);
            return res.Started ? Results.Ok(res) : Results.BadRequest(res);
        });

        // Screen Streaming & Input Simulation
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
            TrackSocket(+1);
            _log.Add("Screen", $"Bắt đầu stream màn hình #{monitor} ({fps} FPS, Q={quality}%)");

            using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted);
            var jsonOpts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };

            // Reader task for touch/mouse/keyboard & stream settings
            var readTask = Task.Run(async () =>
            {
                var buf = new byte[16 * 1024];
                try
                {
                    while (ws.State == WebSocketState.Open && !sessionCts.IsCancellationRequested)
                    {
                        var result = await ws.ReceiveAsync(buf, sessionCts.Token);
                        if (result.MessageType == WebSocketMessageType.Close)
                            break;

                        var text = Encoding.UTF8.GetString(buf, 0, result.Count);
                        var msg = JsonSerializer.Deserialize<ScreenInputMessage>(text, jsonOpts);
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
                finally
                {
                    sessionCts.Cancel();
                }
            }, sessionCts.Token);

            // Writer loop: capture & stream JPEG frames
            try
            {
                while (ws.State == WebSocketState.Open && !sessionCts.IsCancellationRequested)
                {
                    var frameStart = Environment.TickCount64;
                    var jpeg = _screen.CaptureJpeg(monitor, quality, scale);
                    if (jpeg.Length > 0 && ws.State == WebSocketState.Open)
                    {
                        await ws.SendAsync(jpeg, WebSocketMessageType.Binary, true, sessionCts.Token);
                    }

                    int targetDelay = 1000 / Math.Max(1, fps);
                    int elapsed = (int)(Environment.TickCount64 - frameStart);
                    int remaining = targetDelay - elapsed;
                    if (remaining > 5)
                        await Task.Delay(remaining, sessionCts.Token);
                }
            }
            catch { }
            finally
            {
                sessionCts.Cancel();
                try { await readTask; } catch { }
                TrackSocket(-1);
                _log.Add("Screen", "Đã dừng stream màn hình");
            }
        });

        _app = app;
        await app.StartAsync();
        _log.Add("Server", $"KAD Remote đang lắng nghe tại cổng {_config.Current.Port}");
    }

    public async Task RestartAsync()
    {
        await StopAsync();
        await StartAsync();
    }

    public async Task StopAsync()
    {
        if (_app == null) return;
        try
        {
            await _app.StopAsync();
            await _app.DisposeAsync();
        }
        catch { }
        finally
        {
            _app = null;
        }
    }

    private void TrackSocket(int delta)
    {
        Interlocked.Add(ref _activeSockets, delta);
        ClientsChanged?.Invoke();
    }

    private bool IsAuthorized(HttpRequest req)
    {
        var expected = _config.Current.Token;
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
        await StopAsync();
    }
}
