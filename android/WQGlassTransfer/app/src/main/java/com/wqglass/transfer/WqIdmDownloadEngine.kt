package com.wqglass.transfer

import android.os.Environment
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

enum class DownloadStatus {
    QUEUED,
    DOWNLOADING,
    PAUSED,
    COMPLETED,
    FAILED,
    CANCELLED
}

data class DownloadTaskItem(
    val id: String = UUID.randomUUID().toString(),
    val url: String,
    val fileName: String,
    val destinationPath: String,
    val partsCount: Int = 8,
    val totalBytes: Long = 0L,
    val downloadedBytes: Long = 0L,
    val speedBytesPerSec: Double = 0.0,
    val status: DownloadStatus = DownloadStatus.QUEUED,
    val isHls: Boolean = false,
    val errorText: String? = null,
    val createdAt: String = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
) {
    val progressFraction: Float
        get() = if (totalBytes > 0L) (downloadedBytes.toDouble() / totalBytes.toDouble()).toFloat().coerceIn(0f, 1f) else 0f

    val etaText: String
        get() {
            if (speedBytesPerSec < 100.0 || totalBytes <= downloadedBytes) return "--"
            return ProtocolUtils.formatEta((totalBytes - downloadedBytes) / speedBytesPerSec)
        }
}

/**
 * Multi-Part (1–16 parallel Range connections) IDM Download Engine + HLS (.m3u8) segment fetcher.
 */
object WqIdmDownloadEngine {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val activeJobs = ConcurrentHashMap<String, Job>()

    private val _tasks = MutableStateFlow<List<DownloadTaskItem>>(emptyList())
    val tasks: StateFlow<List<DownloadTaskItem>> = _tasks.asStateFlow()

    private val _defaultParts = MutableStateFlow(8)
    val defaultParts: StateFlow<Int> = _defaultParts.asStateFlow()

    fun setDefaultParts(parts: Int) {
        _defaultParts.value = parts.coerceIn(1, 16)
    }

