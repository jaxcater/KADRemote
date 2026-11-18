using System.Runtime.InteropServices;
using KADRemote.Host.Models;

namespace KADRemote.Host.Services;

public sealed class InputSimulationService
{
    private readonly ScreenCaptureService _screenCapture;

    public InputSimulationService(ScreenCaptureService screenCapture)
    {
        _screenCapture = screenCapture;
    }

    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;

    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;

    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public int mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUT_UNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public INPUT_UNION u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetCursorPos(int X, int Y);

    public void HandleInput(ScreenInputMessage msg)
    {
        switch (msg.Type.ToLowerInvariant())
        {
            case "move":
                MoveToNormalized(msg.Monitor, msg.X, msg.Y);
                break;

            case "click":
            case "left_click":
                MoveToNormalized(msg.Monitor, msg.X, msg.Y);
                SendMouseFlags(MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
                break;

            case "right_click":
                MoveToNormalized(msg.Monitor, msg.X, msg.Y);
                SendMouseFlags(MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
                break;

            case "double_click":
                MoveToNormalized(msg.Monitor, msg.X, msg.Y);
                SendMouseFlags(MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
                Thread.Sleep(50);
                SendMouseFlags(MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
                break;

            case "middle_click":
                MoveToNormalized(msg.Monitor, msg.X, msg.Y);
                SendMouseFlags(MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP);
                break;

            case "scroll":
                MoveToNormalized(msg.Monitor, msg.X, msg.Y);
                SendWheel(msg.Delta == 0 ? -120 : msg.Delta);
                break;

            case "text":
                if (!string.IsNullOrEmpty(msg.Text))
                    TypeUnicodeText(msg.Text);
                break;

            case "hotkey":
                if (msg.Keys is { Length: > 0 })
                    SendHotkey(msg.Keys);
                break;
        }
    }

    private void MoveToNormalized(int monitor, double normX, double normY)
    {
        var bounds = _screenCapture.GetMonitorBounds(monitor);
        int x = bounds.X + (int)Math.Round(Math.Clamp(normX, 0, 1) * Math.Max(1, bounds.Width - 1));
        int y = bounds.Y + (int)Math.Round(Math.Clamp(normY, 0, 1) * Math.Max(1, bounds.Height - 1));
        SetCursorPos(x, y);
    }

    private static void SendMouseFlags(params uint[] flags)
    {
        var inputs = new INPUT[flags.Length];
        for (int i = 0; i < flags.Length; i++)
        {
            inputs[i] = new INPUT
            {
                type = INPUT_MOUSE,
                u = new INPUT_UNION
                {
                    mi = new MOUSEINPUT { dwFlags = flags[i] }
                }
            };
        }
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static void SendWheel(int delta)
    {
        var inputs = new[]
        {
            new INPUT
            {
                type = INPUT_MOUSE,
                u = new INPUT_UNION
                {
                    mi = new MOUSEINPUT
                    {
                        dwFlags = MOUSEEVENTF_WHEEL,
                        mouseData = delta
                    }
                }
            }
        };
        SendInput(1, inputs, Marshal.SizeOf<INPUT>());
    }

    private static void TypeUnicodeText(string text)
    {
        var inputs = new List<INPUT>(text.Length * 2);
        foreach (char ch in text)
        {
            if (ch == '\r') continue;
            if (ch == '\n')
            {
                inputs.Add(KeyInput(0x0D, false));
                inputs.Add(KeyInput(0x0D, true));
                continue;
            }

            inputs.Add(new INPUT
            {
                type = INPUT_KEYBOARD,
                u = new INPUT_UNION
                {
                    ki = new KEYBDINPUT { wScan = ch, dwFlags = KEYEVENTF_UNICODE }
                }
            });
            inputs.Add(new INPUT
            {
                type = INPUT_KEYBOARD,
                u = new INPUT_UNION
                {
                    ki = new KEYBDINPUT { wScan = ch, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP }
                }
            });
        }

        if (inputs.Count > 0)
            SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
    }

    private static void SendHotkey(string[] keys)
    {
        var vks = new List<ushort>();
        foreach (var k in keys)
        {
            if (TryMapVirtualKey(k, out var vk))
                vks.Add(vk);
        }
        if (vks.Count == 0) return;

        var inputs = new List<INPUT>(vks.Count * 2);
        foreach (var vk in vks)
            inputs.Add(KeyInput(vk, false));
        for (int i = vks.Count - 1; i >= 0; i--)
            inputs.Add(KeyInput(vks[i], true));

        SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>());
    }

    private static INPUT KeyInput(ushort vk, bool keyUp) => new()
    {
        type = INPUT_KEYBOARD,
        u = new INPUT_UNION
        {
            ki = new KEYBDINPUT
            {
                wVk = vk,
                dwFlags = keyUp ? KEYEVENTF_KEYUP : 0
            }
        }
    };

    private static bool TryMapVirtualKey(string key, out ushort vk)
    {
        var norm = key.Trim().ToLowerInvariant();
        vk = norm switch
        {
            "ctrl" or "control" => 0x11,
            "alt" => 0x12,
            "shift" => 0x10,
            "win" or "meta" or "cmd" => 0x5B,
            "enter" or "return" => 0x0D,
            "esc" or "escape" => 0x1B,
            "tab" => 0x09,
            "backspace" => 0x08,
            "delete" or "del" => 0x2E,
            "space" => 0x20,
            "up" => 0x26,
            "down" => 0x28,
            "left" => 0x25,
            "right" => 0x27,
            "home" => 0x24,
            "end" => 0x23,
            "pgup" or "pageup" => 0x21,
            "pgdn" or "pagedown" => 0x22,
            "f1" => 0x70,
            "f2" => 0x71,
            "f3" => 0x72,
            "f4" => 0x73,
            "f5" => 0x74,
            "f6" => 0x75,
            "f7" => 0x76,
            "f8" => 0x77,
            "f9" => 0x78,
            "f10" => 0x79,
            "f11" => 0x7A,
            "f12" => 0x7B,
            _ when norm.Length == 1 && char.IsLetterOrDigit(norm[0]) => (ushort)char.ToUpperInvariant(norm[0]),
            _ => 0
        };
        return vk != 0;
    }
}
