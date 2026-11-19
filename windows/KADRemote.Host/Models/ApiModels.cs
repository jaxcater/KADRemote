namespace KADRemote.Host.Models;

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
    string Type, // "click", "right_click", "double_click", "move", "scroll", "text", "hotkey", "config"
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