    fun defaultDownloadsDir(): File {
        val dl = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "WQGlass")
        dl.mkdirs()
        return dl
    }

    fun enqueueDownload(
        rawUrl: String,
        customFileName: String? = null,
        partsCount: Int = _defaultParts.value,
        userAgent: String? = null
    ): DownloadTaskItem {
        val cleanUrl = rawUrl.trim()
        val guessedName = customFileName?.trim()?.takeIf { it.isNotEmpty() } ?: guessFileName(cleanUrl)
        val isHls = cleanUrl.contains(".m3u8", ignoreCase = true) || guessedName.endsWith(".m3u8", ignoreCase = true)
        val finalName = if (isHls && guessedName.endsWith(".m3u8", ignoreCase = true)) {
            guessedName.removeSuffix(".m3u8") + ".ts"
        } else {
            guessedName
        }
        val destFile = ProtocolUtils.uniqueTargetFile(defaultDownloadsDir(), finalName)
        val item = DownloadTaskItem(
            url = cleanUrl,
            fileName = destFile.name,
            destinationPath = destFile.absolutePath,
            partsCount = if (isHls) 4 else partsCount.coerceIn(1, 16),
            isHls = isHls,
            status = DownloadStatus.QUEUED
        )
        _tasks.value = listOf(item) + _tasks.value
        AppLogger.info("IDM", "Enqueued download: ${item.fileName} (${item.partsCount} parts) from $cleanUrl")
        startOrResumeTask(item.id, userAgent)
        return item
    }

    fun pauseTask(taskId: String) {
        scope.launch {
            activeJobs.remove(taskId)?.cancelAndJoin()
            updateTask(taskId) {
                if (it.status == DownloadStatus.DOWNLOADING || it.status == DownloadStatus.QUEUED) {
                    it.copy(status = DownloadStatus.PAUSED, speedBytesPerSec = 0.0)
                } else it
            }
            AppLogger.info("IDM", "Paused task $taskId")
        }
    }

    fun resumeTask(taskId: String) {
        startOrResumeTask(taskId, null)
    }

    fun cancelAndRemoveTask(taskId: String, deleteFile: Boolean = false) {
        scope.launch {
            activeJobs.remove(taskId)?.cancelAndJoin()
            val target = _tasks.value.firstOrNull { it.id == taskId }
            _tasks.value = _tasks.value.filterNot { it.id == taskId }
            if (deleteFile && target != null) {
                runCatching { File(target.destinationPath).delete() }
            }
            if (target != null) {
                cleanPartFiles(File(target.destinationPath), target.partsCount)
            }
        }
    }

    fun clearCompleted() {
        _tasks.value = _tasks.value.filterNot { it.status == DownloadStatus.COMPLETED }
    }

    private fun startOrResumeTask(taskId: String, userAgent: String?) {
        val current = _tasks.value.firstOrNull { it.id == taskId } ?: return
        if (activeJobs.containsKey(taskId)) return

        val job = scope.launch {
            updateTask(taskId) { it.copy(status = DownloadStatus.DOWNLOADING, errorText = null) }
            try {
                if (current.isHls) {
                    runHlsDownload(current, userAgent)
                } else {
                    runHttpMultiPartDownload(current, userAgent)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                updateTask(taskId) {
                    if (it.status == DownloadStatus.DOWNLOADING) it.copy(status = DownloadStatus.PAUSED, speedBytesPerSec = 0.0)
                    else it
                }
            } catch (e: Exception) {
                AppLogger.error("IDM", "Download failed for ${current.fileName}", e)
                updateTask(taskId) {
                    it.copy(status = DownloadStatus.FAILED, speedBytesPerSec = 0.0, errorText = e.message ?: "Download failed")
                }
            } finally {
                activeJobs.remove(taskId)
            }
        }
        activeJobs[taskId] = job
    }

    private suspend fun runHttpMultiPartDownload(task: DownloadTaskItem, userAgent: String?) = withContext(Dispatchers.IO) {
        val ua = userAgent ?: "Mozilla/5.0 (Linux; Android 15; WQGlass/4.0) AppleWebKit/537.36 Chrome/131.0.0.0 Mobile Safari/537.36"
        var totalSize = -1L
        var acceptsRanges = false

        // Probe headers via HEAD or Range 0-0 GET
        try {
            val probeConn = (URL(task.url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 12_000
                readTimeout = 15_000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", ua)
                setRequestProperty("Range", "bytes=0-0")
            }
            val code = probeConn.responseCode
            val contentRange = probeConn.getHeaderField("Content-Range") ?: ""
            val acceptHdr = probeConn.getHeaderField("Accept-Ranges") ?: ""
            if (code == HttpURLConnection.HTTP_PARTIAL && contentRange.contains('/')) {
                acceptsRanges = true
                totalSize = contentRange.substringAfterLast('/').trim().toLongOrNull() ?: -1L
            } else if (code in 200..299) {
                totalSize = probeConn.contentLengthLong
                acceptsRanges = acceptHdr.contains("bytes", ignoreCase = true) && totalSize > 0
            }
            probeConn.inputStream?.close()
            probeConn.disconnect()
        } catch (_: Exception) {
        }

        val destFile = File(task.destinationPath)
        destFile.parentFile?.mkdirs()

        val actualParts = if (acceptsRanges && totalSize > 512 * 1024L) task.partsCount.coerceIn(1, 16) else 1
        updateTask(task.id) { it.copy(totalBytes = totalSize.coerceAtLeast(0L), partsCount = actualParts) }

        if (actualParts == 1) {
            val existing = if (destFile.exists() && acceptsRanges) destFile.length() else 0L
            val conn = (URL(task.url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 15_000
                readTimeout = 30_000
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", ua)
                if (existing > 0L) setRequestProperty("Range", "bytes=$existing-")
            }
            val code = conn.responseCode
            if (code !in 200..299) throw IllegalStateException("HTTP $code from server")
            val append = code == HttpURLConnection.HTTP_PARTIAL && existing > 0L
            val len = if (totalSize > 0L) totalSize else (conn.contentLengthLong.takeIf { it > 0L }?.plus(if (append) existing else 0L) ?: 0L)
            var downloaded = if (append) existing else 0L
            var lastTickNs = System.nanoTime()
            var lastTickBytes = downloaded

            FileOutputStream(destFile, append).use { fos ->
                BufferedInputStream(conn.inputStream, 256 * 1024).use { bis ->
                    val buf = ByteArray(128 * 1024)
                    while (isActive) {
                        val r = bis.read(buf)
                        if (r <= 0) break
                        fos.write(buf, 0, r)
                        downloaded += r
                        val nowNs = System.nanoTime()
                        if (nowNs - lastTickNs >= 250_000_000L) {
                            val sec = (nowNs - lastTickNs) / 1e9
                            val bps = (downloaded - lastTickBytes) / sec.coerceAtLeast(0.01)
                            lastTickNs = nowNs
                            lastTickBytes = downloaded
                            updateTask(task.id) { it.copy(downloadedBytes = downloaded, totalBytes = len.coerceAtLeast(downloaded), speedBytesPerSec = bps) }
                        }
                    }
                }
            }
            updateTask(task.id) {
                it.copy(
                    status = DownloadStatus.COMPLETED,
                    downloadedBytes = destFile.length(),
                    totalBytes = destFile.length(),
                    speedBytesPerSec = 0.0
                )
            }
            AppLogger.info("IDM", "Completed single-stream download: ${destFile.name} (${ProtocolUtils.formatBytes(destFile.length())})")
            return@withContext
        }

        // Multi-part parallel range download using RandomAccessFile
        RandomAccessFile(destFile, "rw").use { raf ->
            if (raf.length() != totalSize) raf.setLength(totalSize)
        }

        val chunkSize = totalSize / actualParts
        val totalProgress = AtomicLong(0L)
        val partFiles = (0 until actualParts).map { idx -> File(destFile.parentFile, ".${destFile.name}.part$idx") }

        // Restore already downloaded part offsets
        val partOffsets = LongArray(actualParts) { idx ->
            val pf = partFiles[idx]
            if (pf.exists()) pf.readText().trim().toLongOrNull() ?: 0L else 0L
        }
        totalProgress.set(partOffsets.sum())

        val monitorJob = launch {
            var lastNs = System.nanoTime()
            var lastBytes = totalProgress.get()
            while (isActive) {
                kotlinx.coroutines.delay(250)
                val nowNs = System.nanoTime()
                val cur = totalProgress.get()
                val sec = (nowNs - lastNs) / 1e9
                val bps = (cur - lastBytes) / sec.coerceAtLeast(0.01)
                lastNs = nowNs
                lastBytes = cur
                updateTask(task.id) { it.copy(downloadedBytes = cur, totalBytes = totalSize, speedBytesPerSec = bps.coerceAtLeast(0.0)) }
            }
        }

        try {
            val jobs = (0 until actualParts).map { partIdx ->
                launch(Dispatchers.IO) {
                    val startByte = partIdx * chunkSize + partOffsets[partIdx]
                    val endByte = if (partIdx == actualParts - 1) totalSize - 1 else ((partIdx + 1) * chunkSize - 1)
                    if (startByte > endByte) return@launch

                    val conn = (URL(task.url).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 15_000
                        readTimeout = 30_000
                        instanceFollowRedirects = true
                        setRequestProperty("User-Agent", ua)
                        setRequestProperty("Range", "bytes=$startByte-$endByte")
                    }
                    val code = conn.responseCode
                    if (code != HttpURLConnection.HTTP_PARTIAL && code != HttpURLConnection.HTTP_OK) {
                        throw IllegalStateException("Part $partIdx failed with HTTP $code")
                    }

                    RandomAccessFile(destFile, "rw").use { raf ->
                        raf.seek(startByte)
                        BufferedInputStream(conn.inputStream, 128 * 1024).use { bis ->
                            val buf = ByteArray(64 * 1024)
                            var partDone = partOffsets[partIdx]
                            var sinceSave = 0L
                            while (isActive) {
                                val r = bis.read(buf)
                                if (r <= 0) break
                                raf.write(buf, 0, r)
                                partDone += r
                                sinceSave += r
                                totalProgress.addAndGet(r.toLong())
                                if (sinceSave >= 256 * 1024L) {
                                    sinceSave = 0L
                                    runCatching { partFiles[partIdx].writeText(partDone.toString()) }
                                }
                            }
                            runCatching { partFiles[partIdx].writeText(partDone.toString()) }
                        }
                    }
                    conn.disconnect()
                }
            }
            jobs.joinAll()
        } finally {
            monitorJob.cancel()
        }

        cleanPartFiles(destFile, actualParts)
        updateTask(task.id) {
            it.copy(
                status = DownloadStatus.COMPLETED,
                downloadedBytes = totalSize,
                totalBytes = totalSize,
                speedBytesPerSec = 0.0
            )
        }
        AppLogger.info("IDM", "Completed ${actualParts}-part download: ${destFile.name} (${ProtocolUtils.formatBytes(totalSize)})")
    }

    private suspend fun runHlsDownload(task: DownloadTaskItem, userAgent: String?) = withContext(Dispatchers.IO) {
        val ua = userAgent ?: "Mozilla/5.0 (Linux; Android 15; WQGlass/4.0) AppleWebKit/537.36"
        val playlistText = fetchText(task.url, ua)
        var segmentUrls = parseHlsSegments(task.url, playlistText)

        // If master playlist, follow the highest bandwidth variant
        if (segmentUrls.size == 1 && segmentUrls[0].contains(".m3u8", ignoreCase = true)) {
            val subText = fetchText(segmentUrls[0], ua)
            segmentUrls = parseHlsSegments(segmentUrls[0], subText)
        }
        if (segmentUrls.isEmpty()) throw IllegalStateException("No HLS video segments found in .m3u8 playlist")

        val destFile = File(task.destinationPath)
        destFile.parentFile?.mkdirs()
        var totalWritten = 0L
        val startNs = System.nanoTime()

        FileOutputStream(destFile, false).use { fos ->
            val buf = ByteArray(64 * 1024)
            segmentUrls.forEachIndexed { idx, segUrl ->
                val conn = (URL(segUrl).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 15_000
                    readTimeout = 25_000
                    instanceFollowRedirects = true
                    setRequestProperty("User-Agent", ua)
                }
                conn.inputStream.use { ins ->
                    while (isActive) {
                        val r = ins.read(buf)
                        if (r <= 0) break
                        fos.write(buf, 0, r)
                        totalWritten += r
                    }
                }
                conn.disconnect()
                val elapsedSec = ((System.nanoTime() - startNs) / 1e9).coerceAtLeast(0.05)
                val estTotal = (totalWritten.toDouble() / ((idx + 1).toDouble() / segmentUrls.size.toDouble())).toLong()
                updateTask(task.id) {
                    it.copy(
                        downloadedBytes = totalWritten,
                        totalBytes = estTotal.coerceAtLeast(totalWritten),
                        speedBytesPerSec = totalWritten / elapsedSec
                    )
                }
            }
        }

        updateTask(task.id) {
            it.copy(
                status = DownloadStatus.COMPLETED,
                downloadedBytes = totalWritten,
                totalBytes = totalWritten,
                speedBytesPerSec = 0.0
            )
        }
        AppLogger.info("IDM", "Completed HLS stream download (${segmentUrls.size} segments, ${ProtocolUtils.formatBytes(totalWritten)})")
    }

    private fun fetchText(url: String, ua: String): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 12_000
            readTimeout = 15_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", ua)
        }
        return conn.inputStream.bufferedReader().use { it.readText() }
    }

    private fun parseHlsSegments(baseUrl: String, m3u8: String): List<String> {
        val base = URL(baseUrl)
        val lines = m3u8.lines().map { it.trim() }.filter { it.isNotEmpty() }
        val variants = mutableListOf<Pair<Long, String>>()
        val segments = mutableListOf<String>()

        var i = 0
        while (i < lines.size) {
            val l = lines[i]
            if (l.startsWith("#EXT-X-STREAM-INF:", ignoreCase = true)) {
                val bw = Regex("BANDWIDTH=(\\d+)").find(l)?.groupValues?.getOrNull(1)?.toLongOrNull() ?: 0L
                if (i + 1 < lines.size && !lines[i + 1].startsWith("#")) {
                    variants.add(bw to URL(base, lines[i + 1]).toString())
                    i += 2
                    continue
                }
            } else if (!l.startsWith("#")) {
                segments.add(URL(base, l).toString())
            }
            i++
        }
        if (variants.isNotEmpty()) {
            val best = variants.maxByOrNull { it.first }!!.second
            return listOf(best)
        }
        return segments
    }

    private fun cleanPartFiles(destFile: File, count: Int) {
        for (i in 0 until count) {
            runCatching { File(destFile.parentFile, ".${destFile.name}.part$i").delete() }
        }
    }

    private fun updateTask(taskId: String, updater: (DownloadTaskItem) -> DownloadTaskItem) {
        _tasks.value = _tasks.value.map { if (it.id == taskId) updater(it) else it }
    }

    fun guessFileName(url: String): String {
        val clean = url.substringBefore('?').substringBefore('#').trimEnd('/')
        val raw = clean.substringAfterLast('/').trim()
        if (raw.isNotEmpty() && raw.contains('.')) return raw
        return "download_${System.currentTimeMillis()}.bin"
    }

    /**
     * Converts / extracts audio or remuxes video using Android's hardware MediaExtractor + MediaMuxer.
     */
    suspend fun remuxOrExtractMedia(inputFile: File, audioOnlyM4a: Boolean): Result<File> = withContext(Dispatchers.IO) {
        runCatching {
            val outExt = if (audioOnlyM4a) ".m4a" else ".mp4"
            val stem = inputFile.nameWithoutExtension
            val outFile = ProtocolUtils.uniqueTargetFile(inputFile.parentFile ?: defaultDownloadsDir(), "${stem}_converted$outExt")

            val extractor = android.media.MediaExtractor()
            FileInputStream(inputFile).use { fis ->
                extractor.setDataSource(fis.fd)
                val muxer = android.media.MediaMuxer(outFile.absolutePath, android.media.MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                val trackMap = HashMap<Int, Int>()
                for (i in 0 until extractor.trackCount) {
                    val format = extractor.getTrackFormat(i)
                    val mime = format.getString(android.media.MediaFormat.KEY_MIME) ?: ""
                    if (audioOnlyM4a) {
                        if (mime.startsWith("audio/")) {
                            extractor.selectTrack(i)
                            trackMap[i] = muxer.addTrack(format)
                        }
                    } else if (mime.startsWith("audio/") || mime.startsWith("video/")) {
                        extractor.selectTrack(i)
                        trackMap[i] = muxer.addTrack(format)
                    }
                }
                if (trackMap.isEmpty()) {
                    muxer.release()
                    extractor.release()
                    throw IllegalStateException("No compatible media tracks found in ${inputFile.name}")
                }
                muxer.start()
                val buf = java.nio.ByteBuffer.allocate(1024 * 1024)
                val info = android.media.MediaCodec.BufferInfo()
                while (true) {
                    val trackIdx = extractor.sampleTrackIndex
                    if (trackIdx < 0) break
                    info.offset = 0
                    info.size = extractor.readSampleData(buf, 0)
                    if (info.size < 0) break
                    info.presentationTimeUs = extractor.sampleTime
                    info.flags = extractor.sampleFlags
                    val dstTrack = trackMap[trackIdx]
                    if (dstTrack != null) {
                        muxer.writeSampleData(dstTrack, buf, info)
                    }
                    extractor.advance()
                }
                muxer.stop()
                muxer.release()
                extractor.release()
            }
            AppLogger.info("MediaConverter", "Converted ${inputFile.name} → ${outFile.name}")
            outFile
        }
    }
}
