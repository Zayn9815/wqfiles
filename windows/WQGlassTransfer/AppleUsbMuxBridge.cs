using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Xml.Linq;

namespace WQGlassTransfer;

public sealed class AppleUsbDeviceInfo
{
    public int DeviceId { get; init; }
    public string SerialNumber { get; init; } = "";
    public string DisplayName => string.IsNullOrWhiteSpace(SerialNumber)
        ? $"🍎 iPhone App Documents & Downloads (USB #{DeviceId})"
        : $"🍎 iPhone App Documents & Downloads (USB · {SerialNumber[..Math.Min(8, SerialNumber.Length)]}…)";
}

/// <summary>
/// Pure-C# Apple usbmuxd (127.0.0.1:27015) USB cable bridge.
/// Tunnels WQGlass Transfer HTTP directly over Lightning / USB-C cable (like iTunes / 3uTools)
/// giving full access to iPhone WQ Glass Documents, Downloads, and Selected Files with zero Wi-Fi needed.
/// </summary>
public sealed class AppleUsbMuxBridge : IDisposable
{
    private const string MuxHost = "127.0.0.1";
    private const int MuxPort = 27015;
    private const int MuxVersion = 1;
    private const int MuxMsgPlist = 8;
    private const int PipeBufferSize = 1024 * 1024;

    private TcpListener? _localListener;
    private CancellationTokenSource? _cts;
    private int _tag = 1;

    public bool IsForwarding => _localListener is not null;
    public int LocalPort { get; private set; }
    public int ActiveDeviceId { get; private set; }

    public List<AppleUsbDeviceInfo> ListUsbDevices()
    {
        var result = new List<AppleUsbDeviceInfo>();
        try
        {
            using var tcp = new TcpClient();
            if (!tcp.ConnectAsync(MuxHost, MuxPort).Wait(1200)) return result;
            tcp.ReceiveTimeout = 2000;
            tcp.SendTimeout = 2000;
            using NetworkStream ns = tcp.GetStream();

            string plist =
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
                "<plist version=\"1.0\"><dict>" +
                "<key>MessageType</key><string>ListDevices</string>" +
                "<key>ClientVersionString</key><string>WQGlassTransfer</string>" +
                "<key>ProgName</key><string>WQGlassTransfer</string>" +
                "</dict></plist>";

            SendPacket(ns, plist, Interlocked.Increment(ref _tag));
            string? reply = ReadPacket(ns);
            if (string.IsNullOrWhiteSpace(reply)) return result;

            var doc = XDocument.Parse(reply);
            XElement? rootDict = doc.Root?.Element("dict");
            if (rootDict is null) return result;

            XElement? devArray = GetPlistValue(rootDict, "DeviceList");
            if (devArray is null) return result;

            foreach (XElement devDict in devArray.Elements("dict"))
            {
                string? idStr = GetPlistValue(devDict, "DeviceID")?.Value;
                if (!int.TryParse(idStr, out int devId)) continue;

                XElement? props = GetPlistValue(devDict, "Properties");
                string connType = props is not null ? (GetPlistValue(props, "ConnectionType")?.Value ?? "") : "";
                if (!string.Equals(connType, "USB", StringComparison.OrdinalIgnoreCase)) continue;

                string serial = props is not null ? (GetPlistValue(props, "SerialNumber")?.Value ?? "") : "";
                result.Add(new AppleUsbDeviceInfo
                {
                    DeviceId = devId,
                    SerialNumber = serial
                });
            }
        }
        catch
        {
            // Apple Mobile Device Service (usbmuxd) not installed or not running.
        }
        return result;
    }

    public bool StartTunnel(int deviceId, int remoteIphonePort, out string localEndpoint, out string? error)
    {
        StopTunnel();
        localEndpoint = "";
        error = null;

        // First probe one connection to verify WQ Glass server on the iPhone is listening.
        try
        {
            using TcpClient testMux = ConnectToIphonePort(deviceId, remoteIphonePort, out string? muxErr);
            if (muxErr is not null)
            {
                error = muxErr;
                return false;
            }
        }
        catch (Exception ex)
        {
            error = $"Could not reach WQ Glass on iPhone over USB: {ex.Message}\n\nOpen WQ Glass on your iPhone → LAN Transfer (Share iPhone) first.";
            return false;
        }

        try
        {
            _cts = new CancellationTokenSource();
            _localListener = new TcpListener(IPAddress.Loopback, 0);
            _localListener.Start(64);
            LocalPort = ((IPEndPoint)_localListener.LocalEndpoint).Port;
            ActiveDeviceId = deviceId;
            localEndpoint = $"127.0.0.1:{LocalPort}";

            CancellationToken ct = _cts.Token;
            _ = Task.Run(() => AcceptLoopAsync(deviceId, remoteIphonePort, ct), ct);
            return true;
        }
        catch (Exception ex)
        {
            StopTunnel();
            error = $"Failed to start local USB tunnel: {ex.Message}";
            return false;
        }
    }

    public void StopTunnel()
    {
        try { _cts?.Cancel(); } catch { }
        try { _localListener?.Stop(); } catch { }
        _localListener = null;
        _cts?.Dispose();
        _cts = null;
        LocalPort = 0;
        ActiveDeviceId = 0;
    }

    private async Task AcceptLoopAsync(int deviceId, int remotePort, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && _localListener is not null)
        {
            try
            {
                TcpClient client = await _localListener.AcceptTcpClientAsync(ct);
                _ = Task.Run(() => PumpConnectionAsync(client, deviceId, remotePort, ct), ct);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch { }
        }
    }

