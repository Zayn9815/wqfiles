using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using MediaDevices;

namespace WQGlassTransfer;

/// <summary>
/// Thread-safe STA-affinity Windows WPD/MTP USB Cable transfer engine.
/// All MediaDevice COM calls execute on a dedicated ApartmentState.STA worker thread
/// so folder navigation &amp; file listing work reliably on Android (Infinix, Samsung, Xiaomi, Pixel) &amp; iPhone.
/// </summary>
public sealed class UsbTransferService : IDisposable
{
    private readonly BlockingCollection<Action> _staQueue = new();
    private readonly Thread _staThread;
    private MediaDevice? _activeDevice;
    private volatile bool _disposed;

    public bool IsConnected => _activeDevice is not null;
    public UsbDeviceSummary? ConnectedSummary { get; private set; }

    public UsbTransferService()
    {
        _staThread = new Thread(StaLoop)
        {
            IsBackground = true,
            Name = "WQGlass-WPD-STA"
        };
        _staThread.SetApartmentState(ApartmentState.STA);
        _staThread.Start();
    }

    private void StaLoop()
    {
        foreach (Action work in _staQueue.GetConsumingEnumerable())
        {
            try { work(); } catch { }
        }
    }

    private Task<T> RunOnStaAsync<T>(Func<T> func)
    {
        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (_disposed)
        {
            tcs.TrySetCanceled();
            return tcs.Task;
        }
        try
        {
            _staQueue.Add(() =>
            {
                try { tcs.TrySetResult(func()); }
                catch (Exception ex) { tcs.TrySetException(ex); }
            });
        }
        catch (Exception ex)
        {
            tcs.TrySetException(ex);
        }
        return tcs.Task;
    }

