using System.Text.Json.Serialization;

namespace KADRemote.Agent.Models;

public sealed class EmbeddedAgentConfig
{
    public string ControllerHost { get; set; } = string.Empty;
    public List<string>? ControllerHosts { get; set; }
    public int ControllerPort { get; set; } = 7789;
    public string ControllerToken { get; set; } = string.Empty;
    public int AgentPort { get; set; } = 7788;
    public bool StartWithWindows { get; set; } = true;
    public bool UdpDiscovery { get; set; } = true;
    public bool EnableCloudflareTunnel { get; set; } = true;
    public bool EnableCloudSync { get; set; } = true;
    public string? CloudflareTunnelToken { get; set; }
    public string? CloudflareTunnelUrl { get; set; }
    public string? ExportedBy { get; set; }
    public string? ExportedAt { get; set; }
    public string? WatchedExePath { get; set; }
}

public sealed record DiskInfoDto(
    string Name,
    string Label,
    long TotalBytes,
    long FreeBytes
);

public sealed record SystemInfoDto(
    string DeviceName,
    string OsVersion,
    string UserName,
    double CpuUsagePercent,
    long TotalMemoryBytes,
    long UsedMemoryBytes,
    long UptimeSeconds,
    int MonitorCount,
    List<DiskInfoDto> Disks,
    List<string> LocalUrls,
    string? TunnelUrl,
    string? MachineId = null,
    bool ExeMissing = false,
    string? ExeStatusMessage = null,
    string? ExePath = null
);

public sealed record ProcessInfoDto(
    int Pid,
    string Name,
    string WindowTitle,
    long MemoryBytes
);

public sealed record KillProcessRequest(int Pid);
public sealed record PowerActionRequest(string Action);

public sealed record PsExecRequest(
    string Command,
    string? Cwd = null,
    int TimeoutSeconds = 60
);

public sealed record PsExecResponse(
    string Stdout,
    string Stderr,
    int ExitCode,
    string Cwd,
    long DurationMs
);

public sealed record FileEntryDto(
    string Name,
    string FullPath,
    bool IsDirectory,
    long SizeBytes,
    DateTime LastModifiedUtc,
    string Extension
);

public sealed record FileListResponse(
    string CurrentPath,
    string? ParentPath,
    List<FileEntryDto> Entries
);

public sealed record QuickShortcutDto(string Name, string Path);
public sealed record QuickRootsResponse(List<QuickShortcutDto> Shortcuts, List<DiskInfoDto> Drives);

public sealed record MkdirRequest(string Path);
public sealed record DeletePathRequest(string Path);
public sealed record RenamePathRequest(string Path, string NewName);

public sealed record RunFileRequest(
    string Path,
    string? Args = null,
    bool AsAdmin = false,
    bool WaitForExit = false
);

public sealed record RunFileResponse(
    bool Started,
    int? Pid,
    string Message,
    string? Output = null,
    int? ExitCode = null
);

public sealed record MonitorInfoDto(
    int Index,
    string Name,
    int Width,
    int Height,
    int X,
    int Y,
    bool IsPrimary
);

public sealed record ScreenInputMessage(
    string Type,
    int Monitor = 0,
    double X = 0.5,
    double Y = 0.5,
    int Delta = 0,
    string? Text = null,
    string[]? Keys = null,
    int? Fps = null,
    int? Quality = null,
    double? Scale = null
);

public sealed record HealthResponse(
    string App,
    string Version,
    string Status,
    string Mode,
    bool ExeMissing = false,
    string? ExeStatusMessage = null
);

public sealed record PingResponse(
    bool Ok,
    string DeviceName,
    DateTimeOffset Timestamp,
    bool ExeMissing = false,
    string? ExeStatusMessage = null
);

public sealed record ErrorResponse(string Error);
public sealed record OkResponse(bool Ok, string? Message = null, string? Path = null);
public sealed record UploadResponse(bool Ok, List<string> SavedPaths);

public sealed record PeerInfoDto(
    string MachineId,
    string DeviceName,
    int AgentPort,
    List<string> LocalUrls,
    string? TunnelUrl,
    double CpuUsagePercent,
    long TotalMemoryBytes,
    long UsedMemoryBytes,
    long UptimeSeconds,
    DateTimeOffset LastSeenUtc,
    bool ExeMissing = false,
    string? ExeStatusMessage = null
);

