namespace KADRemote.Host.Models;

public sealed class AppConfig
{
    public int Port { get; set; } = 7788;
    public string Token { get; set; } = string.Empty;
    public string DeviceName { get; set; } = Environment.MachineName;
    public bool StartWithWindows { get; set; } = false;
    public bool AutoStartTunnel { get; set; } = true;
    public bool MinimizeToTrayOnClose { get; set; } = true;
    public string DefaultShellDirectory { get; set; } = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
}
