package com.wqglass.transfer

import android.os.Build
import android.os.StatFs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class HostServerState(
    val isRunning: Boolean = false,
    val ipAddress: String = "",
    val port: Int = ProtocolUtils.BASE_HTTP_PORT,
    val pin: String = "",
    val rootPath: String = "",
    val rootLabel: String = "Downloads",
    val error: String? = null
)

class TransferServer {
    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var udpSocket: DatagramSocket? = null
    private val pool = Executors.newCachedThreadPool()

    @Volatile
    var rootDir: File = File("/storage/emulated/0/Download")

    @Volatile
    var rootLabel: String = "Downloads"

    @Volatile
    var pin: String = generateRandomPin()

    private val _state = MutableStateFlow(HostServerState(pin = pin))
    val state: StateFlow<HostServerState> = _state.asStateFlow()

    private val _logs = MutableStateFlow<List<String>>(emptyList())
    val logs: StateFlow<List<String>> = _logs.asStateFlow()

    private val _receivedText = MutableStateFlow<String?>(null)
    val receivedText: StateFlow<String?> = _receivedText.asStateFlow()

    fun isRunning(): Boolean = running.get()

    fun currentPort(): Int? = if (running.get()) _state.value.port else null

    fun clearReceivedText() {
        _receivedText.value = null
    }

    fun start(sharedDir: File, label: String, desiredPin: String): Boolean {
        stop()
        rootDir = sharedDir
        rootLabel = label.ifBlank { "Downloads" }
        pin = desiredPin.ifBlank { generateRandomPin() }

        if (!sharedDir.exists()) runCatching { sharedDir.mkdirs() }

        val ip = detectLanIpv4()
        if (ip.isBlank()) {
            _state.value = HostServerState(
                isRunning = false,
                pin = pin,
                rootPath = sharedDir.absolutePath,
                rootLabel = rootLabel,
                error = "No active Wi-Fi IPv4 address found. Connect to Wi-Fi and retry."
            )
            return false
        }

        var bound: ServerSocket? = null
        var chosenPort = ProtocolUtils.BASE_HTTP_PORT
        for (p in ProtocolUtils.BASE_HTTP_PORT until ProtocolUtils.BASE_HTTP_PORT + 16) {
            try {
                bound = ServerSocket().apply {
                    reuseAddress = true
                    receiveBufferSize = ProtocolUtils.SOCKET_BUF_BYTES
                    bind(InetSocketAddress(p), 64)
                }
                chosenPort = p
                break
            } catch (_: Exception) {
            }
        }

        if (bound == null) {
            _state.value = HostServerState(
                isRunning = false,
                pin = pin,
                rootPath = sharedDir.absolutePath,
                rootLabel = rootLabel,
                error = "Could not bind TCP port 8765–8780."
            )
            return false
        }

        serverSocket = bound
        running.set(true)
        _state.value = HostServerState(
            isRunning = true,
            ipAddress = ip,
            port = chosenPort,
            pin = pin,
            rootPath = sharedDir.absolutePath,
            rootLabel = rootLabel,
            error = null
        )

        startAcceptLoop(bound)
        startUdpDiscovery()
        log("Android Host ready at http://$ip:$chosenPort · PIN $pin · Sharing \"$rootLabel\"")
        return true
    }

    fun updateRoot(sharedDir: File, label: String) {
        rootDir = sharedDir
        rootLabel = label
        _state.value = _state.value.copy(rootPath = sharedDir.absolutePath, rootLabel = label)
        if (running.get()) log("Switched shared folder to \"$label\" (${sharedDir.absolutePath})")
    }

    fun updatePin(newPin: String) {
        pin = newPin
        _state.value = _state.value.copy(pin = newPin)
    }

    fun clearLogs() {
        _logs.value = emptyList()
    }

