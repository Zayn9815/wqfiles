using System.Text.Json.Serialization;

namespace WQGlassTransfer;

public sealed class DiscoveredPhone
{
    [JsonPropertyName("app")]
    public string App { get; set; } = "";

    [JsonPropertyName("version")]
    public string Version { get; set; } = "";

    [JsonPropertyName("device")]
    public string Device { get; set; } = "iPhone";

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
    public string DisplayName => $"{Device} ({Ip}:{Port}) · {Root}";
}

public sealed class PhoneInfo
{
    [JsonPropertyName("device")]
    public string Device { get; set; } = "iPhone";

    [JsonPropertyName("ios")]
    public string IosVersion { get; set; } = "";

    [JsonPropertyName("root")]
    public string Root { get; set; } = "Downloads";

    [JsonPropertyName("freeBytes")]
    public long FreeBytes { get; set; }

    [JsonPropertyName("totalBytes")]
    public long TotalBytes { get; set; }
}

public sealed class RemoteListResponse
{
    [JsonPropertyName("path")]
    public string Path { get; set; } = "";

    [JsonPropertyName("items")]
    public List<RemoteFileItem> Items { get; set; } = new();
}

public sealed class RemoteFileItem
{
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
    public string Icon => IsDir ? "📁" : GetFileEmoji(Name);

    [JsonIgnore]
    public string SizeText => IsDir ? "Folder" : FormatBytes(Size);

    [JsonIgnore]
    public string ModifiedText => Mtime > 0
        ? DateTimeOffset.FromUnixTimeSeconds(Mtime).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
        : "";

    public static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        if (bytes < 1024L * 1024L) return $"{bytes / 1024.0:0.0} KB";
        if (bytes < 1024L * 1024L * 1024L) return $"{bytes / (1024.0 * 1024.0):0.00} MB";
        return $"{bytes / (1024.0 * 1024.0 * 1024.0):0.00} GB";
    }

    private static string GetFileEmoji(string name)
    {
        string ext = System.IO.Path.GetExtension(name).ToLowerInvariant();
        return ext switch
        {
            ".mp4" or ".mov" or ".m4v" or ".mkv" or ".webm" or ".ts" => "🎬",
            ".mp3" or ".m4a" or ".wav" or ".aac" or ".flac" or ".aiff" => "🎵",
            ".jpg" or ".jpeg" or ".png" or ".heic" or ".gif" or ".webp" => "🖼️",
            ".zip" or ".rar" or ".7z" or ".tar" or ".gz" or ".ipa" => "📦",
            ".pdf" or ".doc" or ".docx" or ".txt" or ".md" => "📄",
            _ => "📄"
        };
    }
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

public sealed class SavedConnectionSettings
{
    public string LastEndpoint { get; set; } = "";
    public string LastPin { get; set; } = "";
    public string DownloadDirectory { get; set; } = "";
}
