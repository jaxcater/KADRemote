using System.Runtime.InteropServices;
using KADRemote.Agent.Services;

EnablePerMonitorDpiAwareness();

var config = new AgentConfigService();

// If launched from Downloads/Desktop with StartWithWindows=true, install to %LocalAppData%\KADRemote\Kad.exe & relaunch
if (config.TrySelfInstallAndRelaunch())
    return;

using var singleInstanceMutex = new Mutex(true, "KADRemote_Agent_SingleInstance_Mutex", out bool isNew);
if (!isNew)
    return;

var system = new SystemService();
var screen = new ScreenCaptureService();
var input = new InputSimulationService(screen);
var powershell = new PowerShellService(config);
var files = new FileService();

await using var apiServer = new AgentApiServer(config, system, screen, input, powershell, files);
await using var controllerLink = new ControllerLinkService(config, system);

await apiServer.StartAsync();
controllerLink.Start();

// Trim initial startup working set to minimize idle RAM on Windows 10/11
GC.Collect(2, GCCollectionMode.Aggressive, blocking: true, compacting: true);
GC.WaitForPendingFinalizers();

var shutdown = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
AppDomain.CurrentDomain.ProcessExit += (_, _) => shutdown.TrySetResult();

await shutdown.Task;

static void EnablePerMonitorDpiAwareness()
{
    try
    {
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (IntPtr)(-4) on Windows 10 1703+ & Windows 11
        if (!NativeDpi.SetProcessDpiAwarenessContext((IntPtr)(-4)))
            NativeDpi.SetProcessDPIAware();
    }
    catch
    {
        try { NativeDpi.SetProcessDPIAware(); } catch { }
    }
}

file static class NativeDpi
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