    fun stop() {
        val wasRunning = running.getAndSet(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        try { udpSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        udpSocket = null
        _state.value = _state.value.copy(isRunning = false)
        if (wasRunning) log("Android Host stopped.")
    }

    private fun log(message: String) {
        val ts = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
        val line = "[$ts] $message"
        _logs.value = (listOf(line) + _logs.value).take(100)
    }

    private fun deviceName(): String {
        val manu = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        return when {
            model.startsWith(manu, ignoreCase = true) -> model.ifBlank { "Android" }
            manu.isNotBlank() && model.isNotBlank() -> "$manu $model"
            else -> model.ifBlank { "Android" }
        }
    }

    private fun buildBeaconBytes(): ByteArray {
        val st = _state.value
        val obj = JSONObject().apply {
            put("app", "WQGlass")
            put("version", "2.0")
            put("device", deviceName())
            put("platform", "android")
            put("osVersion", Build.VERSION.RELEASE ?: "")
            put("ip", st.ipAddress)
            put("port", st.port)
            put("root", rootLabel)
            put("pinRequired", true)
        }
        return obj.toString().toByteArray(Charsets.UTF_8)
    }

    private fun startUdpDiscovery() {
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
        udpSocket = sock

        pool.execute {
            val buf = ByteArray(512)
            while (running.get()) {
                try {
                    val pkt = DatagramPacket(buf, buf.size)
                    sock.receive(pkt)
                    val msg = String(pkt.data, pkt.offset, pkt.length, Charsets.UTF_8)
                    if (msg.contains("WQGLASS_DISCOVER")) {
                        val reply = buildBeaconBytes()
                        sock.send(DatagramPacket(reply, reply.size, pkt.address, pkt.port))
                    }
                } catch (_: SocketTimeoutException) {
                } catch (_: Exception) {
                    if (!running.get()) break
                }
            }
        }

        pool.execute {
            while (running.get()) {
                try {
                    val pkt = buildBeaconBytes()
                    for (target in DiscoveryService.getBroadcastAddresses()) {
                        try {
                            sock.send(DatagramPacket(pkt, pkt.size, target, ProtocolUtils.DISCOVERY_PORT))
                        } catch (_: Exception) {}
                    }
                } catch (_: Exception) {}
                try { Thread.sleep(1500) } catch (_: InterruptedException) { break }
            }
        }
    }

    private fun startAcceptLoop(ss: ServerSocket) {
        pool.execute {
            while (running.get()) {
                try {
                    val client = ss.accept()
                    pool.execute { handleClient(client) }
                } catch (_: Exception) {
                    if (!running.get()) break
                }
            }
        }
    }

    private fun handleClient(socket: Socket) {
        socket.use { sock ->
            try {
                sock.tcpNoDelay = true
                runCatching {
                    sock.sendBufferSize = ProtocolUtils.SOCKET_BUF_BYTES
                    sock.receiveBufferSize = ProtocolUtils.SOCKET_BUF_BYTES
                }
                sock.soTimeout = 30_000
                val input = BufferedInputStream(sock.getInputStream(), ProtocolUtils.CHUNK_BYTES)
                val out = BufferedOutputStream(sock.getOutputStream(), ProtocolUtils.CHUNK_BYTES)

                val headerBuf = ByteArrayOutputStream()
                val tmp = ByteArray(8192)
                var headerEnd = -1
                while (headerBuf.size() < 16384) {
                    val n = input.read(tmp)
                    if (n <= 0) return
                    headerBuf.write(tmp, 0, n)
                    val bytes = headerBuf.toByteArray()
                    headerEnd = findHeaderEnd(bytes)
                    if (headerEnd >= 0) break
                }
                if (headerEnd < 0) {
                    sendJson(out, 400, JSONObject().put("error", "Malformed HTTP request"))
                    return
                }

                val allBytes = headerBuf.toByteArray()
                val headerText = String(allBytes, 0, headerEnd, Charsets.UTF_8)
                val bodyStart = headerEnd + 4
                val leftover = if (bodyStart < allBytes.size) allBytes.copyOfRange(bodyStart, allBytes.size) else ByteArray(0)

                val lines = headerText.split("\r\n")
                if (lines.isEmpty()) return
                val reqParts = lines[0].split(" ")
                if (reqParts.size < 2) return
                val method = reqParts[0].uppercase(Locale.ROOT)
                val rawTarget = reqParts[1]

                val headers = HashMap<String, String>()
                for (i in 1 until lines.size) {
                    val colon = lines[i].indexOf(':')
                    if (colon > 0) {
                        headers[lines[i].substring(0, colon).trim().lowercase(Locale.ROOT)] =
                            lines[i].substring(colon + 1).trim()
                    }
                }

                if (method == "OPTIONS") {
                    sendRaw(out, 204, "No Content", "text/plain", ByteArray(0))
                    return
                }

                val qIdx = rawTarget.indexOf('?')
                val route = if (qIdx >= 0) rawTarget.substring(0, qIdx) else rawTarget
                val query = ProtocolUtils.parseQueryParams(if (qIdx >= 0) rawTarget.substring(qIdx + 1) else "")

                if (method == "GET" && (route == "/" || route == "/index.html")) {
                    sendRaw(out, 200, "OK", "text/html; charset=utf-8", buildWebUiHtml().toByteArray(Charsets.UTF_8))
                    return
                }

                val suppliedPin = (headers["x-wq-pin"] ?: query["pin"] ?: "").trim()
                if (suppliedPin != pin) {
                    sendJson(out, 401, JSONObject().put("error", "Invalid PIN"))
                    return
                }

                val root = rootDir

                when {
                    route == "/api/info" && method == "GET" -> {
                        var freeBytes = 0L
                        var totalBytes = 0L
                        try {
                            val stat = StatFs(root.absolutePath)
                            freeBytes = stat.availableBytes
                            totalBytes = stat.totalBytes
                        } catch (_: Exception) {}
                        val info = JSONObject().apply {
                            put("app", "WQGlass")
                            put("version", "2.0")
                            put("device", deviceName())
                            put("platform", "android")
                            put("osVersion", Build.VERSION.RELEASE ?: "")
                            put("ios", Build.VERSION.RELEASE ?: "")
                            put("root", rootLabel)
                            put("freeBytes", freeBytes)
                            put("totalBytes", totalBytes)
                        }
                        sendJson(out, 200, info)
                        log("Connected: ${sock.inetAddress?.hostAddress ?: "Peer"} verified PIN")
                    }

                    route == "/api/list" && method == "GET" -> {
                        val rel = query["path"] ?: ""
                        val target = ProtocolUtils.safeResolvePath(root, rel)
                        if (target == null || !target.isDirectory) {
                            sendJson(out, 404, JSONObject().put("error", "Directory not found"))
                            return
                        }
                        val rawFiles = target.listFiles()
                        if (rawFiles == null) {
                            sendJson(out, 403, JSONObject().put("error", "Grant 'All Files Access' on Android to read this folder"))
                            return
                        }
                        val children = rawFiles
                            .filter { !it.name.startsWith(".") }
                            .sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase(Locale.ROOT) })

                        val arr = JSONArray()
                        for (f in children) {
                            val childRel = if (rel.isEmpty()) f.name else "${rel.trimEnd('/')}/${f.name}"
                            arr.put(
                                JSONObject().apply {
                                    put("name", f.name)
                                    put("path", childRel)
                                    put("isDir", f.isDirectory)
                                    put("size", if (f.isDirectory) 0L else f.length())
                                    put("mtime", f.lastModified() / 1000L)
                                }
                            )
                        }
                        sendJson(out, 200, JSONObject().put("path", rel).put("items", arr))
                    }

                    route == "/api/download" && (method == "GET" || method == "HEAD") -> {
                        val rel = query["path"] ?: ""
                        val target = ProtocolUtils.safeResolvePath(root, rel)
                        if (target == null || !target.isFile || !target.canRead()) {
                            sendJson(out, 404, JSONObject().put("error", "File not found or unreadable (check All Files Access)"))
                            return
                        }
                        val safeName = target.name.replace("\"", "_")
                        val length = target.length()
                        val hdr = "HTTP/1.1 200 OK\r\n" +
                            "Content-Type: application/octet-stream\r\n" +
                            "Content-Length: $length\r\n" +
                            "Content-Disposition: attachment; filename=\"$safeName\"\r\n" +
                            "Access-Control-Allow-Origin: *\r\n" +
                            "Connection: close\r\n\r\n"
                        out.write(hdr.toByteArray(Charsets.UTF_8))
                        out.flush()
                        if (method == "HEAD") return

                        sock.soTimeout = 0
                        val buf = ByteArray(ProtocolUtils.CHUNK_BYTES)
                        BufferedInputStream(FileInputStream(target), ProtocolUtils.CHUNK_BYTES).use { fis ->
                            while (true) {
                                val r = fis.read(buf)
                                if (r <= 0) break
                                out.write(buf, 0, r)
                            }
                        }
                        out.flush()
                        log("↑ Sent to peer: ${target.name} (${ProtocolUtils.formatBytes(length)})")
                    }

                    route == "/api/upload" && method == "POST" -> {
                        val relDir = query["path"] ?: ""
                        val rawName = (query["name"] ?: "").replace('\\', '/')
                        val cleanName = rawName.substringAfterLast('/')
                        if (cleanName.isBlank() || cleanName == "." || cleanName == "..") {
                            sendJson(out, 400, JSONObject().put("error", "Missing filename"))
                            return
                        }
                        val dirTarget = ProtocolUtils.safeResolvePath(root, relDir)
                        if (dirTarget == null) {
                            sendJson(out, 403, JSONObject().put("error", "Forbidden path"))
                            return
                        }
                        dirTarget.mkdirs()

                        val contentLength = headers["content-length"]?.toLongOrNull()
                        if (contentLength == null || contentLength < 0L) {
                            sendJson(out, 411, JSONObject().put("error", "Content-Length required"))
                            return
                        }

                        sock.soTimeout = 0
                        val dst = ProtocolUtils.uniqueTargetFile(dirTarget, cleanName)
                        var written = 0L
                        BufferedOutputStream(FileOutputStream(dst), ProtocolUtils.CHUNK_BYTES).use { fos ->
                            if (leftover.isNotEmpty() && contentLength > 0L) {
                                val toWrite = minOf(leftover.size.toLong(), contentLength).toInt()
                                fos.write(leftover, 0, toWrite)
                                written += toWrite
                            }
                            val buf = ByteArray(ProtocolUtils.CHUNK_BYTES)
                            while (written < contentLength) {
                                val want = minOf(buf.size.toLong(), contentLength - written).toInt()
                                val r = input.read(buf, 0, want)
                                if (r <= 0) break
                                fos.write(buf, 0, r)
                                written += r
                            }
                        }

                        if (written < contentLength) {
                            runCatching { dst.delete() }
                            sendJson(out, 400, JSONObject().put("error", "Incomplete upload"))
                            return
                        }

                        sendJson(out, 200, JSONObject().put("ok", true).put("name", dst.name).put("size", written))
                        log("↓ Received from peer: ${dst.name} (${ProtocolUtils.formatBytes(written)})")
                    }

                    route == "/api/mkdir" && method == "POST" -> {
                        val rel = query["path"] ?: ""
                        val target = ProtocolUtils.safeResolvePath(root, rel)
                        if (target == null) {
                            sendJson(out, 403, JSONObject().put("error", "Invalid path"))
                            return
                        }
                        target.mkdirs()
                        sendJson(out, 200, JSONObject().put("ok", true))
                        log("+ Created folder: $rel")
                    }

                    route == "/api/delete" && method == "POST" -> {
                        val rel = query["path"] ?: ""
                        val target = ProtocolUtils.safeResolvePath(root, rel)
                        if (target == null || target.canonicalFile == root.canonicalFile) {
                            sendJson(out, 403, JSONObject().put("error", "Cannot delete root"))
                            return
                        }
                        if (target.deleteRecursively()) {
                            sendJson(out, 200, JSONObject().put("ok", true))
                            log("🗑 Deleted: $rel")
                        } else {
                            sendJson(out, 500, JSONObject().put("error", "Delete failed"))
                        }
                    }

                    route == "/api/rename" && method == "POST" -> {
                        val rel = query["path"] ?: ""
                        val newName = (query["to"] ?: "").trim()
                        val src = ProtocolUtils.safeResolvePath(root, rel)
                        if (src == null || newName.isEmpty() || newName.contains('/') || newName.contains('\\') || newName == "." || newName == "..") {
                            sendJson(out, 400, JSONObject().put("error", "Invalid rename parameters"))
                            return
                        }
                        val dst = File(src.parentFile ?: root, newName)
                        if (src.renameTo(dst)) {
                            sendJson(out, 200, JSONObject().put("ok", true))
                            log("✎ Renamed to: $newName")
                        } else {
                            sendJson(out, 500, JSONObject().put("error", "Rename failed"))
                        }
                    }

                    route == "/api/text" && method == "POST" -> {
                        val len = (headers["content-length"]?.toLongOrNull() ?: 0L).coerceIn(0L, 256L * 1024L).toInt()
                        val buf = ByteArrayOutputStream()
                        if (leftover.isNotEmpty() && len > 0) {
                            buf.write(leftover, 0, minOf(leftover.size, len))
                        }
                        val tbuf = ByteArray(8192)
                        while (buf.size() < len) {
                            val want = minOf(tbuf.size, len - buf.size())
                            val r = input.read(tbuf, 0, want)
                            if (r <= 0) break
                            buf.write(tbuf, 0, r)
                        }
                        val text = buf.toString("UTF-8")
                        sendJson(out, 200, JSONObject().put("ok", true))
                        if (text.isNotBlank()) {
                            _receivedText.value = text
                            log("📋 Received text/link (${text.length} chars)")
                        }
                    }

                    else -> sendJson(out, 404, JSONObject().put("error", "Not found"))
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun findHeaderEnd(bytes: ByteArray): Int {
        for (i in 0..bytes.size - 4) {
            if (bytes[i] == '\r'.code.toByte() &&
                bytes[i + 1] == '\n'.code.toByte() &&
                bytes[i + 2] == '\r'.code.toByte() &&
                bytes[i + 3] == '\n'.code.toByte()
            ) return i
        }
        return -1
    }

    private fun sendJson(out: OutputStream, status: Int, obj: JSONObject) {
        val body = obj.toString().toByteArray(Charsets.UTF_8)
        val reason = when (status) {
            200 -> "OK"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            403 -> "Forbidden"
            404 -> "Not Found"
            411 -> "Length Required"
            else -> "Error"
        }
        sendRaw(out, status, reason, "application/json; charset=utf-8", body)
    }

    private fun sendRaw(out: OutputStream, status: Int, reason: String, contentType: String, body: ByteArray) {
        val hdr = "HTTP/1.1 $status $reason\r\n" +
            "Content-Type: $contentType\r\n" +
            "Content-Length: ${body.size}\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Access-Control-Allow-Headers: X-WQ-PIN, Content-Type\r\n" +
            "Connection: close\r\n\r\n"
        out.write(hdr.toByteArray(Charsets.UTF_8))
        if (body.isNotEmpty()) out.write(body)
        out.flush()
    }

    private fun buildWebUiHtml(): String {
        val dev = deviceName().replace("<", "&lt;").replace(">", "&gt;")
        return """
            <!doctype html><html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>WQGlass Transfer — $dev</title>
            <style>
            body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#070d19;color:#e2e8f0;margin:0;padding:20px;}
            .wrap{max-width:880px;margin:0 auto;}
            .card{background:#101b30;border:1px solid #223556;border-radius:16px;padding:18px;margin-bottom:16px;}
            h1{margin:0 0 6px;font-size:21px;color:#fff;} .sub{color:#94a3b8;font-size:13px;}
            input,button{font-size:14px;border-radius:10px;border:1px solid #334155;padding:9px 12px;}
            input{background:#091020;color:#fff;} button{background:#2563eb;color:#fff;border:none;cursor:pointer;font-weight:600;}
            button.sec{background:#17243d;border:1px solid #223556;}
            .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:12px;}
            table{width:100%;border-collapse:collapse;margin-top:10px;} th,td{text-align:left;padding:10px 8px;border-bottom:1px solid #1e293b;font-size:14px;}
            a{color:#38bdf8;text-decoration:none;} .sz{color:#94a3b8;font-variant-numeric:tabular-nums;}
            .prog{height:8px;background:#13213b;border-radius:8px;overflow:hidden;margin-top:10px;display:none;} .prog>div{height:100%;background:linear-gradient(90deg,#38bdf8,#6366f1);width:0%;}
            </style></head><body><div class="wrap">
            <div class="card"><h1>🤖 WQGlass Transfer — $dev (Android)</h1>
            <div class="sub" id="info">Enter the PIN shown on your Android device to browse, download, or upload files.</div>
            <div class="row"><input id="pin" placeholder="4-digit PIN" maxlength="8" style="width:130px;">
            <button onclick="connect()">Connect</button>
            <button class="sec" onclick="goUp()">↑ Up</button>
            <button class="sec" onclick="makeFolder()">+ New Folder</button>
            <label style="background:#2563eb;padding:9px 14px;border-radius:10px;cursor:pointer;font-weight:600;">⬆ Send Files<input type="file" multiple style="display:none" onchange="uploadFiles(this.files)"></label>
            </div><div class="prog" id="prog"><div id="pfill"></div></div><div class="sub" id="status" style="margin-top:8px;"></div></div>
            <div class="card"><table><thead><tr><th>Name</th><th>Size</th><th>Action</th></tr></thead><tbody id="rows"></tbody></table></div>
            </div><script>
            let pin='',curPath='';
            function fmt(b){if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(2)+' MB';return (b/1073741824).toFixed(2)+' GB';}
            async function connect(){pin=document.getElementById('pin').value.trim();const r=await fetch('/api/info',{headers:{'X-WQ-PIN':pin}});if(!r.ok){document.getElementById('status').innerText='Invalid PIN';return;}const j=await r.json();document.getElementById('info').innerText=j.device+' (Android '+(j.osVersion||'')+') · '+j.root+' · Free: '+fmt(j.freeBytes);refresh();}
            async function refresh(){if(!pin)return;const r=await fetch('/api/list?path='+encodeURIComponent(curPath),{headers:{'X-WQ-PIN':pin}});if(!r.ok){const e=await r.json().catch(()=>({}));document.getElementById('status').innerText=e.error||'Auth failed';return;}const j=await r.json();const tb=document.getElementById('rows');tb.innerHTML='';for(const it of j.items){const tr=document.createElement('tr');const n=document.createElement('td');if(it.isDir){const a=document.createElement('a');a.href='#';a.textContent='📁 '+it.name;a.onclick=(e)=>{e.preventDefault();curPath=it.path;refresh();};n.appendChild(a);}else{n.textContent='📄 '+it.name;}const s=document.createElement('td');s.className='sz';s.textContent=it.isDir?'Folder':fmt(it.size);const ac=document.createElement('td');if(!it.isDir){const dl=document.createElement('a');dl.href='/api/download?path='+encodeURIComponent(it.path)+'&pin='+encodeURIComponent(pin);dl.textContent='Download';ac.appendChild(dl);}tr.appendChild(n);tr.appendChild(s);tr.appendChild(ac);tb.appendChild(tr);}document.getElementById('status').innerText='Path: /'+curPath+' ('+j.items.length+' items)';}
            function goUp(){if(!curPath)return;const p=curPath.split('/');p.pop();curPath=p.join('/');refresh();}
            async function makeFolder(){const n=prompt('New folder name:');if(!n||!pin)return;const p=curPath?(curPath+'/'+n):n;await fetch('/api/mkdir?path='+encodeURIComponent(p),{method:'POST',headers:{'X-WQ-PIN':pin}});refresh();}
            async function uploadFiles(files){if(!pin||!files.length)return;const pb=document.getElementById('prog'),pf=document.getElementById('pfill');pb.style.display='block';for(let i=0;i<files.length;i++){const f=files[i];document.getElementById('status').innerText='Sending '+f.name+' ('+(i+1)+'/'+files.length+')…';await new Promise((res,rej)=>{const xhr=new XMLHttpRequest();xhr.open('POST','/api/upload?path='+encodeURIComponent(curPath)+'&name='+encodeURIComponent(f.name));xhr.setRequestHeader('X-WQ-PIN',pin);xhr.upload.onprogress=(e)=>{if(e.lengthComputable)pf.style.width=(100*e.loaded/e.total).toFixed(1)+'%';};xhr.onload=()=>res();xhr.onerror=()=>rej();xhr.send(f);});}pb.style.display='none';document.getElementById('status').innerText='Upload complete!';refresh();}
            const qp=new URLSearchParams(location.search).get('pin');if(qp){document.getElementById('pin').value=qp;connect();}
            </script></body></html>
        """.trimIndent()
    }

    companion object {
        private val rng = SecureRandom()

        fun generateRandomPin(): String = (1000 + rng.nextInt(9000)).toString()

        fun detectLanIpv4(): String {
            var fallback = ""
            try {
                val ifaces = NetworkInterface.getNetworkInterfaces()
                while (ifaces != null && ifaces.hasMoreElements()) {
                    val ni = ifaces.nextElement()
                    if (!ni.isUp || ni.isLoopback) continue
                    val name = ni.name.lowercase(Locale.ROOT)
                    val addrs = ni.inetAddresses
                    while (addrs.hasMoreElements()) {
                        val a = addrs.nextElement()
                        if (a is Inet4Address && !a.isLoopbackAddress) {
                            val ip = a.hostAddress ?: continue
                            if (ip.startsWith("169.254.")) continue
                            if (name.startsWith("wlan") || name.startsWith("wifi") || name.startsWith("eth")) {
                                return ip
                            }
                            if (fallback.isEmpty()) fallback = ip
                        }
                    }
                }
            } catch (_: Exception) {}
            return fallback
        }
    }
}
