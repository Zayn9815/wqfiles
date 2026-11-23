using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace WQGlassTransfer;

public sealed class DiagnosticLogItem
{
    public string Timestamp { get; init; } = "";
    public string Level { get; init; } = "INFO";
    public string Source { get; init; } = "App";
    public string Message { get; init; } = "";
    public string? Detail { get; init; }

    public string formattedLine =>
        string.IsNullOrWhiteSpace(Detail)
            ? $"[{Timestamp}] [{Level}] [{Source}] {Message}"
            : $"[{Timestamp}] [{Level}] [{Source}] {Message}\n    {Detail.Replace("\r\n", "\n").Replace("\n", "\n    ")}";
}

/// <summary>
/// Thread-safe application, error, and crash logger for WQGlass Transfer (Windows).
/// Persists structured session logs and crash dumps to %AppData%\WQGlassTransfer\Logs\
/// so users can view, filter, copy, or export a complete diagnostic report at any time.
/// </summary>
public static class AppLogger
{
    private static readonly object FileLock = new();
    private static readonly ConcurrentQueue<DiagnosticLogItem> RecentItems = new();
    private const int MaxInMemoryItems = 800;

    public static string LogsDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WQGlassTransfer", "Logs");

    public static string CurrentLogFilePath =>
        Path.Combine(LogsDirectory, "wqglass-transfer.log");

    public static string CrashLogFilePath =>
        Path.Combine(LogsDirectory, "wqglass-crashes.log");

    public static event Action<DiagnosticLogItem>? EntryAdded;

    public static void Initialize()
    {
        try
        {
            Directory.CreateDirectory(LogsDirectory);
            RotateIfLarge(CurrentLogFilePath, 4 * 1024 * 1024);
            RotateIfLarge(CrashLogFilePath, 4 * 1024 * 1024);
            Info("Startup", $"WQGlass Transfer v2.2.0 started on {RuntimeInformation.OSDescription} ({RuntimeInformation.OSArchitecture}, .NET {Environment.Version})");
        }
        catch
        {
            // Never throw from logger initialization.
        }
    }

    public static void Info(string source, string message, string? detail = null) =>
        Write("INFO", source, message, detail, isCrash: false);

    public static void Warn(string source, string message, string? detail = null) =>
        Write("WARN", source, message, detail, isCrash: false);

    public static void Error(string source, string message, Exception? ex = null) =>
        Write("ERROR", source, message, ex?.ToString(), isCrash: false);

    public static void Error(string source, string message, string? detail) =>
        Write("ERROR", source, message, detail, isCrash: false);

    public static void Crash(string source, string message, Exception? ex) =>
        Write("CRASH", source, message, ex?.ToString() ?? "Unknown fatal exception", isCrash: true);

    private static void Write(string level, string source, string message, string? detail, bool isCrash)
    {
        var item = new DiagnosticLogItem
        {
            Timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff"),
            Level = level,
            Source = source,
            Message = message,
            Detail = detail
        };

        RecentItems.Enqueue(item);
        while (RecentItems.Count > MaxInMemoryItems && RecentItems.TryDequeue(out _)) { }

        string line = item.formattedLine + Environment.NewLine;
        lock (FileLock)
        {
            try
            {
                Directory.CreateDirectory(LogsDirectory);
                File.AppendAllText(CurrentLogFilePath, line, Encoding.UTF8);
                if (isCrash || level == "ERROR")
                {
                    File.AppendAllText(CrashLogFilePath, line, Encoding.UTF8);
                }
            }
            catch
            {
                // Ignore disk write failures.
            }
        }

        try { EntryAdded?.Invoke(item); } catch { }
    }

    public static IReadOnlyList<DiagnosticLogItem> GetRecentItems() => RecentItems.ToArray();

    public static string ReadCrashLogDiskText()
    {
        lock (FileLock)
        {
            try
            {
                if (File.Exists(CrashLogFilePath))
                    return File.ReadAllText(CrashLogFilePath, Encoding.UTF8);
            }
            catch { }
        }
        return "";
    }

    public static void ClearAllLogs()
    {
        while (RecentItems.TryDequeue(out _)) { }
        lock (FileLock)
        {
            try
            {
                if (File.Exists(CurrentLogFilePath)) File.Delete(CurrentLogFilePath);
                if (File.Exists(CrashLogFilePath)) File.Delete(CrashLogFilePath);
            }
            catch { }
        }
        Info("Logger", "Logs and crash history cleared by user.");
    }

    public static string BuildFullDiagnosticReport(string filterLevel = "ALL")
    {
        var sb = new StringBuilder();
        sb.AppendLine("==================================================================");
        sb.AppendLine("WQGlass Transfer Studio — Diagnostic, Error & Crash Report (Windows)");
        sb.AppendLine("==================================================================");
        sb.AppendLine($"Generated     : {DateTime.Now:yyyy-MM-dd HH:mm:ss zzz}");
        sb.AppendLine($"App Version   : 2.2.0");
        sb.AppendLine($"Machine Name  : {Environment.MachineName}");
        sb.AppendLine($"OS            : {RuntimeInformation.OSDescription} ({RuntimeInformation.OSArchitecture})");
        sb.AppendLine($".NET Runtime  : {RuntimeInformation.FrameworkDescription}");
        sb.AppendLine($"Log Directory : {LogsDirectory}");
        sb.AppendLine("==================================================================");
        sb.AppendLine();

        string crashDisk = ReadCrashLogDiskText();
        if (!string.IsNullOrWhiteSpace(crashDisk))
        {
            sb.AppendLine("--- PERSISTED ERROR & CRASH LOG (wqglass-crashes.log) ---");
            sb.AppendLine(crashDisk.TrimEnd());
            sb.AppendLine();
        }
        else
        {
            sb.AppendLine("--- PERSISTED ERROR & CRASH LOG: None recorded ---");
            sb.AppendLine();
        }

        sb.AppendLine($"--- CURRENT SESSION LOGS (Filter: {filterLevel}) ---");
        foreach (var item in RecentItems)
        {
            if (!MatchesFilter(item, filterLevel)) continue;
            sb.AppendLine(item.formattedLine);
        }

        return sb.ToString();
    }

    public static bool MatchesFilter(DiagnosticLogItem item, string filterLevel)
    {
        return filterLevel.ToUpperInvariant() switch
        {
            "ERRORS" => item.Level is "ERROR" or "WARN" or "CRASH",
            "CRASHES" => item.Level is "CRASH",
            _ => true
        };
    }

    private static void RotateIfLarge(string path, long maxBytes)
    {
        try
        {
            var fi = new FileInfo(path);
            if (fi.Exists && fi.Length > maxBytes)
            {
                string prev = path + ".prev";
                if (File.Exists(prev)) File.Delete(prev);
                File.Move(path, prev);
            }
        }
        catch { }
    }
}
