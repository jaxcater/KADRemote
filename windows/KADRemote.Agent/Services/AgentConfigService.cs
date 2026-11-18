using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using KADRemote.Agent.Models;
using Microsoft.Win32;

namespace KADRemote.Agent.Services;

public sealed class AgentConfigService
{
    private const string Magic = "KADCFG01";
    private const string RunRegKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AppRegName = "KADRemote";
    private const string ScheduledTaskName = "KADRemoteAgent";
    private const int MaxPayloadBytes = 64 * 1024;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeleteFileW(string lpFileName);

    public EmbeddedAgentConfig Config { get; }
    public bool HasEmbeddedConfig { get; private set; }
    public string MachineId { get; }
    public string DeviceName { get; }
    public string DefaultShellDirectory { get; }

    public AgentConfigService()
    {
        DeviceName = Environment.MachineName;
        MachineId = ResolveMachineId();

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        DefaultShellDirectory = Directory.Exists(home) ? home : AppContext.BaseDirectory;

        Config = LoadConfig();
        NormalizeConfig();

        StripZoneIdentifier(Environment.ProcessPath);

        if (Config.StartWithWindows)
            ApplyWindowsStartup(true, Environment.ProcessPath);

        _ = Task.Run(EnsureFirewallRuleIfElevated);
    }

    /// <summary>
    /// When launched from a downloaded/shared Kad.exe (e.g. Downloads/Desktop) with StartWithWindows enabled,
    /// copies itself to %LocalAppData%\KADRemote\Kad.exe, strips MOTW, registers auto-start, and launches the installed copy
    /// so the user can move/delete the original file and the agent survives reboots on Windows 10/11.
    /// Returns true if relaunched and the current process should exit.
    /// </summary>
    public bool TrySelfInstallAndRelaunch()
    {
        if (!Config.StartWithWindows) return false;

        var currentExe = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(currentExe) || !File.Exists(currentExe))
            return false;

        var installDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "KADRemote"
        );
        var installedExe = Path.Combine(installDir, "Kad.exe");

        if (string.Equals(Path.GetFullPath(currentExe), Path.GetFullPath(installedExe), StringComparison.OrdinalIgnoreCase))
            return false;

        try
        {
            Directory.CreateDirectory(installDir);

            // Stop any previously installed instance so we can replace Kad.exe cleanly
            foreach (var proc in Process.GetProcessesByName("Kad"))
            {
                try
                {
                    if (proc.Id == Environment.ProcessId) continue;
                    string? procPath = null;
                    try { procPath = proc.MainModule?.FileName; } catch { }
                    if (procPath == null || string.Equals(Path.GetFullPath(procPath), Path.GetFullPath(installedExe), StringComparison.OrdinalIgnoreCase))
                    {
                        proc.Kill(entireProcessTree: true);
                        proc.WaitForExit(3000);
                    }
                }
                catch { }
                finally { proc.Dispose(); }
            }

            // Copy with brief retry in case file handle is still releasing
            for (int attempt = 0; attempt < 5; attempt++)
            {
                try
                {
                    File.Copy(currentExe, installedExe, overwrite: true);
                    break;
                }
                catch when (attempt < 4)
                {
                    Thread.Sleep(300);
                }
            }

            StripZoneIdentifier(installedExe);
            ApplyWindowsStartup(true, installedExe);

            Process.Start(new ProcessStartInfo
            {
                FileName = installedExe,
                WorkingDirectory = installDir,
                UseShellExecute = false,
                CreateNoWindow = true
            });

            return true;
        }
        catch
        {
            // Fallback: keep running from current location & register current path
            ApplyWindowsStartup(true, currentExe);
            return false;
        }
    }

    private EmbeddedAgentConfig LoadConfig()
    {
        var exePath = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(exePath) && File.Exists(exePath))
        {
            var embedded = TryReadEmbeddedTrailer(exePath);
            if (embedded != null)
            {
                HasEmbeddedConfig = true;
                return embedded;
            }

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

        var localPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "KADRemote",
            "agent.json"
        );
        if (File.Exists(localPath))
        {
            try
            {
                var cfg = JsonSerializer.Deserialize(File.ReadAllText(localPath), AgentJsonContext.Default.EmbeddedAgentConfig);
                if (cfg != null) return cfg;
            }
            catch { }
        }

        return new EmbeddedAgentConfig();
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

            var expectedMagic = Encoding.ASCII.GetBytes(Magic);
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

    private static void StripZoneIdentifier(string? filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath)) return;
        try { DeleteFileW(filePath + ":Zone.Identifier"); }
        catch { }
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

    private static bool IsElevated()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private static void ApplyWindowsStartup(bool enabled, string? exePath)
    {
        if (string.IsNullOrWhiteSpace(exePath)) return;

        if (enabled && IsElevated() && TryRegisterElevatedScheduledTask(exePath))
        {
            // Task Scheduler ONLOGON with HIGHEST privilege handles startup without UAC; remove Run key to avoid double-launch
            SetRunRegistryKey(false, exePath);
            return;
        }

        SetRunRegistryKey(enabled, exePath);
    }

    private static bool TryRegisterElevatedScheduledTask(string exePath)
    {
        try
        {
            using var proc = Process.Start(new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                Arguments = $"/Create /TN \"{ScheduledTaskName}\" /TR \"\\\"{exePath}\\\"\" /SC ONLOGON /RL HIGHEST /F",
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            });
            proc?.WaitForExit(5000);
            return proc is { ExitCode: 0 };
        }
        catch
        {
            return false;
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

    private void EnsureFirewallRuleIfElevated()
    {
        try
        {
            if (!IsElevated())
                return;

            int port = Config.AgentPort;
            var ruleName = $"KADRemote-TCP-{port}";

            using var check = Process.Start(new ProcessStartInfo
            {
                FileName = "netsh",
                Arguments = $"advfirewall firewall show rule name=\"{ruleName}\"",
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            });
            check?.WaitForExit(3000);
            if (check is { ExitCode: 0 })
                return;

            using var add = Process.Start(new ProcessStartInfo
            {
                FileName = "netsh",
                Arguments = $"advfirewall firewall add rule name=\"{ruleName}\" dir=in action=allow protocol=TCP localport={port}",
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            });
            add?.WaitForExit(3000);
        }
        catch { }
    }
}
