package com.wqglass.transfer

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL
import kotlin.coroutines.coroutineContext

class TransferClient(endpoint: String, pin: String) {
    @Volatile
    var baseUrl: String
        private set
    private val host: String
    private val initialPort: Int
    private val cleanPin: String = pin.trim()

    init {
        var clean = endpoint.trim().trimEnd('/')
        if (!clean.startsWith("http://", ignoreCase = true) &&
            !clean.startsWith("https://", ignoreCase = true)
        ) {
            clean = "http://$clean"
        }
        val uri = runCatching { URI(clean) }.getOrNull()
        host = uri?.host?.ifBlank { null } ?: clean.removePrefix("http://").removePrefix("https://").substringBefore(':')
        initialPort = uri?.port?.takeIf { it in 1..65535 } ?: ProtocolUtils.BASE_HTTP_PORT
        baseUrl = "http://$host:$initialPort"
    }

    val resolvedEndpoint: String
        get() = baseUrl.removePrefix("http://").removePrefix("https://")

    private fun openConnectionForBase(base: String, method: String, relativeUrl: String, timeoutMs: Int = 8000): HttpURLConnection {
        val conn = URL(base + relativeUrl).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = timeoutMs
        conn.readTimeout = 60000
        conn.useCaches = false
        conn.setRequestProperty("X-WQ-PIN", cleanPin)
        return conn
    }

    private fun openConnection(method: String, relativeUrl: String): HttpURLConnection =
        openConnectionForBase(baseUrl, method, relativeUrl)

    suspend fun getInfo(): RemoteInfo = withContext(Dispatchers.IO) {
        val candidatePorts = LinkedHashSet<Int>().apply {
            add(initialPort)
            for (p in ProtocolUtils.BASE_HTTP_PORT until ProtocolUtils.BASE_HTTP_PORT + 4) {
                add(p)
            }
        }.toList()

        val localIfaces = TransferServer.getActiveInterfacesSummary()
        AppLogger.info("Client", "Connecting to $host:$initialPort (local ifaces: $localIfaces)")

        var lastError: Exception? = null
        for ((index, port) in candidatePorts.withIndex()) {
            val candidateBase = "http://$host:$port"
            val timeoutMs = if (index == 0) 5000 else 2500
            val conn = openConnectionForBase(candidateBase, "GET", "/api/info", timeoutMs)
            try {
                val code = conn.responseCode
                if (code == HttpURLConnection.HTTP_UNAUTHORIZED) {
                    baseUrl = candidateBase
                    throw IOException("Incorrect PIN for $host:$port. Check the 4-digit PIN shown on the other phone/PC.")
                }
                if (code !in 200..299) {
                    throw IOException("Server at $host:$port returned HTTP $code")
                }
                val body = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                val j = JSONObject(body)
                baseUrl = candidateBase
                return@withContext RemoteInfo(
                    device = j.optString("device", "Device"),
                    platform = j.optString("platform", "ios"),
                    osVersion = j.optString("osVersion", ""),
                    iosVersion = j.optString("ios", ""),
                    root = j.optString("root", "Downloads"),
                    freeBytes = j.optLong("freeBytes", 0L),
                    totalBytes = j.optLong("totalBytes", 0L)
                )
            } catch (e: IOException) {
                if (e.message?.startsWith("Incorrect PIN") == true) {
                    throw e
                }
                lastError = e
            } catch (e: Exception) {
                lastError = e
            } finally {
                conn.disconnect()
            }
        }

        val err = lastError ?: IOException("Failed to connect to $host:$initialPort")
        val msg = err.message.orEmpty()
        val detailedMessage = when {
            err is ConnectException && msg.contains("ECONNREFUSED", ignoreCase = true) || msg.contains("Connection refused", ignoreCase = true) ->
                "Connection refused by $host:$initialPort — make sure WQ Glass is open on the other phone/PC and 'Share iPhone' / 'Start Sharing' server is running (keep the screen unlocked)."
            err is SocketTimeoutException || err is NoRouteToHostException || err is ConnectException ->
                "Could not reach $host:$initialPort (local IPs: $localIfaces). Ensure both phones are on the same Wi-Fi and 'Share iPhone' / 'Share Device' is running. If your Wi-Fi router blocks device-to-device traffic (AP Isolation), turn on Mobile Hotspot on one phone and connect the other phone directly to it."
            else ->
                "${err.message ?: "Connect failed"} (local IPs: $localIfaces)"
        }
        throw IOException(detailedMessage, err)
    }

