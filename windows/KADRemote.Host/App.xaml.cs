using System.Windows;
using KADRemote.Host.Services;

namespace KADRemote.Host;

public partial class App : System.Windows.Application
{
    private Mutex? _singleInstanceMutex;
    private ConfigService? _config;
    private LogService? _log;
    private CloudflareTunnelService? _tunnel;
    private RemoteApiServer? _server;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstanceMutex = new Mutex(true, "KADRemote_Host_SingleInstance_Mutex", out bool isNew);
        if (!isNew)
        {
            System.Windows.MessageBox.Show("KAD Remote đang chạy ở khay hệ thống (System Tray).", "KAD Remote", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        _config = new ConfigService();
        _log = new LogService();
        var system = new SystemService();
        var screen = new ScreenCaptureService();
        var input = new InputSimulationService(screen);
        var powershell = new PowerShellService(_log, _config);
        var files = new FileService(_log);
        _tunnel = new CloudflareTunnelService(_log);
        _server = new RemoteApiServer(_config, _log, system, screen, input, powershell, files, _tunnel);

        var mainWindow = new MainWindow(_config, _log, system, _tunnel, _server);
        MainWindow = mainWindow;

        bool startMinimized = e.Args.Any(a => a.Equals("--minimized", StringComparison.OrdinalIgnoreCase));
        if (!startMinimized)
            mainWindow.Show();

        try
        {
            await _server.StartAsync();
            mainWindow.RefreshStatus();

            if (_config.Current.AutoStartTunnel)
            {
                await _tunnel.StartAsync(_config.Current.Port);
            }
        }
        catch (Exception ex)
        {
            _log.Add("Error", $"Không thể khởi động server: {ex.Message}");
            System.Windows.MessageBox.Show($"Không thể khởi động cổng {_config.Current.Port}:\n{ex.Message}", "KAD Remote", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        _tunnel?.Dispose();
        if (_server != null)
            await _server.DisposeAsync();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        base.OnExit(e);
    }
}
