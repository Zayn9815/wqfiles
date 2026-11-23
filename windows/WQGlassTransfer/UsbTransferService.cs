using System.Diagnostics;
using System.IO;
using MediaDevices;

namespace WQGlassTransfer;

public sealed class UsbTransferService : IDisposable
{
    private MediaDevice? _activeDevice;
    private readonly object _gate = new();

    public bool IsConnected => _activeDevice is not null;
    public UsbDeviceSummary? ConnectedSummary { get; private set; }

    public List<UsbDeviceSummary> EnumerateConnectedDevices()
    {
        var list = new List<UsbDeviceSummary>();
        try
        {
            foreach (MediaDevice dev in MediaDevice.GetDevices())
            {
                try
                {
                    list.Add(new UsbDeviceSummary
                    {
                        DeviceId = dev.DeviceId ?? "",
                        FriendlyName = string.IsNullOrWhiteSpace(dev.FriendlyName) ? (dev.Description ?? "USB Device") : dev.FriendlyName,
                        Manufacturer = dev.Manufacturer ?? "",
                        Model = dev.Description ?? ""
                    });
                }
                finally
                {
                    dev.Dispose();
                }
            }
        }
        catch
        {
            // Ignore transient WPD enumeration errors during hot-plug.
        }
        return list;
    }

    public bool Connect(UsbDeviceSummary summary, out string? error)
    {
        Disconnect();
        error = null;
        try
        {
            MediaDevice? match = MediaDevice.GetDevices()
                .FirstOrDefault(d => string.Equals(d.DeviceId, summary.DeviceId, StringComparison.OrdinalIgnoreCase));
            if (match is null)
            {
                error = "USB device is no longer connected. Replug the cable and unlock your phone.";
                return false;
            }
            match.Connect();
            lock (_gate)
            {
                _activeDevice = match;
                ConnectedSummary = summary;
            }
            return true;
        }
        catch (Exception ex)
        {
            error = $"Could not open USB device: {ex.Message}\n\nMake sure your phone is unlocked and set to File Transfer (MTP) / Trust This Computer.";
            return false;
        }
    }

    public void Disconnect()
    {
        lock (_gate)
        {
            if (_activeDevice is not null)
            {
                try { _activeDevice.Disconnect(); } catch { }
                try { _activeDevice.Dispose(); } catch { }
                _activeDevice = null;
            }
            ConnectedSummary = null;
        }
    }

    public List<UsbFileItem> ListDirectory(string path)
    {
        MediaDevice dev = RequireDevice();
        string norm = NormalizeUsbPath(path);
        var items = new List<UsbFileItem>();

        MediaDirectoryInfo dir = dev.GetDirectoryInfo(norm);
        foreach (MediaDirectoryInfo sub in dir.EnumerateDirectories())
        {
            items.Add(new UsbFileItem
            {
                Name = sub.Name,
                FullPath = sub.FullName,
                IsDir = true,
                Size = 0,
                Modified = sub.LastWriteTime
            });
        }
        foreach (MediaFileInfo file in dir.EnumerateFiles())
        {
            items.Add(new UsbFileItem
            {
                Name = file.Name,
                FullPath = file.FullName,
                IsDir = false,
                Size = (long)file.Length,
                Modified = file.LastWriteTime
            });
        }

        return items
            .OrderByDescending(i => i.IsDir)
            .ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public long ExportFile(
        string remoteUsbPath,
        string localDestinationPath,
        long knownSize,
        int fileIndex,
        int fileCount,
        string conflictPolicy,
        IProgress<TransferProgressInfo>? progress,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        MediaDevice dev = RequireDevice();
        string finalDest = TransferClient.ResolveConflictPath(localDestinationPath, conflictPolicy, out bool skip);
        if (skip) return 0;

        string? dir = Path.GetDirectoryName(finalDest);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        string fileName = Path.GetFileName(finalDest);
        using var fs = new FileStream(finalDest, FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 1024);
        using var tracker = new ProgressStream(fs, knownSize, fileName, fileIndex, fileCount, progress, ct);
        dev.DownloadFile(remoteUsbPath, tracker);
        tracker.FlushFinal();
        return tracker.TotalProcessed;
    }

    public long ImportFile(
        string localFilePath,
        string remoteUsbDir,
        int fileIndex,
        int fileCount,
        IProgress<TransferProgressInfo>? progress,
        CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        MediaDevice dev = RequireDevice();
        var fi = new FileInfo(localFilePath);
        if (!fi.Exists) throw new FileNotFoundException("Local file not found.", localFilePath);

        string normDir = NormalizeUsbPath(remoteUsbDir);
        string targetPath = normDir.EndsWith('\\') ? normDir + fi.Name : normDir + "\\" + fi.Name;

        using var fs = new FileStream(localFilePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024);
        using var tracker = new ProgressStream(fs, fi.Length, fi.Name, fileIndex, fileCount, progress, ct);
        dev.UploadFile(tracker, targetPath);
        tracker.FlushFinal();
        return fi.Length;
    }

    public void CreateFolder(string parentUsbPath, string folderName)
    {
        MediaDevice dev = RequireDevice();
        string norm = NormalizeUsbPath(parentUsbPath);
        string target = norm.EndsWith('\\') ? norm + folderName : norm + "\\" + folderName;
        dev.CreateDirectory(target);
    }

    public void DeleteItem(UsbFileItem item)
    {
        MediaDevice dev = RequireDevice();
        if (item.IsDir) dev.DeleteDirectory(item.FullPath, recursive: true);
        else dev.DeleteFile(item.FullPath);
    }

    public static string NormalizeUsbPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return "\\";
        string p = path.Replace('/', '\\').Trim();
        if (!p.StartsWith('\\')) p = "\\" + p;
        return p;
    }

