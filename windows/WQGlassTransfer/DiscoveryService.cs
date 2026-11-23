using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace WQGlassTransfer;

public sealed class DiscoveryService : IDisposable
{
    private const int DiscoveryPort = 45888;
    private readonly CancellationTokenSource _cts = new();
    private UdpClient? _udp;

    public Func<int?>? LocalServerPortProvider { get; set; }

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
        byte[] probe = Encoding.UTF8.GetBytes("WQGLASS_DISCOVER");
        foreach (IPAddress target in GetBroadcastTargets())
        {
            try
            {
                _udp.Send(probe, probe.Length, new IPEndPoint(target, DiscoveryPort));
            }
            catch
            {
                // Ignore transient network errors when Wi-Fi is disconnected.
            }
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

                // Filter out this machine's own host server beacon so it never lists itself.
                int? localPort = LocalServerPortProvider?.Invoke();
                if (localPort.HasValue && phone.Port == localPort.Value && IsLocalAddress(phone.Ip))
                {
                    continue;
                }

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

    internal static List<IPAddress> GetBroadcastTargets()
    {
        var targets = new List<IPAddress> { IPAddress.Broadcast };
        var seen = new HashSet<string> { IPAddress.Broadcast.ToString() };
        try
        {
            foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (UnicastIPAddressInformation ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    byte[] ip = ua.Address.GetAddressBytes();
                    byte[] mask = ua.IPv4Mask?.GetAddressBytes() ?? new byte[] { 255, 255, 255, 0 };
                    byte[] bcast = new byte[4];
                    for (int i = 0; i < 4; i++) bcast[i] = (byte)(ip[i] | ~mask[i]);
                    var addr = new IPAddress(bcast);
                    if (seen.Add(addr.ToString())) targets.Add(addr);
                }
            }
        }
        catch { }
        return targets;
    }

    internal static bool IsLocalAddress(string ip)
    {
        if (string.IsNullOrWhiteSpace(ip)) return false;
        if (ip == "127.0.0.1" || ip == "::1") return true;
        try
        {
            foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                foreach (UnicastIPAddressInformation ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily == AddressFamily.InterNetwork &&
                        string.Equals(ua.Address.ToString(), ip, StringComparison.Ordinal))
                    {
                        return true;
                    }
                }
            }
        }
        catch { }
        return false;
    }

    public void Dispose()
    {
        _cts.Cancel();
        try { _udp?.Close(); } catch { }
        _udp?.Dispose();
        _cts.Dispose();
    }
}
