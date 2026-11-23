package com.wqglass.transfer

import android.content.Context
import android.net.wifi.WifiManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentHashMap

class DiscoveryService(
    context: Context,
    private val localServerPortProvider: () -> Int?
) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val peersMap = ConcurrentHashMap<String, DiscoveredPeer>()
    private val _peers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    val peers: StateFlow<List<DiscoveredPeer>> = _peers.asStateFlow()

    @Volatile
    private var socket: DatagramSocket? = null
    private var listenJob: Job? = null
    private var probeJob: Job? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    fun start() {
        if (listenJob != null) return
        try {
            val wm = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wm?.createMulticastLock("WQGlassDiscovery")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }

        val sock = try {
            DatagramSocket(null).apply {
                reuseAddress = true
                broadcast = true
                soTimeout = 1000
                bind(InetSocketAddress(ProtocolUtils.DISCOVERY_PORT))
            }
        } catch (_: Exception) {
            try {
                DatagramSocket().apply {
                    broadcast = true
                    soTimeout = 1000
                }
            } catch (_: Exception) {
                return
            }
        }
        socket = sock

        listenJob = scope.launch {
            val buf = ByteArray(2048)
            while (isActive) {
                try {
                    val pkt = DatagramPacket(buf, buf.size)
                    sock.receive(pkt)
                    val text = String(pkt.data, pkt.offset, pkt.length, Charsets.UTF_8)
                    if (!text.contains("\"WQGlass\"")) continue
                    val json = JSONObject(text)
                    if (json.optString("app") != "WQGlass") continue

                    val ip = json.optString("ip").ifBlank { pkt.address?.hostAddress ?: "" }
                    if (ip.isBlank()) continue
                    val port = json.optInt("port", ProtocolUtils.BASE_HTTP_PORT)

                    val selfPort = localServerPortProvider()
                    if (selfPort != null && port == selfPort && isLocalAddress(ip)) {
                        continue
                    }

                    val peer = DiscoveredPeer(
                        app = "WQGlass",
                        version = json.optString("version", "1.0"),
                        device = json.optString("device", "Device"),
                        platform = json.optString("platform", "ios"),
                        osVersion = json.optString("osVersion", ""),
                        ip = ip,
                        port = port,
                        root = json.optString("root", "Downloads"),
                        lastSeenMs = System.currentTimeMillis()
                    )
                    peersMap[peer.endpoint] = peer
                    publishPeers()
                } catch (_: SocketTimeoutException) {
                    pruneStale()
                } catch (_: Exception) {
                    if (!isActive) break
                }
            }
        }

        probeJob = scope.launch {
            while (isActive) {
                sendProbeInternal()
                pruneStale()
                delay(2000)
            }
        }
    }

    fun sendProbeNow() {
        scope.launch { sendProbeInternal(unicastSweep = true) }
    }

    private fun sendProbeInternal(unicastSweep: Boolean = false) {
        val s = socket ?: return
        val probe = "WQGLASS_DISCOVER".toByteArray(Charsets.UTF_8)
        for (target in getBroadcastAddresses()) {
            try {
                s.send(DatagramPacket(probe, probe.size, target, ProtocolUtils.DISCOVERY_PORT))
            } catch (_: Exception) {
            }
        }
        if (unicastSweep) {
            val localIp = TransferServer.detectLanIpv4()
            val parts = localIp.split('.')
            if (parts.size == 4) {
                val prefix = "${parts[0]}.${parts[1]}.${parts[2]}"
                val selfHost = parts[3].toIntOrNull() ?: -1
                for (host in 1..254) {
                    if (host == selfHost) continue
                    try {
                        val addr = InetAddress.getByName("$prefix.$host")
                        s.send(DatagramPacket(probe, probe.size, addr, ProtocolUtils.DISCOVERY_PORT))
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    private fun pruneStale() {
        val now = System.currentTimeMillis()
        var removed = false
        val iter = peersMap.entries.iterator()
        while (iter.hasNext()) {
            val e = iter.next()
            if (now - e.value.lastSeenMs > 12_000L) {
                iter.remove()
                removed = true
            }
        }
        if (removed) publishPeers()
    }

    private fun publishPeers() {
        _peers.value = peersMap.values.sortedBy { it.device.lowercase() }
    }

    fun stop() {
        listenJob?.cancel()
        probeJob?.cancel()
        listenJob = null
        probeJob = null
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    fun close() {
        stop()
        scope.cancel()
    }

    companion object {
        fun getBroadcastAddresses(): List<InetAddress> {
            val out = LinkedHashSet<InetAddress>()
            try {
                out.add(InetAddress.getByName("255.255.255.255"))
                val ifaces = NetworkInterface.getNetworkInterfaces()
                while (ifaces != null && ifaces.hasMoreElements()) {
                    val ni = ifaces.nextElement()
                    if (!ni.isUp || ni.isLoopback) continue
                    for (ia in ni.interfaceAddresses) {
                        val b = ia.broadcast
                        if (b is Inet4Address) out.add(b)
                        val a = ia.address
                        if (a is Inet4Address && !a.isLoopbackAddress) {
                            val parts = (a.hostAddress ?: "").split('.')
                            if (parts.size == 4 && (parts[0] == "192" || parts[0] == "10" || parts[0] == "172")) {
                                runCatching { out.add(InetAddress.getByName("${parts[0]}.${parts[1]}.${parts[2]}.255")) }
                            }
                        }
                    }
                }
            } catch (_: Exception) {
            }
            return out.toList()
        }

        fun getLocalIpv4Addresses(): Set<String> {
            val out = HashSet<String>()
            try {
                val ifaces = NetworkInterface.getNetworkInterfaces()
                while (ifaces != null && ifaces.hasMoreElements()) {
                    val ni = ifaces.nextElement()
                    if (!ni.isUp || ni.isLoopback) continue
                    val addrs = ni.inetAddresses
                    while (addrs.hasMoreElements()) {
                        val a = addrs.nextElement()
                        if (a is Inet4Address && !a.isLoopbackAddress) {
                            a.hostAddress?.let { out.add(it) }
                        }
                    }
                }
            } catch (_: Exception) {
            }
            return out
        }

        fun isLocalAddress(ip: String): Boolean {
            if (ip == "127.0.0.1") return true
            return getLocalIpv4Addresses().contains(ip)
        }
    }
}