    public static string GetParentUsbPath(string path)
    {
        string p = NormalizeUsbPath(path).TrimEnd('\\');
        if (string.IsNullOrEmpty(p)) return "\\";
        int idx = p.LastIndexOf('\\');
        return idx <= 0 ? "\\" : p[..idx];
    }

    public static string? FindAdbExecutable()
    {
        string[] candidates =
        {
            "adb.exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk", "platform-tools", "adb.exe"),
            @"C:\platform-tools\adb.exe"
        };
        foreach (string c in candidates)
        {
            if (c == "adb.exe")
            {
                try
                {
                    var psi = new ProcessStartInfo("where.exe", "adb.exe")
                    {
                        RedirectStandardOutput = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    };
                    using var p = Process.Start(psi);
                    if (p is not null)
                    {
                        string outStr = p.StandardOutput.ReadToEnd().Trim();
                        p.WaitForExit(1500);
                        if (p.ExitCode == 0 && !string.IsNullOrWhiteSpace(outStr))
                            return outStr.Split('\n')[0].Trim();
                    }
                }
                catch { }
            }
            else if (File.Exists(c))
            {
                return c;
            }
        }
        return null;
    }

    public static bool TrySetupAdbUsbTunnel(int localPort, int remotePort, out string message)
    {
        string? adb = FindAdbExecutable();
        if (string.IsNullOrEmpty(adb))
        {
            message = "ADB not found on this PC. Native USB MTP Explorer above works without ADB!";
            return false;
        }
        try
        {
            var psi = new ProcessStartInfo(adb, $"forward tcp:{localPort} tcp:{remotePort}")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var proc = Process.Start(psi);
            if (proc is null)
            {
                message = "Failed to launch ADB.";
                return false;
            }
            string stderr = proc.StandardError.ReadToEnd().Trim();
            proc.WaitForExit(5000);
            if (proc.ExitCode == 0)
            {
                message = $"USB Turbo Tunnel active! Connect Wi-Fi Client to 127.0.0.1:{localPort} (full USB cable speed).";
                return true;
            }
            message = string.IsNullOrWhiteSpace(stderr) ? "No ADB-authorized Android device detected." : stderr;
            return false;
        }
        catch (Exception ex)
        {
            message = ex.Message;
            return false;
        }
    }

    private MediaDevice RequireDevice()
    {
        lock (_gate)
        {
            return _activeDevice ?? throw new InvalidOperationException("No USB device connected.");
        }
    }

    public void Dispose() => Disconnect();

    private sealed class ProgressStream : Stream
    {
        private readonly Stream _inner;
        private readonly long _total;
        private readonly string _fileName;
        private readonly int _index;
        private readonly int _count;
        private readonly IProgress<TransferProgressInfo>? _progress;
        private readonly CancellationToken _ct;
        private readonly Stopwatch _sw = Stopwatch.StartNew();
        private double _lastReportMs;

        public long TotalProcessed { get; private set; }

        public ProgressStream(Stream inner, long total, string fileName, int index, int count, IProgress<TransferProgressInfo>? progress, CancellationToken ct)
        {
            _inner = inner;
            _total = total;
            _fileName = fileName;
            _index = index;
            _count = count;
            _progress = progress;
            _ct = ct;
        }

        private void Report(bool force = false)
        {
            double ms = _sw.Elapsed.TotalMilliseconds;
            if (!force && ms - _lastReportMs < 80) return;
            _lastReportMs = ms;
            double bps = ms > 1 ? TotalProcessed / (ms / 1000.0) : 0;
            _progress?.Report(new TransferProgressInfo
            {
                FileName = _fileName,
                TransferredBytes = TotalProcessed,
                TotalBytes = _total > 0 ? _total : TotalProcessed,
                BytesPerSecond = bps,
                FileIndex = _index,
                FileCount = _count
            });
        }

        public void FlushFinal() => Report(force: true);

        public override bool CanRead => _inner.CanRead;
        public override bool CanSeek => _inner.CanSeek;
        public override bool CanWrite => _inner.CanWrite;
        public override long Length => _inner.Length;
        public override long Position { get => _inner.Position; set => _inner.Position = value; }
        public override void Flush() => _inner.Flush();

        public override int Read(byte[] buffer, int offset, int count)
        {
            _ct.ThrowIfCancellationRequested();
            int n = _inner.Read(buffer, offset, count);
            if (n > 0)
            {
                TotalProcessed += n;
                Report();
            }
            return n;
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            _ct.ThrowIfCancellationRequested();
            _inner.Write(buffer, offset, count);
            TotalProcessed += count;
            Report();
        }

        public override long Seek(long offset, SeekOrigin origin) => _inner.Seek(offset, origin);
        public override void SetLength(long value) => _inner.SetLength(value);
    }
}
