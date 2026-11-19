using System.IO;
using System.Text;

namespace KADRemote.Agent.Services;

public static class AgentLog
{
    private static readonly object LockObj = new();
    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KADRemote",
        "agent.log"
    );
    private const long MaxLogBytes = 256 * 1024;

    public static void Info(string category, string message) => Write("INFO", category, message);
    public static void Warn(string category, string message) => Write("WARN", category, message);
    public static void Error(string category, string message) => Write("ERR", category, message);

    private static void Write(string level, string category, string message)
    {
        try
        {
            lock (LockObj)
            {
                var dir = Path.GetDirectoryName(LogPath);
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);

                if (File.Exists(LogPath) && new FileInfo(LogPath).Length > MaxLogBytes)
                {
                    var backup = LogPath + ".old";
                    if (File.Exists(backup)) File.Delete(backup);
                    File.Move(LogPath, backup);
                }

                var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] [{category}] {message}{Environment.NewLine}";
                File.AppendAllText(LogPath, line, Encoding.UTF8);
            }
        }
        catch
        {
            // Never crash headless agent due to logging IO errors
        }
    }
}
