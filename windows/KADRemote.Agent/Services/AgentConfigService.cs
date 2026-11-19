using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Agent.Models;
using Microsoft.Win32;

namespace KADRemote.Agent.Services;

public sealed class AgentConfigService : IDisposable
{
    private const string LegacyMagic = "KADCFG01";
    private const string SlotPrefix = "KADCFG_SLOT_V2::";
    private const string SlotResourceName = "KADRemote.ConfigSlot.txt";
    private const string RunRegKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AppRegName = "KADRemote";
    private const int MaxPayloadBytes = 64 * 1024;

    private readonly List<FileSystemWatcher> _watchers = new();
    private readonly Timer _healthTimer;
    private readonly object _healthLock = new();

    public EmbeddedAgentConfig Config { get; }
    public bool HasEmbeddedConfig { get; private set; }
    public string MachineId { get; }
    public string DeviceName { get; }
    public string DefaultShellDirectory { get; }
    public string? PrimaryExePath { get; }

    public bool IsExeMissing { get; private set; }
    public string? ExeStatusMessage { get; private set; }

    /// <summary>
    /// Fired immediately whenever Kad.exe missing/deleted state changes on disk.
    /// </summary>
    public event Action<bool, string?>? ExeStatusChanged;

    public AgentConfigService()
    {
        DeviceName = Environment.MachineName;
        MachineId = ResolveMachineId();
        PrimaryExePath = Environment.ProcessPath;

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        DefaultShellDirectory = Directory.Exists(home) ? home : AppContext.BaseDirectory;

        Config = LoadConfig();
        NormalizeConfig();

        _healthTimer = new Timer(_ => CheckExeHealthNow(), null, Timeout.Infinite, Timeout.Infinite);
    }

    private bool _startupKeyVerified;

    public void FinalizeRuntimeSetup()
    {
        if (!string.IsNullOrWhiteSpace(PrimaryExePath) && File.Exists(PrimaryExePath))
        {
            Config.WatchedExePath = PrimaryExePath;
        }

        SaveConfigBackup();
        StartExeWatchers();
        CheckExeHealthNow();
        _healthTimer.Change(TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(3));

        var hosts = string.Join(", ", GetCandidateControllerHosts());
        AgentLog.Info("Config", $"Startup: MachineId={MachineId}, Device={DeviceName}, Embedded={HasEmbeddedConfig}, Exe={PrimaryExePath}, AgentPort={Config.AgentPort}, HubPort={Config.ControllerPort}, Hosts=[{hosts}], Udp={Config.UdpDiscovery}, Tunnel={Config.EnableCloudflareTunnel}, CloudSync={Config.EnableCloudSync}");
    }

    public List<string> GetCandidateControllerHosts()
    {
        var list = new List<string>();
        if (Config.ControllerHosts != null)
        {
            foreach (var h in Config.ControllerHosts)
            {
                var trimmed = h?.Trim();
                if (!string.IsNullOrEmpty(trimmed) && !list.Contains(trimmed, StringComparer.OrdinalIgnoreCase))
                    list.Add(trimmed);
            }
        }
        var primary = Config.ControllerHost?.Trim();
        if (!string.IsNullOrEmpty(primary) && !list.Contains(primary, StringComparer.OrdinalIgnoreCase))
            list.Add(primary);
        return list;
    }