    private async Task PumpConnectionAsync(TcpClient localClient, int deviceId, int remotePort, CancellationToken ct)
    {
        using (localClient)
        {
            localClient.NoDelay = true;
            localClient.SendBufferSize = 4 * 1024 * 1024;
            localClient.ReceiveBufferSize = 4 * 1024 * 1024;

            TcpClient? muxClient = null;
            try
            {
                muxClient = ConnectToIphonePort(deviceId, remotePort, out string? err);
                if (err is not null) return;

                muxClient.NoDelay = true;
                muxClient.SendBufferSize = 4 * 1024 * 1024;
                muxClient.ReceiveBufferSize = 4 * 1024 * 1024;

                await using NetworkStream localStream = localClient.GetStream();
                await using NetworkStream muxStream = muxClient.GetStream();

                Task t1 = localStream.CopyToAsync(muxStream, PipeBufferSize, ct);
                Task t2 = muxStream.CopyToAsync(localStream, PipeBufferSize, ct);
                await Task.WhenAny(t1, t2);
            }
            catch
            {
                // Normal socket close.
            }
            finally
            {
                muxClient?.Dispose();
            }
        }
    }

    private TcpClient ConnectToIphonePort(int deviceId, int remotePort, out string? error)
    {
        error = null;
        var tcp = new TcpClient { NoDelay = true };
        if (!tcp.ConnectAsync(MuxHost, MuxPort).Wait(2500))
        {
            tcp.Dispose();
            error = "Apple Mobile Device Service (usbmuxd) did not respond on 127.0.0.1:27015. Install iTunes, Apple Devices, or 3uTools driver.";
            return new TcpClient();
        }
        tcp.ReceiveTimeout = 4000;
        tcp.SendTimeout = 4000;
        NetworkStream ns = tcp.GetStream();

        int portNetworkOrder = ((remotePort & 0xFF) << 8) | ((remotePort >> 8) & 0xFF);
        string plist =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" +
            "<plist version=\"1.0\"><dict>" +
            "<key>MessageType</key><string>Connect</string>" +
            $"<key>DeviceID</key><integer>{deviceId}</integer>" +
            $"<key>PortNumber</key><integer>{portNetworkOrder}</integer>" +
            "<key>ClientVersionString</key><string>WQGlassTransfer</string>" +
            "<key>ProgName</key><string>WQGlassTransfer</string>" +
            "</dict></plist>";

        SendPacket(ns, plist, Interlocked.Increment(ref _tag));
        string? reply = ReadPacket(ns);
        if (string.IsNullOrWhiteSpace(reply))
        {
            tcp.Dispose();
            error = "Empty reply from Apple usbmuxd.";
            return new TcpClient();
        }

        var doc = XDocument.Parse(reply);
        XElement? rootDict = doc.Root?.Element("dict");
        string? numStr = rootDict is not null ? GetPlistValue(rootDict, "Number")?.Value : null;
        if (numStr != "0")
        {
            tcp.Dispose();
            error = "iPhone is plugged in via USB, but WQ Glass Transfer server is not open on port 8765.\n\nOpen WQ Glass on your iPhone → Utility Hub → LAN Transfer (Share iPhone) and try again!";
            return new TcpClient();
        }

        // Remove short handshake timeout for large file streaming
        tcp.ReceiveTimeout = 0;
        tcp.SendTimeout = 0;
        return tcp;
    }

    private static void SendPacket(NetworkStream ns, string xmlPayload, int tag)
    {
        byte[] body = Encoding.UTF8.GetBytes(xmlPayload);
        byte[] hdr = new byte[16];
        BinaryPrimitives.WriteUInt32LittleEndian(hdr.AsSpan(0, 4), (uint)(16 + body.Length));
        BinaryPrimitives.WriteUInt32LittleEndian(hdr.AsSpan(4, 4), MuxVersion);
        BinaryPrimitives.WriteUInt32LittleEndian(hdr.AsSpan(8, 4), MuxMsgPlist);
        BinaryPrimitives.WriteUInt32LittleEndian(hdr.AsSpan(12, 4), (uint)tag);
        ns.Write(hdr, 0, hdr.Length);
        ns.Write(body, 0, body.Length);
        ns.Flush();
    }

    private static string? ReadPacket(NetworkStream ns)
    {
        byte[] hdr = new byte[16];
        if (!ReadExact(ns, hdr, 16)) return null;
        uint totalLen = BinaryPrimitives.ReadUInt32LittleEndian(hdr.AsSpan(0, 4));
        if (totalLen < 16 || totalLen > 4 * 1024 * 1024) return null;
        int bodyLen = (int)(totalLen - 16);
        byte[] body = new byte[bodyLen];
        if (bodyLen > 0 && !ReadExact(ns, body, bodyLen)) return null;
        return Encoding.UTF8.GetString(body);
    }

    private static bool ReadExact(NetworkStream ns, byte[] buf, int count)
    {
        int offset = 0;
        while (offset < count)
        {
            int n = ns.Read(buf, offset, count - offset);
            if (n <= 0) return false;
            offset += n;
        }
        return true;
    }

    private static XElement? GetPlistValue(XElement dict, string keyName)
    {
        bool next = false;
        foreach (XElement el in dict.Elements())
        {
            if (next) return el;
            if (el.Name == "key" && string.Equals(el.Value, keyName, StringComparison.Ordinal))
                next = true;
        }
        return null;
    }

    public void Dispose() => StopTunnel();
}
