using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using KADRemote.Host.Models;
using Microsoft.Win32;

namespace KADRemote.Host.Services;

public sealed class ConfigService
{
    private static readonly string ConfigDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "KADRemote"
    );
    private static readonly string ConfigPath = Path.Combine(ConfigDir, "config.json");
    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };
    private const string RunRegKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AppRegName = "KADRemote";

    private readonly object _lock = new();
    public AppConfig Current { get; private set; }

    public ConfigService()
    {
        Current = LoadOrCreate();
    }

    private static AppConfig LoadOrCreate()
    {
        Directory.CreateDirectory(ConfigDir);
        if (File.Exists(ConfigPath))
        {
            try
            {
                var json = File.ReadAllText(ConfigPath);
                var cfg = JsonSerializer.Deserialize<AppConfig>(json);
                if (cfg != null)
                {
                    if (string.IsNullOrWhiteSpace(cfg.Token))
                        cfg.Token = GenerateToken();
                    if (cfg.Port is < 1024 or > 65535)
                        cfg.Port = 7788;
                    if (string.IsNullOrWhiteSpace(cfg.DeviceName))
                        cfg.DeviceName = Environment.MachineName;
                    if (string.IsNullOrWhiteSpace(cfg.DefaultShellDirectory) || !Directory.Exists(cfg.DefaultShellDirectory))
                        cfg.DefaultShellDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    return cfg;
                }
            }
            catch
            {
                // Fall through to recreate default config
            }
        }

        var fresh = new AppConfig
        {
            Token = GenerateToken(),
            DeviceName = Environment.MachineName
        };
        SaveInternal(fresh);
        return fresh;
    }

    public void Save()
    {
        lock (_lock)
        {
            SaveInternal(Current);
            ApplyWindowsStartup(Current.StartWithWindows);
        }
    }

    public string RegenerateToken()
    {
        lock (_lock)
        {
            Current.Token = GenerateToken();
            SaveInternal(Current);
            return Current.Token;
        }
    }

    private static void SaveInternal(AppConfig config)
    {
        Directory.CreateDirectory(ConfigDir);
        var json = JsonSerializer.Serialize(config, JsonOpts);
        File.WriteAllText(ConfigPath, json);
    }

    public static string GenerateToken()
    {
        Span<byte> bytes = stackalloc byte[18];
        RandomNumberGenerator.Fill(bytes);
        return Convert.ToBase64String(bytes)
            .Replace("+", "-")
            .Replace("/", "_")
            .TrimEnd('=');
    }

    private static void ApplyWindowsStartup(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunRegKey, writable: true);
            if (key == null) return;

            if (enabled)
            {
                var exePath = Environment.ProcessPath;
                if (!string.IsNullOrWhiteSpace(exePath))
                    key.SetValue(AppRegName, $"\"{exePath}\" --minimized");
            }
            else
            {
                key.DeleteValue(AppRegName, throwOnMissingValue: false);
            }
        }
        catch
        {
            // Ignore registry permission errors
        }
    }

    public static void LaunchSelfWipeAndExit()
    {
        var fileTargets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var dirTargets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void AddExePath(string? p)
        {
            if (string.IsNullOrWhiteSpace(p)) return;
            var full = p.Trim();
            fileTargets.Add(full);
            var dir = Path.GetDirectoryName(full);
            if (!string.IsNullOrWhiteSpace(dir))
            {
                fileTargets.Add(Path.Combine(dir, "kad_config.json"));
                fileTargets.Add(Path.Combine(dir, "Kad.exe"));
                var leaf = Path.GetFileName(dir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                if (string.Equals(leaf, "KADRemote", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(leaf, "KAD", StringComparison.OrdinalIgnoreCase))
                {
                    dirTargets.Add(dir);
                }
            }
        }

        AddExePath(Environment.ProcessPath);
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunRegKey, writable: false);
            var raw = key?.GetValue(AppRegName)?.ToString()?.Trim();
            if (!string.IsNullOrWhiteSpace(raw))
            {
                if (raw.StartsWith('"'))
                {
                    int endQuote = raw.IndexOf('"', 1);
                    if (endQuote > 1) AddExePath(raw[1..endQuote]);
                }
                else
                {
                    AddExePath(raw.Split(' ')[0]);
                }
            }
        }
        catch { }

        var localAppDataKad = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KADRemote");
        var appDataKad = ConfigDir;
        var commonAppDataKad = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "KADRemote");
        dirTargets.Add(localAppDataKad);
        dirTargets.Add(appDataKad);
        dirTargets.Add(commonAppDataKad);

        static string PsQuote(string s) => "'" + s.Replace("'", "''") + "'";

        var filesArray = string.Join(", ", fileTargets.Select(PsQuote));
        var dirsArray = string.Join(", ", dirTargets.Select(PsQuote));
        var exeDirs = fileTargets
            .Select(p => Path.GetDirectoryName(p))
            .Where(d => !string.IsNullOrWhiteSpace(d))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(d => PsQuote(d!));
        var exeDirsArray = string.Join(", ", exeDirs);

        var psScript = $@"
