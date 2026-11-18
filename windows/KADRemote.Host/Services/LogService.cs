using System.Collections.ObjectModel;
using System.Windows;

namespace KADRemote.Host.Services;

public sealed record LogEntry(DateTime Timestamp, string Category, string Message)
{
    public string Formatted => $"[{Timestamp:HH:mm:ss}] [{Category}] {Message}";
}

public sealed class LogService
{
    private const int MaxEntries = 300;
    public ObservableCollection<LogEntry> Entries { get; } = new();

    public void Add(string category, string message)
    {
        var entry = new LogEntry(DateTime.Now, category, message);
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher != null && !dispatcher.CheckAccess())
        {
            dispatcher.BeginInvoke(() => InsertEntry(entry));
        }
        else
        {
            InsertEntry(entry);
        }
    }

    private void InsertEntry(LogEntry entry)
    {
        Entries.Insert(0, entry);
        while (Entries.Count > MaxEntries)
            Entries.RemoveAt(Entries.Count - 1);
    }
}
