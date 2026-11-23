using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace WQGlassTransfer;

public sealed class DiscoveredPhone
{
    [JsonPropertyName("app")]
    public string App { get; set; } = "";

    [JsonPropertyName("version")]
    public string Version { get; set; } = "";

    [JsonPropertyName("device")]
    public string Device { get; set; } = "Device";

    [JsonPropertyName("platform")]
    public string Platform { get; set; } = "";

    [JsonPropertyName("osVersion")]
    public string OsVersion { get; set; } = "";

    [JsonPropertyName("ip")]
    public string Ip { get; set; } = "";

    [JsonPropertyName("port")]
    public int Port { get; set; } = 8765;

    [JsonPropertyName("root")]
    public string Root { get; set; } = "Downloads";

    [JsonIgnore]
    public DateTime LastSeenUtc { get; set; } = DateTime.UtcNow;

    [JsonIgnore]
    public string Endpoint => $"{Ip}:{Port}";

    [JsonIgnore]
    public string NormalizedPlatform => (Platform ?? "").Trim().ToLowerInvariant() switch
    {
        "android" => "android",
        "windows" => "windows",
        _ => "ios"
    };

    [JsonIgnore]
    public string PlatformBadge => NormalizedPlatform switch
    {
        "android" => "🤖 Android",
        "windows" => "💻 Windows",
        _ => "🍎 iOS"
    };

    [JsonIgnore]
    public string DisplayName => $"{PlatformBadge} · {Device} ({Ip}:{Port}) · /{Root}";
}

public sealed class PhoneInfo
{
    [JsonPropertyName("device")]
    public string Device { get; set; } = "Device";

    [JsonPropertyName("platform")]
    public string Platform { get; set; } = "";

    [JsonPropertyName("osVersion")]
    public string OsVersion { get; set; } = "";

    [JsonPropertyName("ios")]
    public string IosVersion { get; set; } = "";

    [JsonPropertyName("root")]
    public string Root { get; set; } = "Downloads";

    [JsonPropertyName("freeBytes")]
    public long FreeBytes { get; set; }

    [JsonPropertyName("totalBytes")]
    public long TotalBytes { get; set; }

    [JsonIgnore]
    public string NormalizedPlatform => (Platform ?? "").Trim().ToLowerInvariant() switch
    {
        "android" => "android",
        "windows" => "windows",
        _ => "ios"
    };

    [JsonIgnore]
    public string PlatformLabel => NormalizedPlatform switch
    {
        "android" => "Android",
        "windows" => "Windows",
        _ => "iOS"
    };

    [JsonIgnore]
    public string PlatformIcon => NormalizedPlatform switch
    {
        "android" => "🤖",
        "windows" => "💻",
        _ => "🍎"
    };

    [JsonIgnore]
    public string EffectiveOsVersion => !string.IsNullOrWhiteSpace(OsVersion) ? OsVersion : IosVersion;

    [JsonIgnore]
    public string OsSummary => string.IsNullOrWhiteSpace(EffectiveOsVersion)
        ? PlatformLabel
        : $"{PlatformLabel} {EffectiveOsVersion}";

    [JsonIgnore]
    public double UsedPercent => TotalBytes > 0
        ? Math.Clamp(100.0 * (TotalBytes - FreeBytes) / TotalBytes, 0.0, 100.0)
        : 0.0;
}

public sealed class RemoteListResponse
{
    [JsonPropertyName("path")]
    public string Path { get; set; } = "";

    [JsonPropertyName("items")]
    public List<RemoteFileItem> Items { get; set; } = new();
}

public sealed class RemoteFileItem : INotifyPropertyChanged
{
    private bool _isSelected;