public sealed record UdpPeerBeaconPacket(
    string Type,
    string TokenHash,
    string MachineId,
    string DeviceName,
    int AgentPort,
    List<string> LocalUrls,
    string? TunnelUrl,
    double CpuUsagePercent,
    long TotalMemoryBytes,
    long UsedMemoryBytes,
    long UptimeSeconds,
    bool ExeMissing = false,
    string? ExeStatusMessage = null
);

// Reverse Hub <-> Agent protocol messages
public sealed record UdpDiscoverPacket(
    string Type,
    string TokenHash,
    string MachineId,
    string DeviceName
);

public sealed record UdpAgentDiscoverPacket(
    string Type,
    string TokenHash
);

public sealed record CloudAnnouncementDto(
    string Type,
    string MachineId,
    string DeviceName,
    int AgentPort,
    List<string> LocalUrls,
    string? TunnelUrl,
    double CpuUsagePercent,
    long TotalMemoryBytes,
    long UsedMemoryBytes,
    long UptimeSeconds,
    DateTimeOffset TimestampUtc,
    bool ExeMissing = false,
    string? ExeStatusMessage = null
);

public sealed record AgentRegisterMessage(
    string Type,
    string Token,
    string MachineId,
    string DeviceName,
    string OsVersion,
    int AgentPort,
    List<string> LocalUrls,
    string? TunnelUrl,
    double CpuUsagePercent,
    long TotalMemoryBytes,
    long UsedMemoryBytes,
    long UptimeSeconds,
    bool ExeMissing = false,
    string? ExeStatusMessage = null
);

public sealed record AgentHeartbeatMessage(
    string Type,
    string MachineId,
    List<string> LocalUrls,
    string? TunnelUrl,
    double CpuUsagePercent,
    long TotalMemoryBytes,
    long UsedMemoryBytes,
    long UptimeSeconds,
    bool ExeMissing = false,
    string? ExeStatusMessage = null
);

public sealed record AgentAlertMessage(
    string Type,
    string AlertType,
    string MachineId,
    string DeviceName,
    bool ExeMissing,
    string Message,
    string? ExePath,
    DateTimeOffset TimestampUtc
);

public sealed record RelayHttpResponse(
    string Type,
    string Id,
    int StatusCode,
    string ContentType,
    string BodyBase64
);

public sealed record RelayWsEvent(
    string Type,
    string StreamId,
    bool IsBinary,
    string? Data,
    string? Error
);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(EmbeddedAgentConfig))]
[JsonSerializable(typeof(SystemInfoDto))]
[JsonSerializable(typeof(List<ProcessInfoDto>))]
[JsonSerializable(typeof(KillProcessRequest))]
[JsonSerializable(typeof(PowerActionRequest))]
[JsonSerializable(typeof(PsExecRequest))]
[JsonSerializable(typeof(PsExecResponse))]
[JsonSerializable(typeof(FileListResponse))]
[JsonSerializable(typeof(QuickRootsResponse))]
[JsonSerializable(typeof(MkdirRequest))]
[JsonSerializable(typeof(DeletePathRequest))]
[JsonSerializable(typeof(RenamePathRequest))]
[JsonSerializable(typeof(RunFileRequest))]
[JsonSerializable(typeof(RunFileResponse))]
[JsonSerializable(typeof(List<MonitorInfoDto>))]
[JsonSerializable(typeof(ScreenInputMessage))]
[JsonSerializable(typeof(HealthResponse))]
[JsonSerializable(typeof(PingResponse))]
[JsonSerializable(typeof(ErrorResponse))]
[JsonSerializable(typeof(OkResponse))]
[JsonSerializable(typeof(UploadResponse))]
[JsonSerializable(typeof(PeerInfoDto))]
[JsonSerializable(typeof(List<PeerInfoDto>))]
[JsonSerializable(typeof(UdpPeerBeaconPacket))]
[JsonSerializable(typeof(UdpDiscoverPacket))]
[JsonSerializable(typeof(UdpAgentDiscoverPacket))]
[JsonSerializable(typeof(CloudAnnouncementDto))]
[JsonSerializable(typeof(AgentRegisterMessage))]
[JsonSerializable(typeof(AgentHeartbeatMessage))]
[JsonSerializable(typeof(AgentAlertMessage))]
[JsonSerializable(typeof(RelayHttpResponse))]
[JsonSerializable(typeof(RelayWsEvent))]
public partial class AgentJsonContext : JsonSerializerContext
{
}
