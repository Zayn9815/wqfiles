using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace WQGlassTransfer;

public sealed class DiscoveryService : IDisposable
{
    private const int DiscoveryPort = 45888;
    private readonly CancellationTokenSource _cts = new();
    private UdpClient? _udp;

    public event Action<DiscoveredPhone>? PhoneDiscovered;

    public void Start()
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
            // Fallback to ephemeral port if 45888 is already bound; active probes still receive unicast replies.
            try
            {
                _udp = new UdpClient(0) { EnableBroadcast = true };
            }
            catch
            {
                return;
            }
        }

        _ = Task.Run(() => ListenLoopAsync(_cts.Token));
        _ = Task.Run(() => ProbeLoopAsync(_cts.Token));
    }

    public void SendProbeNow()
    {
        if (_udp is null) return;
        try
        {
            byte[] probe = Encoding.UTF8.GetBytes("WQGLASS_DISCOVER");
            _udp.Send(probe, probe.Length, new IPEndPoint(IPAddress.Broadcast, DiscoveryPort));
        }
        catch
        {
            // Ignore transient network errors when Wi-Fi is disconnected.
        }
    }

    private async Task ProbeLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            SendProbeNow();
            try
            {
                await Task.Delay(2000, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task ListenLoopAsync(CancellationToken ct)
    {
        if (_udp is null) return;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                UdpReceiveResult res = await _udp.ReceiveAsync(ct);
                string text = Encoding.UTF8.GetString(res.Buffer);
                if (!text.Contains("\"WQGlass\"", StringComparison.Ordinal)) continue;
                DiscoveredPhone? phone = JsonSerializer.Deserialize<DiscoveredPhone>(text);
                if (phone is null || !string.Equals(phone.App, "WQGlass", StringComparison.Ordinal)) continue;
                if (string.IsNullOrWhiteSpace(phone.Ip)) phone.Ip = res.RemoteEndPoint.Address.ToString();
                phone.LastSeenUtc = DateTime.UtcNow;
                PhoneDiscovered?.Invoke(phone);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                // Ignore malformed packets on LAN.
            }
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _udp?.Close(); } catch { }
        _udp?.Dispose();
        _cts.Dispose();
    }
}