    public event PropertyChangedEventHandler? PropertyChanged;

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("path")]
    public string Path { get; set; } = "";

    [JsonPropertyName("isDir")]
    public bool IsDir { get; set; }

    [JsonPropertyName("size")]
    public long Size { get; set; }

    [JsonPropertyName("mtime")]
    public long Mtime { get; set; }

    [JsonIgnore]
    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (_isSelected != value)
            {
                _isSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
            }
        }
    }

    [JsonIgnore]
    public string Category => IsDir ? "Folders" : GetCategory(Name);

    [JsonIgnore]
    public string TypeLabel => IsDir ? "Folder" : GetTypeLabel(Name);

    [JsonIgnore]
    public string Icon => IsDir ? "📁" : GetFileEmoji(Name);

    [JsonIgnore]
    public string SizeText => IsDir ? "Folder" : FormatBytes(Size);

    [JsonIgnore]
    public string ModifiedText => Mtime > 0
        ? DateTimeOffset.FromUnixTimeSeconds(Mtime).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
        : "";

    public static string FormatBytes(long bytes)
    {
        long safe = Math.Max(0, bytes);
        if (safe < 1024) return $"{safe} B";
        if (safe < 1024L * 1024L) return $"{safe / 1024.0:0.0} KB";
        if (safe < 1024L * 1024L * 1024L) return $"{safe / (1024.0 * 1024.0):0.00} MB";
        return $"{safe / (1024.0 * 1024.0 * 1024.0):0.00} GB";
    }

    public static string FormatEta(double seconds)
    {
        if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds < 0 || seconds > 86400 * 7) return "--";
        if (seconds < 60) return $"{Math.Ceiling(seconds):0}s";
        if (seconds < 3600) return $"{(int)(seconds / 60)}m {(int)(seconds % 60)}s";
        return $"{(int)(seconds / 3600)}h {(int)((seconds % 3600) / 60)}m";
    }

    public static string GetCategory(string name)
    {
        string ext = System.IO.Path.GetExtension(name).ToLowerInvariant();
        return ext switch
        {
            ".mp4" or ".mov" or ".m4v" or ".mkv" or ".webm" or ".avi" or ".ts" or ".wmv" => "Videos",
            ".jpg" or ".jpeg" or ".png" or ".heic" or ".gif" or ".webp" or ".bmp" or ".raw" or ".dng" => "Photos",
            ".mp3" or ".m4a" or ".wav" or ".aac" or ".flac" or ".ogg" or ".opus" or ".aiff" => "Audio",
            ".zip" or ".rar" or ".7z" or ".tar" or ".gz" or ".ipa" or ".apk" or ".exe" or ".msi" => "Archives",
            ".pdf" or ".doc" or ".docx" or ".xls" or ".xlsx" or ".ppt" or ".pptx" or ".txt" or ".md" or ".csv" or ".json" => "Docs",
            _ => "Other"
        };
    }

    public static string GetTypeLabel(string name)
    {
        string ext = System.IO.Path.GetExtension(name).TrimStart('.').ToUpperInvariant();
        return string.IsNullOrEmpty(ext) ? "File" : ext;
    }

    public static string GetFileEmoji(string name)
    {
        string ext = System.IO.Path.GetExtension(name).ToLowerInvariant();
        return ext switch
        {
            ".mp4" or ".mov" or ".m4v" or ".mkv" or ".webm" or ".avi" or ".ts" => "🎬",
            ".mp3" or ".m4a" or ".wav" or ".aac" or ".flac" or ".ogg" or ".aiff" => "🎵",
            ".jpg" or ".jpeg" or ".png" or ".heic" or ".gif" or ".webp" or ".bmp" => "🖼️",
            ".zip" or ".rar" or ".7z" or ".tar" or ".gz" or ".ipa" or ".apk" or ".exe" or ".msi" => "📦",
            ".pdf" or ".doc" or ".docx" or ".txt" or ".md" or ".csv" or ".json" => "📄",
            _ => "📄"
        };
    }
}

public sealed class UsbDeviceSummary
{
    public string DeviceId { get; init; } = "";
    public string FriendlyName { get; init; } = "USB Device";
    public string Manufacturer { get; init; } = "";
    public string Model { get; init; } = "";
    public bool IsApple => (Manufacturer + " " + FriendlyName).Contains("Apple", StringComparison.OrdinalIgnoreCase)
                        || (Manufacturer + " " + FriendlyName).Contains("iPhone", StringComparison.OrdinalIgnoreCase)
                        || (Manufacturer + " " + FriendlyName).Contains("iPad", StringComparison.OrdinalIgnoreCase);

    public string Icon => IsApple ? "🍎" : "🤖";
    public string DisplayName => $"{Icon} {FriendlyName} ({(string.IsNullOrWhiteSpace(Manufacturer) ? "USB MTP" : Manufacturer)})";
}

public sealed class UsbFileItem : INotifyPropertyChanged
{
    private bool _isSelected;
    public event PropertyChangedEventHandler? PropertyChanged;

    public string Name { get; init; } = "";
    public string FullPath { get; init; } = "";
    public bool IsDir { get; init; }
    public long Size { get; init; }
    public DateTime? Modified { get; init; }

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (_isSelected != value)
            {
                _isSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
            }
        }
    }

    public string Category => IsDir ? "Folders" : RemoteFileItem.GetCategory(Name);
    public string TypeLabel => IsDir ? "Folder" : RemoteFileItem.GetTypeLabel(Name);
    public string Icon => IsDir ? "📁" : RemoteFileItem.GetFileEmoji(Name);
    public string SizeText => IsDir ? "Folder" : RemoteFileItem.FormatBytes(Size);
    public string ModifiedText => (Modified.HasValue && Modified.Value.Year >= 1980)
        ? Modified.Value.ToString("yyyy-MM-dd HH:mm")
        : "";
}

public sealed class TransferProgressInfo
{
    public string FileName { get; init; } = "";
    public long TransferredBytes { get; init; }
    public long TotalBytes { get; init; }
    public double BytesPerSecond { get; init; }
    public int FileIndex { get; init; }
    public int FileCount { get; init; }
}

public sealed class TransferHistoryEntry
{
    public string Timestamp { get; init; } = DateTime.Now.ToString("HH:mm:ss");
    public string Transport { get; init; } = "Wi-Fi";
    public string Direction { get; init; } = "↓";
    public string FileName { get; init; } = "";
    public long Bytes { get; init; }
    public double AvgBytesPerSec { get; init; }
    public string Status { get; init; } = "Completed";
    public string LocalPath { get; init; } = "";

    public string SizeText => RemoteFileItem.FormatBytes(Bytes);
    public string SpeedText => AvgBytesPerSec > 0 ? $"{RemoteFileItem.FormatBytes((long)AvgBytesPerSec)}/s" : "--";
}

public sealed class SavedConnectionSettings
{
    public string LastEndpoint { get; set; } = "";
    public string LastPin { get; set; } = "";
    public string DownloadDirectory { get; set; } = "";
    public string HostSharedDirectory { get; set; } = "";
    public string HostFixedPin { get; set; } = "";
    public int ParallelStreams { get; set; } = 3;
    public string ConflictPolicy { get; set; } = "Rename"; // Rename | Overwrite | Skip
}
