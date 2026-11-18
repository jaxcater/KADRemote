using System.IO;
using System.Security.Cryptography;
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
}