    suspend fun list(remotePath: String): List<RemoteFileItem> = withContext(Dispatchers.IO) {
        val q = ProtocolUtils.urlEncode(remotePath)
        val conn = openConnection("GET", "/api/list?path=$q")
        try {
            val code = conn.responseCode
            if (code !in 200..299) throw IOException("List failed (HTTP $code)")
            val body = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val j = JSONObject(body)
            val arr = j.optJSONArray("items") ?: return@withContext emptyList()
            val items = ArrayList<RemoteFileItem>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                items.add(
                    RemoteFileItem(
                        name = o.optString("name", ""),
                        path = o.optString("path", ""),
                        isDir = o.optBoolean("isDir", false),
                        size = o.optLong("size", 0L),
                        mtime = o.optLong("mtime", 0L)
                    )
                )
            }
            items
        } finally {
            conn.disconnect()
        }
    }

    suspend fun createFolder(remotePath: String) = simplePost("/api/mkdir?path=${ProtocolUtils.urlEncode(remotePath)}")

    suspend fun delete(remotePath: String) = simplePost("/api/delete?path=${ProtocolUtils.urlEncode(remotePath)}")

    suspend fun rename(remotePath: String, newName: String) =
        simplePost("/api/rename?path=${ProtocolUtils.urlEncode(remotePath)}&to=${ProtocolUtils.urlEncode(newName)}")

    suspend fun sendText(text: String) = withContext(Dispatchers.IO) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        val conn = openConnection("POST", "/api/text")
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "text/plain; charset=utf-8")
        conn.setFixedLengthStreamingMode(bytes.size)
        try {
            conn.outputStream.use { it.write(bytes) }
            val code = conn.responseCode
            if (code !in 200..299) throw IOException("Send text failed (HTTP $code)")
        } finally {
            conn.disconnect()
        }
    }

    private suspend fun simplePost(relativeUrl: String) = withContext(Dispatchers.IO) {
        val conn = openConnection("POST", relativeUrl)
        conn.doOutput = true
        conn.setFixedLengthStreamingMode(0)
        try {
            conn.outputStream.close()
            val code = conn.responseCode
            if (code !in 200..299) throw IOException("Operation failed (HTTP $code)")
        } finally {
            conn.disconnect()
        }
    }

    suspend fun collectRemoteDownloads(
        items: List<RemoteFileItem>,
        baseLocalDir: File
    ): List<Triple<String, File, String>> {
        val jobs = ArrayList<Triple<String, File, String>>()
        suspend fun walk(item: RemoteFileItem, localDir: File) {
            coroutineContext.ensureActive()
            if (item.isDir) {
                val sub = File(localDir, item.name).apply { mkdirs() }
                for (child in list(item.path)) {
                    walk(child, sub)
                }
            } else {
                jobs.add(Triple(item.path, localDir, item.name))
            }
        }
        for (it in items) walk(it, baseLocalDir)
        return jobs
    }

    suspend fun downloadFile(
        remotePath: String,
        destinationDir: File,
        fileName: String,
        fileIndex: Int,
        fileCount: Int,
        onProgress: (TransferProgress) -> Unit
    ): Pair<File, Long> = withContext(Dispatchers.IO) {
        destinationDir.mkdirs()
        val destFile = ProtocolUtils.uniqueTargetFile(destinationDir, fileName)
        val q = ProtocolUtils.urlEncode(remotePath)
        val conn = openConnection("GET", "/api/download?path=$q")
        conn.readTimeout = 0
        try {
            val code = conn.responseCode
            if (code !in 200..299) throw IOException("Download failed (HTTP $code)")
            val total = conn.contentLengthLong
            val buf = ByteArray(ProtocolUtils.CHUNK_BYTES)
            val startNs = System.nanoTime()
            var lastReportMs = 0L
            var received = 0L

            BufferedInputStream(conn.inputStream, ProtocolUtils.CHUNK_BYTES).use { input ->
                BufferedOutputStream(FileOutputStream(destFile), ProtocolUtils.CHUNK_BYTES).use { out ->
                    while (true) {
                        coroutineContext.ensureActive()
                        val read = input.read(buf)
                        if (read <= 0) break
                        out.write(buf, 0, read)
                        received += read
                        val elapsedMs = (System.nanoTime() - startNs) / 1_000_000L
                        if (elapsedMs - lastReportMs >= 80L || (total > 0L && received >= total)) {
                            lastReportMs = elapsedMs
                            val bps = if (elapsedMs > 0L) received * 1000.0 / elapsedMs else 0.0
                            onProgress(
                                TransferProgress(
                                    verb = "Downloading",
                                    fileName = fileName,
                                    transferredBytes = received,
                                    totalBytes = if (total > 0L) total else received,
                                    bytesPerSec = bps,
                                    fileIndex = fileIndex,
                                    fileCount = fileCount
                                )
                            )
                        }
                    }
                }
            }
            destFile to received
        } catch (e: Exception) {
            runCatching { destFile.delete() }
            throw e
        } finally {
            conn.disconnect()
        }
    }

    suspend fun uploadUri(
        context: Context,
        uri: Uri,
        remoteDir: String,
        overrideName: String? = null,
        fileIndex: Int,
        fileCount: Int,
        onProgress: (TransferProgress) -> Unit
    ): Pair<String, Long> = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        var displayName = overrideName?.takeIf { it.isNotBlank() } ?: "file_${System.currentTimeMillis()}.bin"
        var totalLength = -1L

        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (overrideName.isNullOrBlank() && nameIdx >= 0) {
                            cursor.getString(nameIdx)?.takeIf { it.isNotBlank() }?.let { displayName = it }
                        }
                        if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
                            totalLength = cursor.getLong(sizeIdx)
                        }
                    }
                }
        }

        if (totalLength < 0L) {
            runCatching {
                resolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                    if (afd.length >= 0L) totalLength = afd.length
                }
            }
        }

        // Fallback for content providers that don't expose Content-Length (Gallery, Drive, WhatsApp, etc.):
        // spool to a temporary cache file so we ALWAYS know the exact byte length and never fail!
        var spooledTemp: File? = null
        try {
            if (totalLength < 0L) {
                val tmp = File.createTempFile("wq_up_", ".tmp", context.cacheDir)
                spooledTemp = tmp
                val buf = ByteArray(ProtocolUtils.CHUNK_BYTES)
                var copied = 0L
                resolver.openInputStream(uri)?.use { src ->
                    BufferedOutputStream(FileOutputStream(tmp), ProtocolUtils.CHUNK_BYTES).use { dst ->
                        while (true) {
                            coroutineContext.ensureActive()
                            val n = src.read(buf)
                            if (n <= 0) break
                            dst.write(buf, 0, n)
                            copied += n
                        }
                    }
                } ?: throw IOException("Cannot read selected file $displayName")
                totalLength = copied
            }

            val qDir = ProtocolUtils.urlEncode(remoteDir)
            val qName = ProtocolUtils.urlEncode(displayName)
            val conn = openConnection("POST", "/api/upload?path=$qDir&name=$qName")
            conn.doOutput = true
            conn.readTimeout = 0
            conn.setRequestProperty("Content-Type", "application/octet-stream")
            conn.setFixedLengthStreamingMode(totalLength)

            try {
                val buf = ByteArray(ProtocolUtils.CHUNK_BYTES)
                val startNs = System.nanoTime()
                var lastReportMs = 0L
                var sent = 0L

                val sourceStream = if (spooledTemp != null) {
                    BufferedInputStream(FileInputStream(spooledTemp), ProtocolUtils.CHUNK_BYTES)
                } else {
                    BufferedInputStream(
                        resolver.openInputStream(uri) ?: throw IOException("Cannot read $displayName"),
                        ProtocolUtils.CHUNK_BYTES
                    )
                }

                sourceStream.use { input ->
                    BufferedOutputStream(conn.outputStream, ProtocolUtils.CHUNK_BYTES).use { out ->
                        while (true) {
                            coroutineContext.ensureActive()
                            val read = input.read(buf)
                            if (read <= 0) break
                            out.write(buf, 0, read)
                            sent += read
                            val elapsedMs = (System.nanoTime() - startNs) / 1_000_000L
                            if (elapsedMs - lastReportMs >= 80L || sent >= totalLength) {
                                lastReportMs = elapsedMs
                                val bps = if (elapsedMs > 0L) sent * 1000.0 / elapsedMs else 0.0
                                onProgress(
                                    TransferProgress(
                                        verb = "Uploading",
                                        fileName = displayName,
                                        transferredBytes = sent,
                                        totalBytes = totalLength,
                                        bytesPerSec = bps,
                                        fileIndex = fileIndex,
                                        fileCount = fileCount
                                    )
                                )
                            }
                        }
                        out.flush()
                    }
                }

                val code = conn.responseCode
                if (code !in 200..299) throw IOException("Upload failed (HTTP $code)")
                displayName to sent
            } finally {
                conn.disconnect()
            }
        } finally {
            runCatching { spooledTemp?.delete() }
        }
    }

    suspend fun collectTreeUploads(
        context: Context,
        treeUri: Uri,
        baseRemoteDir: String
    ): List<Triple<Uri, String, String>> = withContext(Dispatchers.IO) {
        val rootDoc = DocumentFile.fromTreeUri(context, treeUri) ?: return@withContext emptyList()
        val folderName = rootDoc.name ?: "Folder"
        val startRemote = if (baseRemoteDir.isEmpty()) folderName else "$baseRemoteDir/$folderName"
        val jobs = ArrayList<Triple<Uri, String, String>>()

        fun walk(doc: DocumentFile, remoteDir: String) {
            for (child in doc.listFiles()) {
                val cname = child.name ?: continue
                if (child.isDirectory) {
                    walk(child, "$remoteDir/$cname")
                } else if (child.isFile) {
                    jobs.add(Triple(child.uri, remoteDir, cname))
                }
            }
        }
        walk(rootDoc, startRemote)
        jobs
    }
}
