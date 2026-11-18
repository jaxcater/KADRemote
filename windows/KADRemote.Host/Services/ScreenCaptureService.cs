using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using KADRemote.Host.Models;

namespace KADRemote.Host.Services;

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

    private const int CURSOR_SHOWING = 0x00000001;
    private const int DI_NORMAL = 0x0003;

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
        var screens = Screen.AllScreens;
        var list = new List<MonitorInfoDto>(screens.Length);
        for (int i = 0; i < screens.Length; i++)
        {
            var s = screens[i];
            list.Add(new MonitorInfoDto(
                Index: i,
                Name: s.DeviceName.Replace(@"\\.\", ""),
                Width: s.Bounds.Width,
                Height: s.Bounds.Height,
                X: s.Bounds.X,
                Y: s.Bounds.Y,
                IsPrimary: s.Primary
            ));
        }
        return list;
    }

    public Rectangle GetMonitorBounds(int monitorIndex)
    {
        var screens = Screen.AllScreens;
        if (screens.Length == 0)
            return new Rectangle(0, 0, 1920, 1080);

        if (monitorIndex < 0)
            return SystemInformation.VirtualScreen;

        if (monitorIndex >= screens.Length)
            monitorIndex = 0;

        return screens[monitorIndex].Bounds;
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
                using var titleFont = new Font("Segoe UI", 28, FontStyle.Bold);
                using var subFont = new Font("Segoe UI", 16, FontStyle.Regular);
                using var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                var rect = new RectangleF(40, 40, bounds.Width - 80, bounds.Height - 80);
                g.DrawString(
                    $"KAD Remote — Không thể chụp màn hình\n({ex.Message})\n\nMàn hình PC có thể đang khóa (Lock) hoặc tắt hiển thị.",
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
                ep.Param[0] = new EncoderParameter(Encoder.Quality, (long)quality);
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
        catch
        {
            // Ignore cursor drawing failures
        }
    }
}
