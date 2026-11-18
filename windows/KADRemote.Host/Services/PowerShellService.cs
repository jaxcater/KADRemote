using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using KADRemote.Host.Models;

namespace KADRemote.Host.Services;

public sealed class PowerShellService
{
    private readonly LogService _log;
    private readonly ConfigService _config;

    public PowerShellService(LogService log, ConfigService config)
    {
        _log = log;
        _config = config;
    }

    public async Task<PsExecResponse> ExecuteAsync(PsExecRequest req, CancellationToken ct)
    {
        var cwd = !string.IsNullOrWhiteSpace(req.Cwd) && Directory.Exists(req.Cwd)
            ? req.Cwd
            : _config.Current.DefaultShellDirectory;

        var sw = Stopwatch.StartNew();
        _log.Add("PowerShell", $"Exec: {req.Command}");

        // Wrap command to ensure UTF-8 output and emit final working directory marker
        const string marker = "__KAD_CWD__:";
        var script = $@"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
{req.Command}
$__kadCode = $LASTEXITCODE
Write-Output ""{marker}$((Get-Location).Path)""
if ($null -ne $__kadCode -and $__kadCode -ne 0) {{ exit $__kadCode }}
";

        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));

        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {encoded}",
            WorkingDirectory = cwd,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var proc = new Process { StartInfo = psi };
        var stdoutSb = new StringBuilder();
        var stderrSb = new StringBuilder();

        proc.Start();

        var outTask = Task.Run(async () =>
        {
            while (await proc.StandardOutput.ReadLineAsync() is { } line)
            {
                if (line.StartsWith(marker, StringComparison.Ordinal))
                {
                    var nextCwd = line[marker.Length..].Trim();
                    if (Directory.Exists(nextCwd)) cwd = nextCwd;
                }
                else
                {
                    stdoutSb.AppendLine(line);
                }
            }
        }, ct);

        var errTask = Task.Run(async () =>
        {
            while (await proc.StandardError.ReadLineAsync() is { } line)
            {
                stderrSb.AppendLine(line);
            }
        }, ct);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(req.TimeoutSeconds, 5, 600)));

        try
        {
            await proc.WaitForExitAsync(timeoutCts.Token);
            await Task.WhenAll(outTask, errTask);
        }
        catch (OperationCanceledException)
        {
            try { proc.Kill(entireProcessTree: true); } catch { }
            stderrSb.AppendLine("Lệnh đã bị hủy hoặc quá thời gian chờ.");
        }

        sw.Stop();
        return new PsExecResponse(
            Stdout: stdoutSb.ToString().TrimEnd(),
            Stderr: stderrSb.ToString().TrimEnd(),
            ExitCode: proc.HasExited ? proc.ExitCode : -1,
            Cwd: cwd,
            DurationMs: sw.ElapsedMilliseconds
        );
    }

    public async Task HandleWebSocketAsync(WebSocket ws, CancellationToken appCt)
    {
        _log.Add("PowerShell", "Phiên PowerShell tương tác đã kết nối");
        var sendLock = new SemaphoreSlim(1, 1);

        async Task SendJsonAsync(string type, string data)
        {
            if (ws.State != WebSocketState.Open) return;
            var payload = JsonSerializer.SerializeToUtf8Bytes(new { type, data });
            await sendLock.WaitAsync(appCt);
            try
            {
                if (ws.State == WebSocketState.Open)
                    await ws.SendAsync(payload, WebSocketMessageType.Text, true, appCt);
            }
            catch { }
            finally
            {
                sendLock.Release();
            }
        }

        Process StartShellProcess()
        {
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoLogo -NoExit -ExecutionPolicy Bypass -Command -",
                WorkingDirectory = _config.Current.DefaultShellDirectory,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false),
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            var p = new Process { StartInfo = psi };
            p.Start();
            p.StandardInput.WriteLine("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $OutputEncoding = [System.Text.Encoding]::UTF8");
            p.StandardInput.Flush();
            return p;
        }

        Process shell = StartShellProcess();
        using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(appCt);

        Task StartReader(StreamReader reader, string kind, Process targetProc, CancellationToken token) => Task.Run(async () =>
        {
            var buffer = new char[2048];
            try
            {
                while (!token.IsCancellationRequested && !targetProc.HasExited)
                {
                    int read = await reader.ReadAsync(buffer, 0, buffer.Length);
                    if (read <= 0) break;
                    await SendJsonAsync(kind, new string(buffer, 0, read));
                }
            }
            catch { }
        }, token);

        var outLoop = StartReader(shell.StandardOutput, "stdout", shell, sessionCts.Token);
        var errLoop = StartReader(shell.StandardError, "stderr", shell, sessionCts.Token);

        await SendJsonAsync("status", $"Connected to PowerShell ({Environment.MachineName})");

        var recvBuf = new byte[16 * 1024];
        try
        {
            while (ws.State == WebSocketState.Open && !appCt.IsCancellationRequested)
            {
                var result = await ws.ReceiveAsync(recvBuf, appCt);
                if (result.MessageType == WebSocketMessageType.Close)
                    break;

                var text = Encoding.UTF8.GetString(recvBuf, 0, result.Count);
                using var doc = JsonDocument.Parse(text);
                var root = doc.RootElement;
                var msgType = root.TryGetProperty("type", out var tp) ? tp.GetString() : "input";

                if (msgType == "interrupt")
                {
                    try { shell.Kill(entireProcessTree: true); } catch { }
                    shell.Dispose();
                    shell = StartShellProcess();
                    outLoop = StartReader(shell.StandardOutput, "stdout", shell, sessionCts.Token);
                    errLoop = StartReader(shell.StandardError, "stderr", shell, sessionCts.Token);
                    await SendJsonAsync("status", "^C - Đã khởi động lại phiên PowerShell");
                }
                else if (msgType == "input")
                {
                    var cmd = root.TryGetProperty("data", out var dp) ? dp.GetString() ?? "" : "";
                    if (!string.IsNullOrWhiteSpace(cmd))
                    {
                        _log.Add("PowerShell", $"WS: {cmd.Trim()}");
                        if (shell.HasExited)
                        {
                            shell.Dispose();
                            shell = StartShellProcess();
                            outLoop = StartReader(shell.StandardOutput, "stdout", shell, sessionCts.Token);
                            errLoop = StartReader(shell.StandardError, "stderr", shell, sessionCts.Token);
                        }
                        await shell.StandardInput.WriteLineAsync(cmd);
                        await shell.StandardInput.WriteLineAsync("Write-Output \"PS $((Get-Location).Path)>\"");
                        await shell.StandardInput.FlushAsync();
                    }
                }
            }
        }
        catch { }
        finally
        {
            sessionCts.Cancel();
            try { if (!shell.HasExited) shell.Kill(entireProcessTree: true); } catch { }
            shell.Dispose();
            _log.Add("PowerShell", "Phiên PowerShell tương tác đã đóng");
        }
    }
}
