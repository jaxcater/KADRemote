using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using KADRemote.Agent.Models;

namespace KADRemote.Agent.Services;

public sealed class ScreenCaptureService
{
    private static readonly ImageCodecInfo? JpegCodec = ImageCodecInfo
        .GetImageEncoders()
        .FirstOrDefault(c => c.FormatID == ImageFormat.Jpeg.Guid);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CURSORINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO
    {
        public bool fIcon;
        public int xHotspot;
        public int yHotspot;
        public IntPtr hbmMask;
        public IntPtr hbmColor;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    private const int CURSOR_SHOWING = 0x00000001;
    private const int DI_NORMAL = 0x0003;
    private const uint MONITORINFOF_PRIMARY = 1;
    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    private static extern bool GetCursorInfo(out CURSORINFO pci);

    [DllImport("user32.dll")]
    private static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO piconinfo);

    [DllImport("user32.dll")]
    private static extern bool DrawIconEx(
        IntPtr hdc, int xLeft, int yTop, IntPtr hIcon,
        int cxWidth, int cyHeight, int istepIfAniCur, IntPtr hbrFlickerFreeDraw, int diFlags);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    public List<MonitorInfoDto> GetMonitors()
    {
        var list = new List<MonitorInfoDto>();
        int idx = 0;

        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hMon, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var mi = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
            if (GetMonitorInfo(hMon, ref mi))
            {
                int w = mi.rcMonitor.Right - mi.rcMonitor.Left;
                int h = mi.rcMonitor.Bottom - mi.rcMonitor.Top;
                list.Add(new MonitorInfoDto(
                    Index: idx++,
                    Name: (mi.szDevice ?? $"DISPLAY{idx}").Replace(@"\\.\", ""),
                    Width: w,
                    Height: h,
                    X: mi.rcMonitor.Left,
                    Y: mi.rcMonitor.Top,
                    IsPrimary: (mi.dwFlags & MONITORINFOF_PRIMARY) != 0
                ));
            }
            return true;
        }, IntPtr.Zero);

        if (list.Count == 0)
            list.Add(new MonitorInfoDto(0, "DISPLAY1", 1920, 1080, 0, 0, true));

        return list;
    }

    public Rectangle GetMonitorBounds(int monitorIndex)
    {
        if (monitorIndex < 0)
        {
            return new Rectangle(
                GetSystemMetrics(SM_XVIRTUALSCREEN),
                GetSystemMetrics(SM_YVIRTUALSCREEN),
                Math.Max(1, GetSystemMetrics(SM_CXVIRTUALSCREEN)),
                Math.Max(1, GetSystemMetrics(SM_CYVIRTUALSCREEN))
            );
        }

        var monitors = GetMonitors();
        if (monitorIndex >= monitors.Count)
            monitorIndex = 0;

        var m = monitors[monitorIndex];
        return new Rectangle(m.X, m.Y, m.Width, m.Height);
    }

    public byte[] CaptureJpeg(int monitorIndex = 0, int quality = 60, double scale = 0.65)
    {
        quality = Math.Clamp(quality, 15, 95);
        scale = Math.Clamp(scale, 0.2, 1.0);

        var bounds = GetMonitorBounds(monitorIndex);
        if (bounds.Width <= 0 || bounds.Height <= 0)
            return Array.Empty<byte>();

        using var rawBmp = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb);
        using (var g = Graphics.FromImage(rawBmp))
        {
            try
            {
                g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size, CopyPixelOperation.SourceCopy);
                DrawCursor(g, bounds);
            }
            catch (Exception ex)
            {
                g.Clear(Color.FromArgb(15, 23, 42));
                using var subFont = new Font("Segoe UI", 16, FontStyle.Regular);
                using var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                var rect = new RectangleF(40, 40, bounds.Width - 80, bounds.Height - 80);
                g.DrawString(
                    $"KAD Remote — Không thể chụp màn hình\n({ex.Message})\n\nMàn hình Server có thể đang khóa (Lock) hoặc chưa có session hiển thị.",
                    subFont,
                    Brushes.LightSkyBlue,
                    rect,
                    sf
                );
            }
        }

        Bitmap targetBmp = rawBmp;
        Bitmap? scaledBmp = null;

        try
        {
            if (scale < 0.99)
            {
                int targetW = Math.Max(320, (int)Math.Round(bounds.Width * scale));
                int targetH = Math.Max(180, (int)Math.Round(bounds.Height * scale));
                scaledBmp = new Bitmap(targetW, targetH, PixelFormat.Format24bppRgb);
                using var sg = Graphics.FromImage(scaledBmp);
                sg.InterpolationMode = InterpolationMode.Bilinear;
                sg.CompositingQuality = CompositingQuality.HighSpeed;
                sg.DrawImage(rawBmp, 0, 0, targetW, targetH);
                targetBmp = scaledBmp;
            }

            using var ms = new MemoryStream(64 * 1024);
            if (JpegCodec != null)
            {
                using var ep = new EncoderParameters(1);
                using var qualityParam = new EncoderParameter(Encoder.Quality, (long)quality);
                ep.Param[0] = qualityParam;
                targetBmp.Save(ms, JpegCodec, ep);
            }
            else
            {
                targetBmp.Save(ms, ImageFormat.Jpeg);
            }

            return ms.ToArray();
        }
        finally
        {
            scaledBmp?.Dispose();
        }
    }

    private static void DrawCursor(Graphics g, Rectangle monitorBounds)
    {
        try
        {
            var ci = new CURSORINFO { cbSize = Marshal.SizeOf<CURSORINFO>() };
            if (!GetCursorInfo(out ci) || (ci.flags & CURSOR_SHOWING) == 0 || ci.hCursor == IntPtr.Zero)
                return;

            int x = ci.ptScreenPos.x - monitorBounds.X;
            int y = ci.ptScreenPos.y - monitorBounds.Y;

            if (GetIconInfo(ci.hCursor, out var iconInfo))
            {
                x -= iconInfo.xHotspot;
                y -= iconInfo.yHotspot;
                if (iconInfo.hbmMask != IntPtr.Zero) DeleteObject(iconInfo.hbmMask);
                if (iconInfo.hbmColor != IntPtr.Zero) DeleteObject(iconInfo.hbmColor);
            }

            if (x < -64 || y < -64 || x > monitorBounds.Width + 64 || y > monitorBounds.Height + 64)
                return;

            IntPtr hdc = g.GetHdc();
            try
            {
                DrawIconEx(hdc, x, y, ci.hCursor, 0, 0, 0, IntPtr.Zero, DI_NORMAL);
            }
            finally
            {
                g.ReleaseHdc(hdc);
            }
        }
        catch { }
    }
}
