using KADRemote.Agent.Services;

using var config = new AgentConfigService();

var mutexName = $"KADRemote_Agent_SingleInstance_Mutex_{config.Config.AgentPort}";
using var singleInstanceMutex = new Mutex(false, mutexName);

bool hasHandle = false;
try
{
    hasHandle = singleInstanceMutex.WaitOne(0, false);
    if (!hasHandle)
    {
        config.RequestExistingInstanceShutdown();
        hasHandle = singleInstanceMutex.WaitOne(3500, false);
    }
}
catch (AbandonedMutexException)
{
    hasHandle = true;
}

if (!hasHandle)
{
    AgentLog.Warn("Startup", $"Another KADRemote Agent instance on port {config.Config.AgentPort} is still running; exiting duplicate.");
    return;
}

config.FinalizeRuntimeSetup();

var system = new SystemService();
var screen = new ScreenCaptureService();
var input = new InputSimulationService(screen);
var powershell = new PowerShellService(config);
var files = new FileService();
using var tunnel = new CloudflareTunnelService(config);
using var peers = new PeerDiscoveryService(config, system, tunnel);
using var cloudSync = new CloudSyncService(config, system, tunnel, peers);

await using var apiServer = new AgentApiServer(config, system, screen, input, powershell, files, tunnel, peers);
await using var controllerLink = new ControllerLinkService(config, system, tunnel);

await apiServer.StartAsync();
tunnel.Start();
peers.Start();
controllerLink.Start();
cloudSync.Start();

// Trim initial startup working set to minimize idle RAM on Windows 10/11
GC.Collect(2, GCCollectionMode.Aggressive, blocking: true, compacting: true);
GC.WaitForPendingFinalizers();

var shutdown = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
AppDomain.CurrentDomain.ProcessExit += (_, _) =>
{
    try { config.CheckExeHealthNow(); } catch { }
    shutdown.TrySetResult();
};

await shutdown.Task;
