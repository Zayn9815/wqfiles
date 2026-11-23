using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.Json;

namespace WQGlassTransfer;

public sealed class TransferClient : IDisposable
{
    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string _pin;

    public TransferClient(string endpoint, string pin)
    {
        string clean = endpoint.Trim().TrimEnd('/');
        if (!clean.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
            !clean.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            clean = "http://" + clean;
        }
        _baseUrl = clean;
        _pin = pin.Trim();
        _http = new HttpClient
        {
            Timeout = Timeout.InfiniteTimeSpan
        };
    }

    private HttpRequestMessage CreateRequest(HttpMethod method, string relativeUrl)
    {
        var req = new HttpRequestMessage(method, _baseUrl + relativeUrl);
        req.Headers.Add("X-WQ-PIN", _pin);
        return req;
    }

    public async Task<PhoneInfo> GetInfoAsync(CancellationToken ct = default)
    {
        using var req = CreateRequest(HttpMethod.Get, "/api/info");
        using var resp = await _http.SendAsync(req, ct);
        if (resp.StatusCode == HttpStatusCode.Unauthorized)
            throw new InvalidOperationException("Incorrect PIN. Please check the PIN shown on the target device.");
        resp.EnsureSuccessStatusCode();
        string json = await resp.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<PhoneInfo>(json) ?? new PhoneInfo();
    }

    public async Task<RemoteListResponse> ListAsync(string remotePath, CancellationToken ct = default)
    {
        string q = Uri.EscapeDataString(remotePath ?? "");
        using var req = CreateRequest(HttpMethod.Get, $"/api/list?path={q}");
        using var resp = await _http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
        string json = await resp.Content.ReadAsStringAsync(ct);
        return JsonSerializer.Deserialize<RemoteListResponse>(json) ?? new RemoteListResponse();
    }

    public async Task CreateFolderAsync(string remotePath, CancellationToken ct = default)
    {
        string q = Uri.EscapeDataString(remotePath);
        using var req = CreateRequest(HttpMethod.Post, $"/api/mkdir?path={q}");
        using var resp = await _http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
    }

    public async Task DeleteAsync(string remotePath, CancellationToken ct = default)
    {
        string q = Uri.EscapeDataString(remotePath);
        using var req = CreateRequest(HttpMethod.Post, $"/api/delete?path={q}");
        using var resp = await _http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
    }

    public async Task RenameAsync(string remotePath, string newName, CancellationToken ct = default)
    {
        string q1 = Uri.EscapeDataString(remotePath);
        string q2 = Uri.EscapeDataString(newName);
        using var req = CreateRequest(HttpMethod.Post, $"/api/rename?path={q1}&to={q2}");
        using var resp = await _http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
    }

    public async Task DownloadFileAsync(
        string remotePath,
        string localDestinationPath,
        int fileIndex,
        int fileCount,
        IProgress<TransferProgressInfo>? progress,
        CancellationToken ct)
    {
        string q = Uri.EscapeDataString(remotePath);
        using var req = CreateRequest(HttpMethod.Get, $"/api/download?path={q}");
        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();

        long total = resp.Content.Headers.ContentLength ?? -1;
        string? dir = Path.GetDirectoryName(localDestinationPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        string fileName = Path.GetFileName(localDestinationPath);
        var sw = Stopwatch.StartNew();
        long received = 0;
        byte[] buffer = new byte[256 * 1024];

        await using Stream netStream = await resp.Content.ReadAsStreamAsync(ct);
        await using FileStream fs = new(localDestinationPath, FileMode.Create, FileAccess.Write, FileShare.None, buffer.Length, useAsync: true);

        double lastReportMs = 0;
        int read;
        while ((read = await netStream.ReadAsync(buffer.AsMemory(0, buffer.Length), ct)) > 0)
        {
            await fs.WriteAsync(buffer.AsMemory(0, read), ct);
            received += read;
            double ms = sw.Elapsed.TotalMilliseconds;
            if (ms - lastReportMs >= 100 || (total > 0 && received >= total))
            {
                lastReportMs = ms;
                double bps = ms > 1 ? received / (ms / 1000.0) : 0;
                progress?.Report(new TransferProgressInfo
                {
                    FileName = fileName,
                    TransferredBytes = received,
                    TotalBytes = total > 0 ? total : received,
                    BytesPerSecond = bps,
                    FileIndex = fileIndex,
                    FileCount = fileCount
                });
            }
        }
    }

    public async Task UploadFileAsync(
        string remoteDir,
        string localFilePath,
        int fileIndex,
        int fileCount,
        IProgress<TransferProgressInfo>? progress,
        CancellationToken ct)
    {
        var fi = new FileInfo(localFilePath);
        if (!fi.Exists) throw new FileNotFoundException("Local file not found.", localFilePath);

        string qDir = Uri.EscapeDataString(remoteDir ?? "");
        string qName = Uri.EscapeDataString(fi.Name);
        using var req = CreateRequest(HttpMethod.Post, $"/api/upload?path={qDir}&name={qName}");
        req.Content = new StreamingFileContent(localFilePath, fi.Name, fi.Length, fileIndex, fileCount, progress, ct);
        using var resp = await _http.SendAsync(req, ct);
        resp.EnsureSuccessStatusCode();
    }

    public void Dispose() => _http.Dispose();

    private sealed class StreamingFileContent : HttpContent
    {
        private readonly string _path;
        private readonly string _name;
        private readonly long _length;
        private readonly int _index;
        private readonly int _count;
        private readonly IProgress<TransferProgressInfo>? _progress;
        private readonly CancellationToken _ct;

        public StreamingFileContent(string path, string name, long length, int index, int count, IProgress<TransferProgressInfo>? progress, CancellationToken ct)
        {
            _path = path;
            _name = name;
            _length = length;
            _index = index;
            _count = count;
            _progress = progress;
            _ct = ct;
            Headers.ContentLength = length;
        }

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            byte[] buffer = new byte[256 * 1024];
            long sent = 0;
            var sw = Stopwatch.StartNew();
            double lastReportMs = 0;

            await using FileStream fs = new(_path, FileMode.Open, FileAccess.Read, FileShare.Read, buffer.Length, useAsync: true);
            int read;
            while ((read = await fs.ReadAsync(buffer.AsMemory(0, buffer.Length), _ct)) > 0)
            {
                await stream.WriteAsync(buffer.AsMemory(0, read), _ct);
                sent += read;
                double ms = sw.Elapsed.TotalMilliseconds;
                if (ms - lastReportMs >= 100 || sent >= _length)
                {
                    lastReportMs = ms;
                    double bps = ms > 1 ? sent / (ms / 1000.0) : 0;
                    _progress?.Report(new TransferProgressInfo
                    {
                        FileName = _name,
                        TransferredBytes = sent,
                        TotalBytes = _length,
                        BytesPerSecond = bps,
                        FileIndex = _index,
                        FileCount = _count
                    });
                }
            }
        }

        protected override bool TryComputeLength(out long length)
        {
            length = _length;
            return true;
        }
    }
}
