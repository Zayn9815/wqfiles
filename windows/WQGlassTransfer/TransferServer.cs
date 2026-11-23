using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace WQGlassTransfer;

public sealed class TransferServer : IDisposable
{
    private const int DiscoveryPort = 45888;
    private const int BasePort = 8765;
    private const int ChunkBytes = 1024 * 1024;
    private const int SocketBufBytes = 4 * 1024 * 1024;
    private const int MaxHeaderBytes = 16384;

    private CancellationTokenSource? _cts;
    private TcpListener? _listener;
    private UdpClient? _udp;

    public bool IsRunning { get; private set; }
    public string IpAddress { get; private set; } = "";
    public int Port { get; private set; } = BasePort;
    public string Pin { get; set; } = GenerateRandomPin();
    public string RootPath { get; set; }
    public string RootLabel { get; set; }

    public event Action<string>? ActivityLogged;
    public event Action<string>? TextReceived;

    public TransferServer()
    {
        string downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        RootPath = Directory.Exists(downloads) ? downloads : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        RootLabel = Path.GetFileName(RootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        if (string.IsNullOrWhiteSpace(RootLabel)) RootLabel = "PC";
    }

    public static string GenerateRandomPin()
    {
        return RandomNumberGenerator.GetInt32(1000, 10000).ToString(CultureInfo.InvariantCulture);
    }

    public bool Start(out string? error)
    {
        Stop();
        error = null;

        try
        {
            Directory.CreateDirectory(RootPath);
        }
        catch (Exception ex)
        {
            error = $"Shared folder is unavailable: {ex.Message}";
            return false;
        }

        string ip = GetLocalLanIpv4();
        if (string.IsNullOrWhiteSpace(ip))
        {
            error = "No active Wi-Fi / LAN IPv4 address detected. Connect to Wi-Fi and try again.";
            return false;
        }

        TcpListener? bound = null;
        int chosenPort = BasePort;
        for (int candidate = BasePort; candidate < BasePort + 16; candidate++)
        {
            var l = new TcpListener(IPAddress.Any, candidate);
            try
            {
                l.Start(64);
                bound = l;
                chosenPort = candidate;
                break;
            }
            catch
            {
                try { l.Stop(); } catch { }
            }
        }

        if (bound is null)
        {
            error = "Could not bind any port in range 8765–8780.";
            return false;
        }

        _listener = bound;
        IpAddress = ip;
        Port = chosenPort;
        IsRunning = true;
        _cts = new CancellationTokenSource();

        StartUdpDiscovery(_cts.Token);
        _ = Task.Run(() => AcceptLoopAsync(_cts.Token));

        EmitActivity($"PC Host ready at http://{IpAddress}:{Port} · PIN {Pin} · Sharing \"{RootLabel}\"");
        return true;
    }

    public void Stop()
    {
        IsRunning = false;
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); } catch { }
        try { _udp?.Close(); } catch { }
        try { _udp?.Dispose(); } catch { }
        _listener = null;
        _udp = null;
        _cts?.Dispose();
        _cts = null;
    }

    public void Dispose() => Stop();

    private void EmitActivity(string msg)
    {
        string line = $"[{DateTime.Now:HH:mm:ss}] {msg}";
        ActivityLogged?.Invoke(line);
    }

    private string GetOsVersionLabel()
    {
        Version v = Environment.OSVersion.Version;
        if (v.Major == 10 && v.Build >= 22000) return $"Windows 11 (Build {v.Build})";
        if (v.Major == 10) return $"Windows 10 (Build {v.Build})";
        return $"Windows {v.Major}.{v.Minor}";
    }

    private byte[] BuildDiscoveryBeaconBytes()
    {
        var payload = new
        {
            app = "WQGlass",
            version = "1.1",
            device = Environment.MachineName,
            platform = "windows",
            osVersion = GetOsVersionLabel(),
            ip = IpAddress,
            port = Port,
            root = RootLabel,
            pinRequired = true
        };
        return JsonSerializer.SerializeToUtf8Bytes(payload);
    }

    private void StartUdpDiscovery(CancellationToken ct)
    {
        try
        {
            _udp = new UdpClient();
            _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _udp.EnableBroadcast = true;
            _udp.Client.Bind(new IPEndPoint(IPAddress.Any, DiscoveryPort));
        }
        catch
        {
            try
            {
                _udp = new UdpClient(0) { EnableBroadcast = true };
            }
            catch
            {
                return;
            }
        }

        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested && _udp is not null)
            {
                try
                {
                    UdpReceiveResult res = await _udp.ReceiveAsync(ct);
                    string text = Encoding.UTF8.GetString(res.Buffer);
                    if (text.Contains("WQGLASS_DISCOVER", StringComparison.Ordinal))
                    {
                        byte[] reply = BuildDiscoveryBeaconBytes();
                        await _udp.SendAsync(reply, reply.Length, res.RemoteEndPoint);
                    }
                }
                catch (OperationCanceledException) { break; }
                catch { }
            }
        }, ct);

        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested && _udp is not null)
            {
                try
                {
                    byte[] pkt = BuildDiscoveryBeaconBytes();
                    foreach (IPAddress target in DiscoveryService.GetBroadcastTargets())
                    {
                        try
                        {
                            await _udp.SendAsync(pkt, pkt.Length, new IPEndPoint(target, DiscoveryPort));
                        }
                        catch { }
                    }
                }
                catch { }

                try { await Task.Delay(1500, ct); }
                catch (OperationCanceledException) { break; }
            }
        }, ct);
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _listener is not null)
        {
            try
            {
                TcpClient client = await _listener.AcceptTcpClientAsync(ct);
                _ = Task.Run(() => HandleClientAsync(client, ct), ct);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException) when (ct.IsCancellationRequested) { break; }
            catch { }
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
    {
        using (client)
        {
            client.NoDelay = true;
            client.SendBufferSize = SocketBufBytes;
            client.ReceiveBufferSize = SocketBufBytes;

            try
            {
                await using NetworkStream net = client.GetStream();
                var headerBuf = new MemoryStream();
                byte[] tmp = new byte[8192];
                int headerEnd = -1;

                while (headerBuf.Length < MaxHeaderBytes)
                {
                    int n = await net.ReadAsync(tmp.AsMemory(0, tmp.Length), ct);
                    if (n <= 0) return;
                    headerBuf.Write(tmp, 0, n);

                    byte[] arr = headerBuf.GetBuffer();
                    int len = (int)headerBuf.Length;
                    headerEnd = FindHeaderEnd(arr, len);
                    if (headerEnd >= 0) break;
                }

                if (headerEnd < 0)
                {
                    await SendJsonAsync(net, 400, new { error = "Malformed HTTP request" }, ct);
                    return;
                }

                byte[] allBytes = headerBuf.GetBuffer();
                int totalBuffered = (int)headerBuf.Length;
                string headerText = Encoding.UTF8.GetString(allBytes, 0, headerEnd);
                int bodyOffset = headerEnd + 4;
                int leftoverCount = totalBuffered - bodyOffset;
                byte[] leftover = leftoverCount > 0 ? allBytes[bodyOffset..totalBuffered] : Array.Empty<byte>();

                string[] lines = headerText.Split("\r\n", StringSplitOptions.None);
                if (lines.Length == 0) return;
                string[] reqParts = lines[0].Split(' ');
                if (reqParts.Length < 2) return;

                string method = reqParts[0].ToUpperInvariant();
                string rawTarget = reqParts[1];

                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (int i = 1; i < lines.Length; i++)
                {
                    int colon = lines[i].IndexOf(':');
                    if (colon > 0)
                    {
                        string k = lines[i][..colon].Trim();
                        string v = lines[i][(colon + 1)..].Trim();
                        headers[k] = v;
                    }
                }

                if (method == "OPTIONS")
                {
                    await SendRawAsync(net, 204, "No Content", "text/plain", Array.Empty<byte>(), ct);
                    return;
                }

                string route = rawTarget;
                string queryStr = "";
                int qIdx = rawTarget.IndexOf('?');
                if (qIdx >= 0)
                {
                    route = rawTarget[..qIdx];
                    queryStr = rawTarget[(qIdx + 1)..];
                }
                Dictionary<string, string> query = ParseQuery(queryStr);

                if (method == "GET" && (route == "/" || route == "/index.html"))
                {
                    byte[] html = Encoding.UTF8.GetBytes(BuildWebUiHtml());
                    await SendRawAsync(net, 200, "OK", "text/html; charset=utf-8", html, ct);
                    return;
                }

                headers.TryGetValue("X-WQ-PIN", out string? pinHeader);
                query.TryGetValue("pin", out string? pinQuery);
                string suppliedPin = (pinHeader ?? pinQuery ?? "").Trim();
                if (!string.Equals(suppliedPin, Pin, StringComparison.Ordinal))
                {
                    await SendJsonAsync(net, 401, new { error = "Invalid PIN" }, ct);
                    return;
                }

                string root = RootPath;

                if (route == "/api/info" && method == "GET")
                {
                    long freeBytes = 0, totalBytes = 0;
                    try
                    {
                        string? driveRoot = Path.GetPathRoot(Path.GetFullPath(root));
                        if (!string.IsNullOrEmpty(driveRoot))
                        {
                            var di = new DriveInfo(driveRoot);
                            freeBytes = di.AvailableFreeSpace;
                            totalBytes = di.TotalSize;
                        }
                    }
                    catch { }

                    await SendJsonAsync(net, 200, new
                    {
                        app = "WQGlass",
                        version = "1.1",
                        device = Environment.MachineName,
                        platform = "windows",
                        osVersion = GetOsVersionLabel(),
                        ios = GetOsVersionLabel(),
                        root = RootLabel,
                        freeBytes,
                        totalBytes
                    }, ct);

                    string remoteIp = (client.Client.RemoteEndPoint as IPEndPoint)?.Address.ToString() ?? "Peer";
                    EmitActivity($"Connected: {remoteIp} verified PIN");
                    return;
                }

                if (route == "/api/list" && method == "GET")
                {
                    query.TryGetValue("path", out string? rel);
                    rel ??= "";
                    string? target = SafeResolvePath(root, rel);
                    if (target is null || !Directory.Exists(target))
                    {
                        await SendJsonAsync(net, 404, new { error = "Directory not found" }, ct);
                        return;
                    }

                    var items = new List<object>();
                    var dirInfo = new DirectoryInfo(target);
                    IEnumerable<FileSystemInfo> entries;
                    try
                    {
                        entries = dirInfo.EnumerateFileSystemInfos()
                            .Where(e => !e.Name.StartsWith(".", StringComparison.Ordinal))
                            .OrderByDescending(e => (e.Attributes & FileAttributes.Directory) != 0)
                            .ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase);
                    }
                    catch (Exception ex)
                    {
                        await SendJsonAsync(net, 500, new { error = ex.Message }, ct);
                        return;
                    }

                    foreach (FileSystemInfo entry in entries)
                    {
                        bool isDir = (entry.Attributes & FileAttributes.Directory) != 0;
                        long size = 0;
                        if (!isDir && entry is FileInfo fi)
                        {
                            try { size = fi.Length; } catch { }
                        }
                        long mtime = 0;
                        try { mtime = new DateTimeOffset(entry.LastWriteTimeUtc).ToUnixTimeSeconds(); } catch { }
                        string childRel = string.IsNullOrEmpty(rel) ? entry.Name : $"{rel.TrimEnd('/')}/{entry.Name}";
                        items.Add(new
                        {
                            name = entry.Name,
                            path = childRel,
                            isDir,
                            size,
                            mtime
                        });
                    }

                    await SendJsonAsync(net, 200, new { path = rel, items }, ct);
                    return;
                }

                if (route == "/api/download" && (method == "GET" || method == "HEAD"))
                {
                    query.TryGetValue("path", out string? rel);
                    string? target = SafeResolvePath(root, rel ?? "");
                    if (target is null || !File.Exists(target))
                    {
                        await SendJsonAsync(net, 404, new { error = "File not found" }, ct);
                        return;
                    }

                    var fi = new FileInfo(target);
                    string safeName = fi.Name.Replace("\"", "_");
                    string hdr =
                        $"HTTP/1.1 200 OK\r\n" +
                        $"Content-Type: application/octet-stream\r\n" +
                        $"Content-Length: {fi.Length}\r\n" +
                        $"Content-Disposition: attachment; filename=\"{safeName}\"\r\n" +
                        $"Access-Control-Allow-Origin: *\r\n" +
                        $"Connection: close\r\n\r\n";
                    byte[] hdrBytes = Encoding.UTF8.GetBytes(hdr);
                    await net.WriteAsync(hdrBytes, ct);

                    if (method == "HEAD") return;

                    byte[] buffer = new byte[ChunkBytes];
                    await using (FileStream fs = new(target, FileMode.Open, FileAccess.Read, FileShare.Read, ChunkBytes, useAsync: true))
                    {
                        int read;
                        while ((read = await fs.ReadAsync(buffer.AsMemory(0, buffer.Length), ct)) > 0)
                        {
                            await net.WriteAsync(buffer.AsMemory(0, read), ct);
                        }
                    }

                    EmitActivity($"↑ Sent to device: {fi.Name} ({RemoteFileItem.FormatBytes(fi.Length)})");
                    return;
                }

                if (route == "/api/upload" && method == "POST")
                {
                    query.TryGetValue("path", out string? relDir);
                    query.TryGetValue("name", out string? rawName);
                    string cleanName = Path.GetFileName((rawName ?? "").Replace('\\', '/'));
                    if (string.IsNullOrWhiteSpace(cleanName) || cleanName == "." || cleanName == "..")
                    {
                        await SendJsonAsync(net, 400, new { error = "Missing file name" }, ct);
                        return;
                    }

                    string? dirTarget = SafeResolvePath(root, relDir ?? "");
                    if (dirTarget is null)
                    {
                        await SendJsonAsync(net, 403, new { error = "Forbidden path" }, ct);
                        return;
                    }
                    Directory.CreateDirectory(dirTarget);

                    if (!headers.TryGetValue("Content-Length", out string? clStr) ||
                        !long.TryParse(clStr, NumberStyles.Integer, CultureInfo.InvariantCulture, out long contentLength) ||
                        contentLength < 0)
                    {
                        await SendJsonAsync(net, 411, new { error = "Content-Length required" }, ct);
                        return;
                    }

                    string dst = UniqueUploadPath(dirTarget, cleanName);
                    long written = 0;
                    await using (FileStream fs = new(dst, FileMode.Create, FileAccess.Write, FileShare.None, ChunkBytes, useAsync: true))
                    {
                        if (leftover.Length > 0 && contentLength > 0)
                        {
                            int toWrite = (int)Math.Min(leftover.Length, contentLength);
                            await fs.WriteAsync(leftover.AsMemory(0, toWrite), ct);
                            written += toWrite;
                        }

                        byte[] buf = new byte[ChunkBytes];
                        while (written < contentLength)
                        {
                            int want = (int)Math.Min(buf.Length, contentLength - written);
                            int n = await net.ReadAsync(buf.AsMemory(0, want), ct);
                            if (n <= 0) break;
                            await fs.WriteAsync(buf.AsMemory(0, n), ct);
                            written += n;
                        }
                    }

                    if (written < contentLength)
                    {
                        try { File.Delete(dst); } catch { }
                        await SendJsonAsync(net, 400, new { error = "Incomplete upload" }, ct);
                        return;
                    }

                    await SendJsonAsync(net, 200, new { ok = true, name = Path.GetFileName(dst), size = written }, ct);
                    EmitActivity($"↓ Received from device: {Path.GetFileName(dst)} ({RemoteFileItem.FormatBytes(written)})");
                    return;
                }

                if (route == "/api/mkdir" && method == "POST")
                {
                    query.TryGetValue("path", out string? rel);
                    string? target = SafeResolvePath(root, rel ?? "");
                    if (target is null)
                    {
                        await SendJsonAsync(net, 403, new { error = "Invalid path" }, ct);
                        return;
                    }
                    Directory.CreateDirectory(target);
                    await SendJsonAsync(net, 200, new { ok = true }, ct);
                    EmitActivity($"+ Created folder: {rel}");
                    return;
                }

                if (route == "/api/delete" && method == "POST")
                {
                    query.TryGetValue("path", out string? rel);
                    string? target = SafeResolvePath(root, rel ?? "");
                    string fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                    if (target is null || string.Equals(target.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), fullRoot, StringComparison.OrdinalIgnoreCase))
                    {
                        await SendJsonAsync(net, 403, new { error = "Cannot delete root" }, ct);
                        return;
                    }
                    if (Directory.Exists(target)) Directory.Delete(target, recursive: true);
                    else if (File.Exists(target)) File.Delete(target);
                    else
                    {
                        await SendJsonAsync(net, 404, new { error = "Not found" }, ct);
                        return;
                    }
                    await SendJsonAsync(net, 200, new { ok = true }, ct);
                    EmitActivity($"🗑 Deleted: {rel}");
                    return;
                }

                if (route == "/api/rename" && method == "POST")
                {
                    query.TryGetValue("path", out string? rel);
                    query.TryGetValue("to", out string? newName);
                    newName = (newName ?? "").Trim();
                    string? src = SafeResolvePath(root, rel ?? "");
                    if (src is null || string.IsNullOrEmpty(newName) || newName.Contains('/') || newName.Contains('\\') || newName == "." || newName == "..")
                    {
                        await SendJsonAsync(net, 400, new { error = "Invalid rename parameters" }, ct);
                        return;
                    }
                    string? parent = Path.GetDirectoryName(src);
                    if (string.IsNullOrEmpty(parent))
                    {
                        await SendJsonAsync(net, 400, new { error = "Invalid parent" }, ct);
                        return;
                    }
                    string dst = Path.Combine(parent, newName);
                    if (Directory.Exists(src)) Directory.Move(src, dst);
                    else if (File.Exists(src)) File.Move(src, dst);
                    else
                    {
                        await SendJsonAsync(net, 404, new { error = "Not found" }, ct);
                        return;
                    }
                    await SendJsonAsync(net, 200, new { ok = true }, ct);
                    EmitActivity($"✎ Renamed to: {newName}");
                    return;
                }

                if (route == "/api/text" && method == "POST")
                {
                    long len = 0;
                    if (headers.TryGetValue("Content-Length", out string? clStr))
                        long.TryParse(clStr, NumberStyles.Integer, CultureInfo.InvariantCulture, out len);
                    len = Math.Clamp(len, 0, 256 * 1024);
                    using var ms = new MemoryStream();
                    if (leftover.Length > 0 && len > 0)
                    {
                        int take = (int)Math.Min(leftover.Length, len);
                        ms.Write(leftover, 0, take);
                    }
                    byte[] tbuf = new byte[8192];
                    while (ms.Length < len)
                    {
                        int want = (int)Math.Min(tbuf.Length, len - ms.Length);
                        int r = await net.ReadAsync(tbuf.AsMemory(0, want), ct);
                        if (r <= 0) break;
                        ms.Write(tbuf, 0, r);
                    }
                    string text = Encoding.UTF8.GetString(ms.ToArray());
                    await SendJsonAsync(net, 200, new { ok = true }, ct);
                    if (!string.IsNullOrWhiteSpace(text))
                    {
                        EmitActivity($"📋 Received text/link ({text.Length} chars)");
                        TextReceived?.Invoke(text);
                    }
                    return;
                }

                await SendJsonAsync(net, 404, new { error = "Not found" }, ct);
            }
            catch
            {
                // Ignore broken client pipe / cancellation.
            }
        }
    }

    private static int FindHeaderEnd(byte[] buf, int length)
    {
        for (int i = 0; i <= length - 4; i++)
        {
            if (buf[i] == '\r' && buf[i + 1] == '\n' && buf[i + 2] == '\r' && buf[i + 3] == '\n')
                return i;
        }
        return -1;
    }

    private static Dictionary<string, string> ParseQuery(string qs)
    {
        var dict = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrEmpty(qs)) return dict;
        foreach (string part in qs.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = part.IndexOf('=');
            if (eq >= 0)
            {
                string k = Uri.UnescapeDataString(part[..eq].Replace('+', ' '));
                string v = Uri.UnescapeDataString(part[(eq + 1)..].Replace('+', ' '));
                dict[k] = v;
            }
            else
            {
                dict[Uri.UnescapeDataString(part.Replace('+', ' '))] = "";
            }
        }
        return dict;
    }

    internal static string? SafeResolvePath(string rootPath, string relPath)
    {
        try
        {
            string fullRoot = Path.GetFullPath(rootPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string normalizedRel = (relPath ?? "").Replace('\\', '/').TrimStart('/');
            if (string.IsNullOrEmpty(normalizedRel)) return fullRoot;

            string combined = Path.GetFullPath(Path.Combine(fullRoot, normalizedRel));
            if (string.Equals(combined, fullRoot, StringComparison.OrdinalIgnoreCase)) return combined;
            if (combined.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return combined;
            return null;
        }
        catch
        {
            return null;
        }
    }

    private static string UniqueUploadPath(string dir, string filename)
    {
        string candidate = Path.Combine(dir, filename);
        if (!File.Exists(candidate)) return candidate;
        string stem = Path.GetFileNameWithoutExtension(filename);
        string ext = Path.GetExtension(filename);
        for (int i = 2; i < 1000; i++)
        {
            string next = Path.Combine(dir, $"{stem}_{i}{ext}");
            if (!File.Exists(next)) return next;
        }
        return Path.Combine(dir, $"{Guid.NewGuid():N}_{filename}");
    }

    private static async Task SendJsonAsync(NetworkStream net, int status, object payload, CancellationToken ct)
    {
        byte[] body = JsonSerializer.SerializeToUtf8Bytes(payload);
        string reason = status switch
        {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            411 => "Length Required",
            _ => "Error"
        };
        await SendRawAsync(net, status, reason, "application/json; charset=utf-8", body, ct);
    }

    private static async Task SendRawAsync(NetworkStream net, int status, string reason, string contentType, byte[] body, CancellationToken ct)
    {
        string hdr =
            $"HTTP/1.1 {status} {reason}\r\n" +
            $"Content-Type: {contentType}\r\n" +
            $"Content-Length: {body.Length}\r\n" +
            $"Access-Control-Allow-Origin: *\r\n" +
            $"Access-Control-Allow-Headers: X-WQ-PIN, Content-Type\r\n" +
            $"Connection: close\r\n\r\n";
        byte[] hdrBytes = Encoding.UTF8.GetBytes(hdr);
        await net.WriteAsync(hdrBytes, ct);
        if (body.Length > 0) await net.WriteAsync(body, ct);
    }

    internal static string GetLocalLanIpv4()
    {
        string? fallback = null;
        try
        {
            foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                    ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;

                string desc = (ni.Description + " " + ni.Name).ToLowerInvariant();
                bool looksVirtual = desc.Contains("vethernet") || desc.Contains("wsl") ||
                                    desc.Contains("hyper-v") || desc.Contains("virtualbox") ||
                                    desc.Contains("vmware") || desc.Contains("docker") ||
                                    desc.Contains("tailscale") || desc.Contains("zerotier");

                IPInterfaceProperties props = ni.GetIPProperties();
                bool hasGateway = props.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork);

                foreach (UnicastIPAddressInformation ua in props.UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    string ip = ua.Address.ToString();
                    if (ip.StartsWith("127.", StringComparison.Ordinal) || ip.StartsWith("169.254.", StringComparison.Ordinal)) continue;

                    if (!looksVirtual && hasGateway &&
                        (ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ||
                         ni.NetworkInterfaceType == NetworkInterfaceType.Ethernet))
                    {
                        return ip;
                    }
                    fallback ??= ip;
                }
            }
        }
        catch { }
        return fallback ?? "";
    }

    private string BuildWebUiHtml()
    {
        string safeDevice = WebUtility.HtmlEncode(Environment.MachineName);
        return
            "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
            $"<title>WQGlass Transfer — {safeDevice}</title>" +
            "<style>" +
            "body{font-family:-apple-system,Segoe UI,sans-serif;background:#0b1120;color:#e2e8f0;margin:0;padding:20px;}" +
            ".wrap{max-width:920px;margin:0 auto;}" +
            ".card{background:#131c31;border:1px solid #24324d;border-radius:16px;padding:18px;margin-bottom:16px;}" +
            "h1{margin:0 0 6px;font-size:21px;color:#fff;} .sub{color:#94a3b8;font-size:13px;}" +
            "input,button{font-size:14px;border-radius:10px;border:1px solid #334155;padding:9px 12px;}" +
            "input{background:#0f172a;color:#fff;} button{background:#2563eb;color:#fff;border:none;cursor:pointer;font-weight:600;}" +
            "button.sec{background:#1e293b;border:1px solid #334155;} button:hover{opacity:.9;}" +
            ".row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:12px;}" +
            "table{width:100%;border-collapse:collapse;margin-top:12px;} th,td{text-align:left;padding:10px 8px;border-bottom:1px solid #1e293b;font-size:14px;}" +
            "a{color:#38bdf8;text-decoration:none;} .sz{color:#94a3b8;font-variant-numeric:tabular-nums;}" +
            ".prog{height:8px;background:#1e293b;border-radius:8px;overflow:hidden;margin-top:10px;display:none;} .prog>div{height:100%;background:#38bdf8;width:0%;}" +
            "</style></head><body><div class=\"wrap\">" +
            $"<div class=\"card\"><h1>💻 WQGlass Transfer — {safeDevice} (Windows PC)</h1>" +
            "<div class=\"sub\" id=\"info\">Enter the PIN shown on WQGlass Transfer to browse, pull, or send files.</div>" +
            "<div class=\"row\"><input id=\"pin\" placeholder=\"4-digit PIN\" maxlength=\"8\" style=\"width:130px;\">" +
            "<button onclick=\"connect()\">Connect</button>" +
            "<button class=\"sec\" onclick=\"goUp()\">↑ Up</button>" +
            "<button class=\"sec\" onclick=\"makeFolder()\">+ New Folder</button>" +
            "<label style=\"background:#2563eb;padding:9px 14px;border-radius:10px;cursor:pointer;font-weight:600;\">⬆ Send Files to PC<input type=\"file\" id=\"up\" multiple style=\"display:none\" onchange=\"uploadFiles(this.files)\"></label>" +
            "</div><div class=\"prog\" id=\"prog\"><div id=\"pfill\"></div></div><div class=\"sub\" id=\"status\" style=\"margin-top:8px;\"></div></div>" +
            "<div class=\"card\"><table><thead><tr><th>Name</th><th>Size</th><th>Action</th></tr></thead><tbody id=\"rows\"></tbody></table></div>" +
            "</div><script>" +
            "let pin='',curPath='';" +
            "function fmt(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(2)+' MB';return (b/1073741824).toFixed(2)+' GB';}" +
            "async function connect(){pin=document.getElementById('pin').value.trim();const r=await fetch('/api/info',{headers:{'X-WQ-PIN':pin}});if(!r.ok){document.getElementById('status').innerText='Invalid PIN';return;}const j=await r.json();document.getElementById('info').innerText=j.device+' ('+(j.osVersion||'Windows')+') · '+j.root+' · Free: '+fmt(j.freeBytes);refresh();}" +
            "async function refresh(){if(!pin)return;const r=await fetch('/api/list?path='+encodeURIComponent(curPath),{headers:{'X-WQ-PIN':pin}});if(!r.ok){document.getElementById('status').innerText='Auth failed';return;}const j=await r.json();const tb=document.getElementById('rows');tb.innerHTML='';for(const it of j.items){const tr=document.createElement('tr');const n=document.createElement('td');if(it.isDir){const a=document.createElement('a');a.href='#';a.textContent='📁 '+it.name;a.onclick=(e)=>{e.preventDefault();curPath=it.path;refresh();};n.appendChild(a);}else{n.textContent='📄 '+it.name;}const s=document.createElement('td');s.className='sz';s.textContent=it.isDir?'Folder':fmt(it.size);const ac=document.createElement('td');if(!it.isDir){const dl=document.createElement('a');dl.href='/api/download?path='+encodeURIComponent(it.path)+'&pin='+encodeURIComponent(pin);dl.textContent='Download';ac.appendChild(dl);}tr.appendChild(n);tr.appendChild(s);tr.appendChild(ac);tb.appendChild(tr);}document.getElementById('status').innerText='Path: /'+curPath+' ('+j.items.length+' items)';}" +
            "function goUp(){if(!curPath)return;const parts=curPath.split('/');parts.pop();curPath=parts.join('/');refresh();}" +
            "async function makeFolder(){const n=prompt('New folder name:');if(!n||!pin)return;const p=curPath?(curPath+'/'+n):n;await fetch('/api/mkdir?path='+encodeURIComponent(p),{method:'POST',headers:{'X-WQ-PIN':pin}});refresh();}" +
            "async function uploadFiles(files){if(!pin||!files.length)return;const pb=document.getElementById('prog'),pf=document.getElementById('pfill');pb.style.display='block';for(let i=0;i<files.length;i++){const f=files[i];document.getElementById('status').innerText='Sending '+f.name+' ('+(i+1)+'/'+files.length+')…';await new Promise((res,rej)=>{const xhr=new XMLHttpRequest();xhr.open('POST','/api/upload?path='+encodeURIComponent(curPath)+'&name='+encodeURIComponent(f.name));xhr.setRequestHeader('X-WQ-PIN',pin);xhr.upload.onprogress=(e)=>{if(e.lengthComputable)pf.style.width=(100*e.loaded/e.total).toFixed(1)+'%';};xhr.onload=()=>res();xhr.onerror=()=>rej();xhr.send(f);});}pb.style.display='none';document.getElementById('status').innerText='Upload complete!';refresh();}" +
            "const qp=new URLSearchParams(location.search).get('pin');if(qp){document.getElementById('pin').value=qp;connect();}" +
            "</script></body></html>";
    }
}
