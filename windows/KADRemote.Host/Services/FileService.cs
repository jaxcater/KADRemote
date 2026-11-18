using System.Diagnostics;
using System.IO;
using KADRemote.Host.Models;

namespace KADRemote.Host.Services;

public sealed class FileService
{
    private readonly LogService _log;

    public FileService(LogService log)
    {
        _log = log;
    }

    public object GetQuickRoots()
    {
        var shortcuts = new List<object>
        {
            new { name = "Desktop", path = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) },
            new { name = "Downloads", path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads") },
            new { name = "Documents", path = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) },
            new { name = "User Home", path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) }
        };

        var drives = DriveInfo.GetDrives()
            .Where(d => d.IsReady)
            .Select(d => new
            {
                name = d.Name,
                label = string.IsNullOrWhiteSpace(d.VolumeLabel) ? d.DriveType.ToString() : d.VolumeLabel,
                totalBytes = d.TotalSize,
                freeBytes = d.AvailableFreeSpace
            })
            .ToList();

        return new { shortcuts, drives };
    }

    public FileListResponse ListDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            path = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        var dirInfo = new DirectoryInfo(path);
        if (!dirInfo.Exists)
            throw new DirectoryNotFoundException($"Không tìm thấy thư mục: {path}");

        var entries = new List<FileEntryDto>();

        foreach (var sub in dirInfo.EnumerateDirectories())
        {
            try
            {
                entries.Add(new FileEntryDto(
                    Name: sub.Name,
                    FullPath: sub.FullName,
                    IsDirectory: true,
                    SizeBytes: 0,
                    LastModifiedUtc: sub.LastWriteTimeUtc,
                    Extension: string.Empty
                ));
            }
            catch { }
        }

        foreach (var file in dirInfo.EnumerateFiles())
        {
            try
            {
                entries.Add(new FileEntryDto(
                    Name: file.Name,
                    FullPath: file.FullName,
                    IsDirectory: false,
                    SizeBytes: file.Length,
                    LastModifiedUtc: file.LastWriteTimeUtc,
                    Extension: file.Extension.ToLowerInvariant()
                ));
            }
            catch { }
        }

        var sorted = entries
            .OrderByDescending(e => e.IsDirectory)
            .ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new FileListResponse(
            CurrentPath: dirInfo.FullName,
            ParentPath: dirInfo.Parent?.FullName,
            Entries: sorted
        );
    }

    public async Task<string> SaveUploadedFileAsync(string targetDir, string fileName, Stream content, CancellationToken ct)
    {
        if (!Directory.Exists(targetDir))
            Directory.CreateDirectory(targetDir);

        var safeName = Path.GetFileName(fileName);
        if (string.IsNullOrWhiteSpace(safeName))
            safeName = $"upload_{DateTime.Now:yyyyMMdd_HHmmss}";

        var destPath = Path.Combine(targetDir, safeName);
        await using var fs = new FileStream(destPath, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true);
        await content.CopyToAsync(fs, ct);

        _log.Add("File", $"Đã nhận file từ điện thoại: {destPath}");
        return destPath;
    }

    public void CreateDirectory(string path)
    {
        Directory.CreateDirectory(path);
        _log.Add("File", $"Tạo thư mục: {path}");
    }

    public void DeletePath(string path)
    {
        if (File.Exists(path))
        {
            File.Delete(path);
            _log.Add("File", $"Đã xóa file: {path}");
        }
        else if (Directory.Exists(path))
        {
            Directory.Delete(path, recursive: true);
            _log.Add("File", $"Đã xóa thư mục: {path}");
        }
        else
        {
            throw new FileNotFoundException($"Không tìm thấy: {path}");
        }
    }

    public string RenamePath(string path, string newName)
    {
        var safeName = Path.GetFileName(newName);
        if (string.IsNullOrWhiteSpace(safeName))
            throw new ArgumentException("Tên mới không hợp lệ");

        var parent = Path.GetDirectoryName(path) ?? throw new ArgumentException("Đường dẫn không hợp lệ");
        var dest = Path.Combine(parent, safeName);

        if (File.Exists(path))
            File.Move(path, dest);
        else if (Directory.Exists(path))
            Directory.Move(path, dest);
        else
            throw new FileNotFoundException($"Không tìm thấy: {path}");

        _log.Add("File", $"Đổi tên: {path} -> {dest}");
        return dest;
    }

    public async Task<RunFileResponse> RunFileAsync(RunFileRequest req, CancellationToken ct)
    {
        if (!File.Exists(req.Path) && !Directory.Exists(req.Path))
            return new RunFileResponse(false, null, $"Không tìm thấy: {req.Path}");

        var ext = Path.GetExtension(req.Path).ToLowerInvariant();
        _log.Add("Run", $"Chạy từ xa: {req.Path} {req.Args}");

        try
        {
            ProcessStartInfo psi;
            if (ext == ".ps1")
            {
                psi = new ProcessStartInfo
                {
                    FileName = "powershell.exe",
                    Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{req.Path}\" {req.Args}".Trim(),
                    WorkingDirectory = Path.GetDirectoryName(req.Path) ?? "",
                    UseShellExecute = !req.WaitForExit,
                    RedirectStandardOutput = req.WaitForExit,
                    RedirectStandardError = req.WaitForExit,
                    CreateNoWindow = req.WaitForExit
                };
            }
            else if (req.WaitForExit && ext is ".exe" or ".bat" or ".cmd")
            {
                psi = new ProcessStartInfo
                {
                    FileName = ext is ".bat" or ".cmd" ? "cmd.exe" : req.Path,
                    Arguments = ext is ".bat" or ".cmd" ? $"/c \"\"{req.Path}\" {req.Args}\"" : (req.Args ?? ""),
                    WorkingDirectory = Path.GetDirectoryName(req.Path) ?? "",
                    UseShellExecute = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    CreateNoWindow = true
                };
            }
            else
            {
                psi = new ProcessStartInfo
                {
                    FileName = req.Path,
                    Arguments = req.Args ?? "",
                    WorkingDirectory = Path.GetDirectoryName(req.Path) ?? "",
                    UseShellExecute = true
                };
            }

            if (req.AsAdmin && psi.UseShellExecute)
                psi.Verb = "runas";

            using var proc = Process.Start(psi);
            if (proc == null)
                return new RunFileResponse(true, null, "Đã mở qua Windows Shell");

            if (req.WaitForExit && !psi.UseShellExecute)
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeout.CancelAfter(TimeSpan.FromSeconds(60));
                var stdout = await proc.StandardOutput.ReadToEndAsync(timeout.Token);
                var stderr = await proc.StandardError.ReadToEndAsync(timeout.Token);
                await proc.WaitForExitAsync(timeout.Token);
                var combined = string.IsNullOrWhiteSpace(stderr) ? stdout : $"{stdout}\n[STDERR]\n{stderr}";
                return new RunFileResponse(true, proc.Id, "Đã chạy xong", combined.Trim(), proc.ExitCode);
            }

            return new RunFileResponse(true, proc.Id, $"Đã khởi chạy (PID {proc.Id})");
        }
        catch (Exception ex)
        {
            return new RunFileResponse(false, null, ex.Message);
        }
    }
}
