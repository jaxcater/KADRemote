using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Forms;
using System.Windows.Media.Imaging;
using KADRemote.Host.Services;
using QRCoder;

namespace KADRemote.Host;

public partial class MainWindow : Window
{
    private readonly ConfigService _config;
    private readonly LogService _log;
    private readonly SystemService _system;
    private readonly CloudflareTunnelService _tunnel;
    private readonly RemoteApiServer _server;

    private NotifyIcon? _trayIcon;
    private bool _isLoadingUi = true;
    private bool _forceExit;

    public MainWindow(
        ConfigService config,
        LogService log,
        SystemService system,
        CloudflareTunnelService tunnel,
        RemoteApiServer server)
    {
        InitializeComponent();
        _config = config;
        _log = log;
        _system = system;
        _tunnel = tunnel;
        _server = server;

        LogList.ItemsSource = _log.Entries;

        _tunnel.StateChanged += () => Dispatcher.BeginInvoke(RefreshStatus);
        _server.ClientsChanged += () => Dispatcher.BeginInvoke(RefreshStatus);

        SetupTrayIcon();
        LoadFieldsFromConfig();
        RefreshStatus();
        _isLoadingUi = false;
    }

    private void SetupTrayIcon()
    {
        Icon? appIcon = null;
        try
        {
            var exePath = Environment.ProcessPath;
            if (!string.IsNullOrEmpty(exePath))
                appIcon = System.Drawing.Icon.ExtractAssociatedIcon(exePath);
        }
        catch { }

        _trayIcon = new NotifyIcon
        {
            Icon = appIcon ?? SystemIcons.Application,
            Text = "KAD Remote (Đang chạy)",
            Visible = true
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add("Mở KAD Remote", null, (_, _) => ShowFromTray());
        menu.Items.Add("Thoát hoàn toàn", null, (_, _) => ExitApplication());
        _trayIcon.ContextMenuStrip = menu;
        _trayIcon.DoubleClick += (_, _) => ShowFromTray();
    }

    private void ShowFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
    }

    private void ExitApplication()
    {
        _forceExit = true;
        _trayIcon?.Dispose();
        System.Windows.Application.Current.Shutdown();
    }

    private void LoadFieldsFromConfig()
    {
        TokenBox.Text = _config.Current.Token;
        PortBox.Text = _config.Current.Port.ToString();
        AutoStartCheck.IsChecked = _config.Current.StartWithWindows;
        AutoTunnelCheck.IsChecked = _config.Current.AutoStartTunnel;
        TrayOnCloseCheck.IsChecked = _config.Current.MinimizeToTrayOnClose;
    }

    public void RefreshStatus()
    {
        var port = _config.Current.Port;
        SubtitleText.Text = $"{_config.Current.DeviceName} • Port {port} • Client đang mở stream/shell: {_server.ActiveClients}";
        ServerStatusText.Text = _server.IsRunning ? $"Đang chạy :{port}" : "Đã dừng";

        // Local URLs
        var localUrls = _system.GetLocalUrls(port);
        var prevSelected = LocalUrlsCombo.SelectedItem as string;
        LocalUrlsCombo.ItemsSource = localUrls;
        if (!string.IsNullOrEmpty(prevSelected) && localUrls.Contains(prevSelected))
            LocalUrlsCombo.SelectedItem = prevSelected;
        else if (localUrls.Count > 0)
            LocalUrlsCombo.SelectedIndex = 0;

        // Tunnel status
        TunnelStatusText.Text = _tunnel.StatusText;
        ToggleTunnelBtn.Content = _tunnel.IsRunning ? "Tắt Tunnel" : "Bật Tunnel";
        TunnelUrlBox.Text = string.IsNullOrEmpty(_tunnel.PublicUrl)
            ? (_tunnel.IsRunning ? "Đang lấy link https://*.trycloudflare.com ..." : "Chưa có URL — bấm Bật Tunnel để tạo link từ xa")
            : _tunnel.PublicUrl;

        UpdateQrCode();
    }