$ErrorActionPreference = 'SilentlyContinue'
$targetPid = {Environment.ProcessId}
$files = @({filesArray})
$dirs = @({dirsArray})
$exeDirs = @({exeDirsArray})
$localKad = {PsQuote(localAppDataKad)}
$appKad = {PsQuote(appDataKad)}

try {{
    $p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if ($p) {{
        $null = $p.WaitForExit(4000)
        if (-not $p.HasExited) {{ Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue }}
    }}
}} catch {{}}

try {{
    Get-Process | ForEach-Object {{
        try {{
            $path = $_.Path
            if ($path -and (
                ($files -contains $path) -or
                $path.StartsWith($localKad, [StringComparison]::OrdinalIgnoreCase) -or
                $path.StartsWith($appKad, [StringComparison]::OrdinalIgnoreCase)
            )) {{
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }}
        }} catch {{}}
    }}
}} catch {{}}

foreach ($regPath in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run')) {{
    Remove-ItemProperty -Path $regPath -Name 'KADRemote' -Force -ErrorAction SilentlyContinue
}}

try {{ & schtasks.exe /Delete /TN 'KADRemote' /F 2>$null | Out-Null }} catch {{}}
try {{ Get-ScheduledTask -TaskName 'KADRemote*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue }} catch {{}}

for ($i = 0; $i -lt 15; $i++) {{
    $remaining = $false
    foreach ($f in $files) {{
        if ([string]::IsNullOrWhiteSpace($f)) {{ continue }}
        if (Test-Path -LiteralPath $f) {{
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $f) {{ $remaining = $true }}
        }}
    }}
    foreach ($ed in $exeDirs) {{
        if ([string]::IsNullOrWhiteSpace($ed) -or -not (Test-Path -LiteralPath $ed)) {{ continue }}
        Get-ChildItem -LiteralPath $ed -Filter 'KADRemote.*' -Force -ErrorAction SilentlyContinue | ForEach-Object {{
            Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
        }}
    }}
    foreach ($d in $dirs) {{
        if ([string]::IsNullOrWhiteSpace($d)) {{ continue }}
        if (Test-Path -LiteralPath $d) {{
            Remove-Item -LiteralPath $d -Force -Recurse -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $d) {{ $remaining = $true }}
        }}
    }}
    foreach ($tempRoot in @($env:TEMP, (Join-Path $env:LOCALAPPDATA 'Temp'))) {{
        if ([string]::IsNullOrWhiteSpace($tempRoot)) {{ continue }}
        $netDir = Join-Path $tempRoot '.net'
        if (Test-Path -LiteralPath $netDir) {{
            Get-ChildItem -LiteralPath $netDir -Force -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -like 'Kad*' -or $_.Name -like 'KADRemote*' }} | ForEach-Object {{
                Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
            }}
        }}
    }}
    foreach ($lnkDir in @(
        [Environment]::GetFolderPath('DesktopDirectory'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
    )) {{
        if (-not [string]::IsNullOrWhiteSpace($lnkDir) -and (Test-Path -LiteralPath $lnkDir)) {{
            foreach ($pat in @('KAD Remote*.lnk', 'KADRemote*.lnk', 'KAD Remote')) {{
                Get-ChildItem -LiteralPath $lnkDir -Filter $pat -Force -ErrorAction SilentlyContinue | ForEach-Object {{
                    Remove-Item -LiteralPath $_.FullName -Force -Recurse -ErrorAction SilentlyContinue
                }}
            }}
        }}
    }}
    if (-not $remaining) {{ break }}
    Start-Sleep -Milliseconds 400
}}
";

        try
        {
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(psScript));
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand {encoded}",
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(psi);
        }
        catch { }

        Environment.Exit(0);
    }
}