    public Task<List<UsbDeviceSummary>> EnumerateConnectedDevicesAsync()
    {
        return RunOnStaAsync(() =>
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
                // Ignore transient WPD errors during hot-plug.
            }
            return list;
        });
    }

    public Task<(bool ok, string? error)> ConnectAsync(UsbDeviceSummary summary)
    {
        return RunOnStaAsync(() =>
        {
            DisconnectInternal();
            try
            {
                MediaDevice? match = null;
                foreach (MediaDevice d in MediaDevice.GetDevices())
                {
                    if (match is null && string.Equals(d.DeviceId, summary.DeviceId, StringComparison.OrdinalIgnoreCase))
                        match = d;
                    else
                        d.Dispose();
                }

                if (match is null)
                    return (false, (string?)"USB device is no longer connected. Replug the cable and unlock your phone.");

                match.Connect();
                _activeDevice = match;
                ConnectedSummary = summary;
                return (true, (string?)null);
            }
            catch (Exception ex)
            {
                return (false, (string?)$"Could not open USB device: {ex.Message}\n\nMake sure your phone is unlocked and set to File Transfer (MTP) / Trust This Computer.");
            }
        });
    }

    public Task DisconnectAsync()
    {
        return RunOnStaAsync(() =>
        {
            DisconnectInternal();
            return true;
        });
    }

    private void DisconnectInternal()
    {
        if (_activeDevice is not null)
        {
            try { _activeDevice.Disconnect(); } catch { }
            try { _activeDevice.Dispose(); } catch { }
            _activeDevice = null;
        }
        ConnectedSummary = null;
    }

    public Task<List<UsbFileItem>> ListDirectoryAsync(string path)
    {
        return RunOnStaAsync(() => ListDirectoryInternal(path));
    }

    private List<UsbFileItem> ListDirectoryInternal(string path)
    {
        MediaDevice dev = RequireDevice();
        string norm = NormalizeUsbPath(path);
        var items = new List<UsbFileItem>();

        try
        {
            MediaDirectoryInfo dir = dev.GetDirectoryInfo(norm);
            foreach (MediaDirectoryInfo sub in dir.EnumerateDirectories())
            {
                string full = NormalizeUsbPath(sub.FullName);
                items.Add(new UsbFileItem
                {
                    Name = sub.Name,
                    FullPath = full,
                    IsDir = true,
                    Size = 0,
                    Modified = SanitizeDate(sub.LastWriteTime)
                });
            }
            foreach (MediaFileInfo file in dir.EnumerateFiles())
            {
                string full = NormalizeUsbPath(file.FullName);
                items.Add(new UsbFileItem
                {
                    Name = file.Name,
                    FullPath = full,
                    IsDir = false,
                    Size = (long)file.Length,
                    Modified = SanitizeDate(file.LastWriteTime)
                });
            }
        }
        catch
        {
            // Fallback via flat path APIs for Android MTP implementations that dislike GetDirectoryInfo on certain nodes.
            foreach (string subPath in dev.GetDirectories(norm))
            {
                string full = NormalizeUsbPath(subPath);
                string name = Path.GetFileName(full.TrimEnd('\\'));
                if (string.IsNullOrWhiteSpace(name)) name = full.Trim('\\');
                items.Add(new UsbFileItem
                {
                    Name = name,
                    FullPath = full,
                    IsDir = true,
                    Size = 0,
                    Modified = null
                });
            }
            foreach (string filePath in dev.GetFiles(norm))
            {
                string full = NormalizeUsbPath(filePath);
                long size = 0;
                DateTime? mod = null;
                try
                {
                    var fi = dev.GetFileInfo(full);
                    size = (long)fi.Length;
                    mod = SanitizeDate(fi.LastWriteTime);
                }
                catch { }
                items.Add(new UsbFileItem
                {
                    Name = Path.GetFileName(full),
                    FullPath = full,
                    IsDir = false,
                    Size = size,
                    Modified = mod
                });
            }
        }

        return items
            .OrderByDescending(i => i.IsDir)
            .ThenBy(i => i.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public Task<List<(string remotePath, string localPath, long size)>> CollectExportsRecursiveAsync(
        IReadOnlyList<UsbFileItem> items, string localRoot, CancellationToken ct)
    {
        return RunOnStaAsync(() =>
        {
            var jobs = new List<(string remotePath, string localPath, long size)>();
            void Walk(UsbFileItem it, string localBase)
            {
                ct.ThrowIfCancellationRequested();
                if (it.IsDir)
                {
                    string subLocal = Path.Combine(localBase, it.Name);
                    Directory.CreateDirectory(subLocal);
                    foreach (var child in ListDirectoryInternal(it.FullPath))
                        Walk(child, subLocal);
                }
                else
                {
                    jobs.Add((it.FullPath, Path.Combine(localBase, it.Name), it.Size));
                }
            }
            foreach (var it in items) Walk(it, localRoot);
            return jobs;
        });
    }

    public Task<long> ExportFileAsync(
        string remoteUsbPath,
        string localDestinationPath,
        long knownSize,
        int fileIndex,
        int fileCount,
        string conflictPolicy,
        IProgress<TransferProgressInfo>? progress,
        CancellationToken ct)
    {
        return RunOnStaAsync(() =>
        {
            ct.ThrowIfCancellationRequested();
            MediaDevice dev = RequireDevice();
            string finalDest = TransferClient.ResolveConflictPath(localDestinationPath, conflictPolicy, out bool skip);
            if (skip) return 0L;

            string? dir = Path.GetDirectoryName(finalDest);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

            string fileName = Path.GetFileName(finalDest);
            using var fs = new FileStream(finalDest, FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 1024);
            using var tracker = new ProgressStream(fs, knownSize, fileName, fileIndex, fileCount, progress, ct);
            dev.DownloadFile(NormalizeUsbPath(remoteUsbPath), tracker);
            tracker.FlushFinal();
            return tracker.TotalProcessed;
        });
    }

    public Task<long> ImportFileAsync(
        string localFilePath,
        string remoteUsbDir,
        int fileIndex,
        int fileCount,
        IProgress<TransferProgressInfo>? progress,
        CancellationToken ct)
    {
        return RunOnStaAsync(() =>
        {
            ct.ThrowIfCancellationRequested();
            MediaDevice dev = RequireDevice();
            var fi = new FileInfo(localFilePath);
            if (!fi.Exists) throw new FileNotFoundException("Local file not found.", localFilePath);

            string normDir = NormalizeUsbPath(remoteUsbDir);
            string targetPath = normDir == "\\" ? "\\" + fi.Name : normDir + "\\" + fi.Name;

            using var fs = new FileStream(localFilePath, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024);
            using var tracker = new ProgressStream(fs, fi.Length, fi.Name, fileIndex, fileCount, progress, ct);
            dev.UploadFile(tracker, targetPath);
            tracker.FlushFinal();
            return fi.Length;
        });
    }

    public Task CreateFolderAsync(string parentUsbPath, string folderName)
    {
        return RunOnStaAsync(() =>
        {
            MediaDevice dev = RequireDevice();
            string norm = NormalizeUsbPath(parentUsbPath);
            string target = norm == "\\" ? "\\" + folderName : norm + "\\" + folderName;
            if (!dev.DirectoryExists(target)) dev.CreateDirectory(target);
            return true;
        });
    }

    public Task DeleteItemsAsync(IReadOnlyList<UsbFileItem> items)
    {
        return RunOnStaAsync(() =>
        {
            MediaDevice dev = RequireDevice();
            foreach (var item in items)
            {
                string p = NormalizeUsbPath(item.FullPath);
                if (item.IsDir) dev.DeleteDirectory(p, recursive: true);
                else dev.DeleteFile(p);
            }
            return true;
        });
    }

    public static string NormalizeUsbPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return "\\";
        string p = path.Replace('/', '\\').Trim();
        if (!p.StartsWith('\\')) p = "\\" + p;
        if (p.Length > 1) p = p.TrimEnd('\\');
        return p;
    }

    public static string GetParentUsbPath(string path)
    {
        string p = NormalizeUsbPath(path);
        if (p == "\\") return "\\";
        int idx = p.LastIndexOf('\\');
        return idx <= 0 ? "\\" : p[..idx];
    }

    private static DateTime? SanitizeDate(DateTime? dt)
    {
        if (!dt.HasValue || dt.Value.Year < 1980) return null;
        return dt;
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
            else if (File.Exists(c)) return c;
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
            if (proc is null) { message = "Failed to launch ADB."; return false; }
            string stderr = proc.StandardError.ReadToEnd().Trim();
            proc.WaitForExit(5000);
            if (proc.ExitCode == 0)
            {
                message = $"USB Turbo Tunnel active! Connect to 127.0.0.1:{localPort} (full USB cable speed).";
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
        return _activeDevice ?? throw new InvalidOperationException("No USB device connected.");
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { _staQueue.Add(DisconnectInternal); } catch { }
        _staQueue.CompleteAdding();
    }

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
            if (n > 0) { TotalProcessed += n; Report(); }
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
