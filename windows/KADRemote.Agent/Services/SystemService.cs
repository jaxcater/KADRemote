using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using KADRemote.Agent.Models;

namespace KADRemote.Agent.Services;

public sealed class SystemService
{
    private ulong _prevIdle;
    private ulong _prevKernel;
    private ulong _prevUser;
    private bool _hasPrevCpu;

    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME
    {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
        public ulong ToUInt64() => ((ulong)dwHighDateTime << 32) | dwLowDateTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(out FILETIME lpIdleTime, out FILETIME lpKernelTime, out FILETIME lpUserTime);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool LockWorkStation();

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

    private const int SM_CMONITORS = 80;

    public double GetCpuUsagePercent()
    {
        if (!GetSystemTimes(out var idleFt, out var kernelFt, out var userFt))
            return 0;

        ulong idle = idleFt.ToUInt64();
        ulong kernel = kernelFt.ToUInt64();
        ulong user = userFt.ToUInt64();

        if (!_hasPrevCpu)
        {
            _prevIdle = idle;
            _prevKernel = kernel;
            _prevUser = user;
            _hasPrevCpu = true;
            return 0;
        }

        ulong idleDiff = idle - _prevIdle;
        ulong kernelDiff = kernel - _prevKernel;
        ulong userDiff = user - _prevUser;

        _prevIdle = idle;
        _prevKernel = kernel;
        _prevUser = user;

        ulong total = kernelDiff + userDiff;
        if (total == 0) return 0;

        double usage = (double)(total - idleDiff) / total * 100.0;
        return Math.Round(Math.Clamp(usage, 0, 100), 1);
    }

    public (long total, long used) GetMemoryBytes()
    {
        var mem = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        if (!GlobalMemoryStatusEx(ref mem))
            return (0, 0);

        long total = (long)mem.ullTotalPhys;
        long used = (long)(mem.ullTotalPhys - mem.ullAvailPhys);
        return (total, used);
    }

    public List<string> GetLocalUrls(int port)
    {
        var candidates = new List<(string Url, int Score)>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;

                var desc = $"{ni.Name} {ni.Description}".ToLowerInvariant();
                bool isVirtual = desc.Contains("virtualbox")
                    || desc.Contains("vmware")
                    || desc.Contains("hyper-v")
                    || desc.Contains("vethernet")
                    || desc.Contains("wsl")
                    || desc.Contains("docker")
                    || desc.Contains("loopback");

                bool isVpn = desc.Contains("tailscale")
                    || desc.Contains("wireguard")
                    || desc.Contains("zerotier")
                    || desc.Contains("wintun");

                var props = ni.GetIPProperties();
                bool hasGateway = props.GatewayAddresses.Any(g =>
                    g.Address.AddressFamily == AddressFamily.InterNetwork &&
                    !g.Address.Equals(System.Net.IPAddress.Any));

                foreach (var addr in props.UnicastAddresses)
                {
                    if (addr.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    var ip = addr.Address.ToString();
                    if (ip.StartsWith("169.254.", StringComparison.Ordinal)) continue;

                    int score = 0;
                    if (hasGateway && !isVirtual) score += 100;
                    if (isVpn || ip.StartsWith("100.", StringComparison.Ordinal)) score += 60;
                    if (ip.StartsWith("192.168.", StringComparison.Ordinal) || ip.StartsWith("10.", StringComparison.Ordinal)) score += 20;
                    if (isVirtual) score -= 80;
                    if (ip.StartsWith("192.168.56.", StringComparison.Ordinal)) score -= 50; // VirtualBox default host-only

                    candidates.Add(($"http://{ip}:{port}", score));
                }
            }
        }
        catch { }

        return candidates
            .OrderByDescending(c => c.Score)
            .Select(c => c.Url)
            .Distinct()
            .ToList();
    }

    public SystemInfoDto GetSystemInfo(string deviceName, int port, string? tunnelUrl = null, string? machineId = null)
    {
        var (totalMem, usedMem) = GetMemoryBytes();
        var disks = new List<DiskInfoDto>();

        foreach (var d in DriveInfo.GetDrives())
        {
            try
            {
                if (!d.IsReady) continue;
                disks.Add(new DiskInfoDto(
                    d.Name.TrimEnd('\\'),
                    string.IsNullOrWhiteSpace(d.VolumeLabel) ? d.DriveType.ToString() : d.VolumeLabel,
                    d.TotalSize,
                    d.AvailableFreeSpace
                ));
            }
            catch { }
        }

        int monitors = Math.Max(1, GetSystemMetrics(SM_CMONITORS));

        return new SystemInfoDto(
            DeviceName: deviceName,
            OsVersion: Environment.OSVersion.VersionString,
            UserName: Environment.UserName,
            CpuUsagePercent: GetCpuUsagePercent(),
            TotalMemoryBytes: totalMem,
            UsedMemoryBytes: usedMem,
            UptimeSeconds: Environment.TickCount64 / 1000,
            MonitorCount: monitors,
            Disks: disks,
            LocalUrls: GetLocalUrls(port),
            TunnelUrl: tunnelUrl,
            MachineId: machineId
        );
    }

    public List<ProcessInfoDto> GetProcesses()
    {
        var result = new List<ProcessInfoDto>();
        foreach (var proc in Process.GetProcesses())
        {
            try
            {
                result.Add(new ProcessInfoDto(
                    proc.Id,
                    proc.ProcessName,
                    proc.MainWindowTitle ?? string.Empty,
                    proc.WorkingSet64
                ));
            }
            catch { }
            finally
            {
                proc.Dispose();
            }
        }

        return result
            .OrderByDescending(p => !string.IsNullOrEmpty(p.WindowTitle))
            .ThenByDescending(p => p.MemoryBytes)
            .Take(120)
            .ToList();
    }

    public (bool ok, string message) KillProcess(int pid)
    {
        try
        {
            using var proc = Process.GetProcessById(pid);
            var name = proc.ProcessName;
            proc.Kill(entireProcessTree: true);
            return (true, $"Đã tắt tiến trình {name} (PID {pid})");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    public (bool ok, string message) ExecutePowerAction(string action)
    {
        switch (action.Trim().ToLowerInvariant())
        {
            case "lock":
                LockWorkStation();
                return (true, "Đã khóa màn hình PC");

            case "sleep":
                SetSuspendState(hibernate: false, forceCritical: false, disableWakeEvent: false);
                return (true, "PC đang chuyển sang chế độ ngủ");

            case "restart":
                Process.Start(new ProcessStartInfo("shutdown", "/r /t 5") { CreateNoWindow = true, UseShellExecute = false });
                return (true, "PC sẽ khởi động lại sau 5 giây");

            case "shutdown":
                Process.Start(new ProcessStartInfo("shutdown", "/s /t 5") { CreateNoWindow = true, UseShellExecute = false });
                return (true, "PC sẽ tắt sau 5 giây");

            case "cancel_shutdown":
                Process.Start(new ProcessStartInfo("shutdown", "/a") { CreateNoWindow = true, UseShellExecute = false });
                return (true, "Đã hủy lệnh tắt/khởi động lại");

            default:
                return (false, $"Lệnh nguồn không hợp lệ: {action}");
        }
    }
}