    public void RequestExistingInstanceShutdown()
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMilliseconds(1200) };
            using var resp = http.PostAsync($"http://127.0.0.1:{Config.AgentPort}/api/agent/shutdown", null).GetAwaiter().GetResult();
            if (resp.IsSuccessStatusCode)
                Thread.Sleep(450);
        }
        catch { }
    }

    private void StartExeWatchers()
    {
        var dirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        if (!string.IsNullOrWhiteSpace(PrimaryExePath))
        {
            var d = Path.GetDirectoryName(PrimaryExePath);
            if (!string.IsNullOrWhiteSpace(d) && Directory.Exists(d))
                dirs.Add(d);
        }

        if (!string.IsNullOrWhiteSpace(Config.WatchedExePath))
        {
            var d = Path.GetDirectoryName(Config.WatchedExePath);
            if (!string.IsNullOrWhiteSpace(d) && Directory.Exists(d))
                dirs.Add(d);
        }

        foreach (var dir in dirs)
        {
            try
            {
                var fsw = new FileSystemWatcher(dir, "*.exe")
                {
                    NotifyFilter = NotifyFilters.FileName | NotifyFilters.CreationTime | NotifyFilters.LastWrite | NotifyFilters.Size,
                    IncludeSubdirectories = false,
                    EnableRaisingEvents = true
                };
                fsw.Deleted += (_, _) => CheckExeHealthNow();
                fsw.Renamed += (_, _) => CheckExeHealthNow();
                fsw.Created += (_, _) => CheckExeHealthNow();
                _watchers.Add(fsw);
            }
            catch { }
        }
    }

    public void CheckExeHealthNow()
    {
        bool missing = false;
        string? missingPath = null;

        if (!string.IsNullOrWhiteSpace(PrimaryExePath) && !File.Exists(PrimaryExePath))
        {
            missing = true;
            missingPath = PrimaryExePath;
        }
        else if (!string.IsNullOrWhiteSpace(Config.WatchedExePath) && !File.Exists(Config.WatchedExePath))
        {
            missing = true;
            missingPath = Config.WatchedExePath;
        }
        else if (Config.StartWithWindows)
        {
            var regTarget = GetRegisteredStartupExePath();
            if (!string.IsNullOrWhiteSpace(regTarget) && !File.Exists(regTarget))
            {
                missing = true;
                missingPath = regTarget;
            }
        }

        string? message = missing
            ? $"CẢNH BÁO: File Kad.exe trên máy {DeviceName} đã bị mất hoặc bị Windows xóa tại: {missingPath}"
            : null;

        bool changed = false;
        lock (_healthLock)
        {
            if (IsExeMissing != missing || !string.Equals(ExeStatusMessage, message, StringComparison.Ordinal))
            {
                IsExeMissing = missing;
                ExeStatusMessage = message;
                changed = true;
            }
        }

        if (!missing && Config.StartWithWindows && !string.IsNullOrWhiteSpace(PrimaryExePath) && File.Exists(PrimaryExePath))
        {
            // Ensure startup key stays healthy after startup or if file was restored
            if (changed || !_startupKeyVerified)
            {
                _startupKeyVerified = true;
                SetRunRegistryKey(true, PrimaryExePath);
            }
        }

        if (changed)
        {
            if (missing)
                AgentLog.Warn("ExeHealth", message ?? "Kad.exe missing on disk!");
            else
                AgentLog.Info("ExeHealth", "Kad.exe file verified present on disk.");

            try { ExeStatusChanged?.Invoke(missing, message); }
            catch { }
        }
    }

    private void SaveConfigBackup()
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "KADRemote"
            );
            Directory.CreateDirectory(dir);
            var localPath = Path.Combine(dir, "agent.json");
            var bytes = JsonSerializer.SerializeToUtf8Bytes(Config, AgentJsonContext.Default.EmbeddedAgentConfig);
            File.WriteAllBytes(localPath, bytes);
        }
        catch { }
    }

    private EmbeddedAgentConfig LoadConfig()
    {
        var previousSaved = LoadLocalSavedConfig();

        // 1. Check in-place embedded resource slot (V2 - PE safe, zero EOF overlay)
        var slotConfig = TryReadEmbeddedResourceSlot();
        if (slotConfig != null)
        {
            HasEmbeddedConfig = true;
            if (string.IsNullOrWhiteSpace(slotConfig.WatchedExePath))
                slotConfig.WatchedExePath = previousSaved?.WatchedExePath;
            return slotConfig;
        }

        var exePath = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(exePath) && File.Exists(exePath))
        {
            // 2. Check in-place slot directly in file bytes or legacy trailer
            var fileSlot = TryReadFileSlot(exePath) ?? TryReadEmbeddedTrailer(exePath);
            if (fileSlot != null)
            {
                HasEmbeddedConfig = true;
                if (string.IsNullOrWhiteSpace(fileSlot.WatchedExePath))
                    fileSlot.WatchedExePath = previousSaved?.WatchedExePath;
                return fileSlot;
            }

            // 3. Check sidecar kad_config.json
            var sidecar = Path.Combine(Path.GetDirectoryName(exePath) ?? AppContext.BaseDirectory, "kad_config.json");
            if (File.Exists(sidecar))
            {
                try
                {
                    var cfg = JsonSerializer.Deserialize(File.ReadAllText(sidecar), AgentJsonContext.Default.EmbeddedAgentConfig);
                    if (cfg != null) return cfg;
                }
                catch { }
            }
        }

        // 4. Fallback to saved %LocalAppData%\KADRemote\agent.json
        if (previousSaved != null)
            return previousSaved;

        return new EmbeddedAgentConfig();
    }

    private static EmbeddedAgentConfig? LoadLocalSavedConfig()
    {
        var localPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "KADRemote",
            "agent.json"
        );
        if (File.Exists(localPath))
        {
            try
            {
                return JsonSerializer.Deserialize(File.ReadAllText(localPath), AgentJsonContext.Default.EmbeddedAgentConfig);
            }
            catch { }
        }
        return null;
    }

    private static EmbeddedAgentConfig? TryReadEmbeddedResourceSlot()
    {
        try
        {
            using var stream = typeof(AgentConfigService).Assembly.GetManifestResourceStream(SlotResourceName);
            if (stream == null) return null;
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var raw = reader.ReadToEnd();
            if (!raw.StartsWith(SlotPrefix, StringComparison.Ordinal))
                return null;

            var payload = raw[SlotPrefix.Length..].Trim();
            return ParseSlotPayload(payload);
        }
        catch
        {
            return null;
        }
    }

    private static EmbeddedAgentConfig? TryReadFileSlot(string exePath)
    {
        try
        {
            var bytes = File.ReadAllBytes(exePath);
            var marker = Encoding.ASCII.GetBytes(SlotPrefix);
            int idx = bytes.AsSpan().IndexOf(marker);
            if (idx < 0) return null;

            int start = idx + marker.Length;
            int maxLen = Math.Min(16384 - marker.Length, bytes.Length - start);
            if (maxLen <= 2) return null;

            var payload = Encoding.UTF8.GetString(bytes, start, maxLen).Trim();
            return ParseSlotPayload(payload);
        }
        catch
        {
            return null;
        }
    }

    private static EmbeddedAgentConfig? ParseSlotPayload(string payload)
    {
        if (string.IsNullOrEmpty(payload))
            return null;

        if (payload.StartsWith("B64:", StringComparison.Ordinal))
        {
            var b64 = payload[4..].Trim();
            int spaceIdx = b64.IndexOfAny(new[] { ' ', '\0', '\r', '\n' });
            if (spaceIdx > 0)
                b64 = b64[..spaceIdx];
            var decoded = Convert.FromBase64String(b64);
            return JsonSerializer.Deserialize(decoded, AgentJsonContext.Default.EmbeddedAgentConfig);
        }

        if (payload.StartsWith('{'))
        {
            return JsonSerializer.Deserialize(payload, AgentJsonContext.Default.EmbeddedAgentConfig);
        }

        return null;
    }

    private void NormalizeConfig()
    {
        if (Config.AgentPort is < 1024 or > 65535)
            Config.AgentPort = 7788;
        if (Config.ControllerPort is < 1024 or > 65535)
            Config.ControllerPort = 7789;
        if (string.IsNullOrWhiteSpace(Config.ControllerToken))
        {
            Span<byte> bytes = stackalloc byte[18];
            RandomNumberGenerator.Fill(bytes);
            Config.ControllerToken = Convert.ToBase64String(bytes)
                .Replace("+", "-")
                .Replace("/", "_")
                .TrimEnd('=');
        }
    }

    private static EmbeddedAgentConfig? TryReadEmbeddedTrailer(string exePath)
    {
        try
        {
            using var fs = new FileStream(exePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            if (fs.Length < 12) return null;

            Span<byte> magicBuf = stackalloc byte[8];
            fs.Seek(-8, SeekOrigin.End);
            fs.ReadExactly(magicBuf);

            var expectedMagic = Encoding.ASCII.GetBytes(LegacyMagic);
            if (!magicBuf.SequenceEqual(expectedMagic))
                return null;

            Span<byte> lenBuf = stackalloc byte[4];
            fs.Seek(-12, SeekOrigin.End);
            fs.ReadExactly(lenBuf);
            int payloadLen = BitConverter.ToInt32(lenBuf);
            if (payloadLen <= 2 || payloadLen > MaxPayloadBytes || fs.Length < 12 + payloadLen)
                return null;

            fs.Seek(-(12 + payloadLen), SeekOrigin.End);
            var payload = new byte[payloadLen];
            fs.ReadExactly(payload);

            return JsonSerializer.Deserialize(payload, AgentJsonContext.Default.EmbeddedAgentConfig);
        }
        catch
        {
            return null;
        }
    }

    private static string ResolveMachineId()
    {
        try
        {
            using var key = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64)
                .OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
            var guid = key?.GetValue("MachineGuid")?.ToString();
            if (!string.IsNullOrWhiteSpace(guid))
                return guid.Trim().ToLowerInvariant();
        }
        catch { }

        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "KADRemote"
            );
            Directory.CreateDirectory(dir);
            var idFile = Path.Combine(dir, "machine.id");
            if (File.Exists(idFile))
            {
                var existing = File.ReadAllText(idFile).Trim();
                if (!string.IsNullOrEmpty(existing)) return existing;
            }
            var created = Guid.NewGuid().ToString("N");
            File.WriteAllText(idFile, created);
            return created;
        }
        catch
        {
            var raw = Encoding.UTF8.GetBytes($"{Environment.MachineName}:{Environment.UserName}");
            return Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant()[..24];
        }
    }

    private static void SetRunRegistryKey(bool enabled, string exePath)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunRegKey, writable: true);
            if (key == null) return;

            if (enabled)
                key.SetValue(AppRegName, $"\"{exePath}\"");
            else
                key.DeleteValue(AppRegName, throwOnMissingValue: false);
        }
        catch { }
    }

    private static string? GetRegisteredStartupExePath()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunRegKey, writable: false);
            var raw = key?.GetValue(AppRegName)?.ToString()?.Trim();
            if (string.IsNullOrWhiteSpace(raw)) return null;
            if (raw.StartsWith('"'))
            {
                int endQuote = raw.IndexOf('"', 1);
                if (endQuote > 1)
                    return raw[1..endQuote];
            }
            return raw.Split(' ')[0];
        }
        catch
        {
            return null;
        }
    }

    public void Dispose()
    {
        _healthTimer.Dispose();
        foreach (var w in _watchers)
        {
            try { w.Dispose(); } catch { }
        }
        _watchers.Clear();
    }
}