    private void UpdateQrCode()
    {
        bool preferTunnel = QrPreferTunnelRadio.IsChecked == true;
        string? activeUrl = null;
        string modeLabel;

        if (preferTunnel && !string.IsNullOrEmpty(_tunnel.PublicUrl))
        {
            activeUrl = _tunnel.PublicUrl;
            modeLabel = "Đang dùng: Tunnel Từ Xa (4G/Internet)";
        }
        else
        {
            activeUrl = LocalUrlsCombo.SelectedItem as string;
            if (string.IsNullOrEmpty(activeUrl) && !string.IsNullOrEmpty(_tunnel.PublicUrl))
            {
                activeUrl = _tunnel.PublicUrl;
                modeLabel = "Đang dùng: Tunnel Từ Xa";
            }
            else
            {
                modeLabel = "Đang dùng: LAN / Tailscale";
            }
        }

        QrTargetLabel.Text = modeLabel;
        if (string.IsNullOrEmpty(activeUrl))
        {
            QrImage.Source = null;
            return;
        }

        var payload = $"kadremote://connect?url={Uri.EscapeDataString(activeUrl)}&token={Uri.EscapeDataString(_config.Current.Token)}&name={Uri.EscapeDataString(_config.Current.DeviceName)}";

        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        var pngQr = new PngByteQRCode(data);
        var pngBytes = pngQr.GetGraphic(8);

        using var ms = new MemoryStream(pngBytes);
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.StreamSource = ms;
        bmp.EndInit();
        bmp.Freeze();
        QrImage.Source = bmp;
    }

    private async void ToggleTunnel_Click(object sender, RoutedEventArgs e)
    {
        if (_tunnel.IsRunning)
        {
            _tunnel.Stop();
            RefreshStatus();
        }
        else
        {
            ToggleTunnelBtn.IsEnabled = false;
            await _tunnel.StartAsync(_config.Current.Port);
            ToggleTunnelBtn.IsEnabled = true;
            RefreshStatus();
        }
    }

    private void CopyTunnelUrl_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(_tunnel.PublicUrl))
            System.Windows.Clipboard.SetText(_tunnel.PublicUrl);
    }

    private void CopyLocalUrl_Click(object sender, RoutedEventArgs e)
    {
        if (LocalUrlsCombo.SelectedItem is string url)
            System.Windows.Clipboard.SetText(url);
    }

    private void CopyToken_Click(object sender, RoutedEventArgs e)
    {
        System.Windows.Clipboard.SetText(_config.Current.Token);
    }

    private void RegenToken_Click(object sender, RoutedEventArgs e)
    {
        var newToken = _config.RegenerateToken();
        TokenBox.Text = newToken;
        _log.Add("Security", "Đã tạo Access Token mới");
        UpdateQrCode();
    }

    private async void ApplyPort_Click(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(PortBox.Text.Trim(), out int port) || port < 1024 || port > 65535)
        {
            System.Windows.MessageBox.Show("Port phải nằm trong khoảng 1024 - 65535.", "KAD Remote", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        _config.Current.Port = port;
        _config.Save();

        try
        {
            await _server.RestartAsync();
            if (_tunnel.IsRunning)
            {
                _tunnel.Stop();
                await _tunnel.StartAsync(port);
            }
            RefreshStatus();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show($"Lỗi đổi cổng: {ex.Message}", "KAD Remote", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void SettingsCheck_Changed(object sender, RoutedEventArgs e)
    {
        if (_isLoadingUi) return;
        _config.Current.StartWithWindows = AutoStartCheck.IsChecked == true;
        _config.Current.AutoStartTunnel = AutoTunnelCheck.IsChecked == true;
        _config.Current.MinimizeToTrayOnClose = TrayOnCloseCheck.IsChecked == true;
        _config.Save();
    }

    private void QrMode_Changed(object sender, RoutedEventArgs e)
    {
        if (!_isLoadingUi) UpdateQrCode();
    }

    private void LocalUrlsCombo_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!_isLoadingUi) UpdateQrCode();
    }

    private void MinimizeTray_Click(object sender, RoutedEventArgs e)
    {
        Hide();
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (!_forceExit && _config.Current.MinimizeToTrayOnClose)
        {
            e.Cancel = true;
            Hide();
            _trayIcon?.ShowBalloonTip(2000, "KAD Remote", "Ứng dụng vẫn đang chạy ngầm ở System Tray.", ToolTipIcon.Info);
        }
        else
        {
            _trayIcon?.Dispose();
            System.Windows.Application.Current.Shutdown();
        }
    }
}
