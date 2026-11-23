package com.wqglass.transfer

import java.io.File
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.Locale
import java.util.UUID
import kotlin.math.ceil

data class DiscoveredPeer(
    val app: String = "WQGlass",
    val version: String = "2.0",
    val device: String = "Device",
    val platform: String = "ios",
    val osVersion: String = "",
    val ip: String = "",
    val port: Int = 8765,
    val root: String = "Downloads",
    val lastSeenMs: Long = System.currentTimeMillis()
) {
    val endpoint: String get() = "$ip:$port"

    val normalizedPlatform: String
        get() = when (platform.trim().lowercase(Locale.ROOT)) {
            "android" -> "android"
            "windows" -> "windows"
            else -> "ios"
        }

    val platformBadge: String
        get() = when (normalizedPlatform) {
            "android" -> "Android"
            "windows" -> "Windows"
            else -> "iOS"
        }

    val platformEmoji: String
        get() = when (normalizedPlatform) {
            "android" -> "\uD83E\uDD16"
            "windows" -> "\uD83D\uDCBB"
            else -> "\uD83C\uDF4E"
        }

    val displayName: String
        get() = "$platformEmoji $platformBadge · $device ($endpoint) · $root"
}

data class RemoteInfo(
    val device: String = "Device",
    val platform: String = "ios",
    val osVersion: String = "",
    val iosVersion: String = "",
    val root: String = "Downloads",
    val freeBytes: Long = 0L,
    val totalBytes: Long = 0L
) {
    val normalizedPlatform: String
        get() = when (platform.trim().lowercase(Locale.ROOT)) {
            "android" -> "android"
            "windows" -> "windows"
            else -> "ios"
        }

    val platformLabel: String
        get() = when (normalizedPlatform) {
            "android" -> "Android"
            "windows" -> "Windows"
            else -> "iOS"
        }

    val effectiveOsVersion: String
        get() = osVersion.ifBlank { iosVersion }

    val osSummary: String
        get() = if (effectiveOsVersion.isBlank()) platformLabel else "$platformLabel $effectiveOsVersion"

    val usedFraction: Float
        get() = if (totalBytes > 0L) ((totalBytes - freeBytes).toDouble() / totalBytes.toDouble()).toFloat().coerceIn(0f, 1f) else 0f
}

data class RemoteFileItem(
    val name: String,
    val path: String,
    val isDir: Boolean,
    val size: Long,
    val mtime: Long
) {
    val category: String
        get() = if (isDir) "Folders" else ProtocolUtils.categorizeFileName(name)
}

data class TransferProgress(
    val verb: String,
    val fileName: String,
    val transferredBytes: Long,
    val totalBytes: Long,
    val bytesPerSec: Double,
    val fileIndex: Int,
    val fileCount: Int
) {
    val fraction: Float
        get() = if (totalBytes > 0L) (transferredBytes.toDouble() / totalBytes.toDouble()).toFloat().coerceIn(0f, 1f) else 0f

    val etaText: String
        get() {
            if (bytesPerSec < 100.0 || totalBytes <= transferredBytes) return "--"
            return ProtocolUtils.formatEta((totalBytes - transferredBytes) / bytesPerSec)
        }
}

data class TransferHistoryItem(
    val timestamp: String,
    val direction: String,
    val fileName: String,
    val bytes: Long,
    val avgBytesPerSec: Double,
    val status: String
)

data class ParsedQrEndpoint(
    val endpoint: String,
    val pin: String?
)

object ProtocolUtils {
    const val DISCOVERY_PORT = 45888
    const val BASE_HTTP_PORT = 8765
    const val CHUNK_BYTES = 1024 * 1024        // 1 MB chunks for fast Wi-Fi streaming
    const val SOCKET_BUF_BYTES = 4 * 1024 * 1024 // 4 MB TCP socket windows

    fun categorizeFileName(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return when (ext) {
            "mp4", "mov", "m4v", "mkv", "webm", "avi", "ts", "wmv" -> "Videos"
            "jpg", "jpeg", "png", "heic", "gif", "webp", "bmp", "dng" -> "Photos"
            "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "aiff" -> "Audio"
            "zip", "rar", "7z", "tar", "gz", "ipa", "apk", "exe" -> "Archives"
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "json" -> "Docs"
            else -> "Other"
        }
    }

    fun formatBytes(bytes: Long): String {
        val safe = bytes.coerceAtLeast(0L)
        return when {
            safe < 1024L -> "$safe B"
            safe < 1024L * 1024L -> String.format(Locale.US, "%.1f KB", safe / 1024.0)
            safe < 1024L * 1024L * 1024L -> String.format(Locale.US, "%.2f MB", safe / (1024.0 * 1024.0))
            else -> String.format(Locale.US, "%.2f GB", safe / (1024.0 * 1024.0 * 1024.0))
        }
    }

    fun formatSpeed(bytesPerSec: Double): String {
        val safe = bytesPerSec.coerceAtLeast(0.0)
        return when {
            safe < 1024.0 -> String.format(Locale.US, "%.0f B/s", safe)
            safe < 1024.0 * 1024.0 -> String.format(Locale.US, "%.1f KB/s", safe / 1024.0)
            else -> String.format(Locale.US, "%.2f MB/s", safe / (1024.0 * 1024.0))
        }
    }

    fun formatEta(seconds: Double): String {
        if (seconds.isNaN() || seconds.isInfinite() || seconds < 0.0 || seconds > 86400.0 * 7) return "--"
        val s = ceil(seconds).toLong()
        return when {
            s < 60L -> "${s}s"
            s < 3600L -> "${s / 60L}m ${s % 60L}s"
            else -> "${s / 3600L}h ${(s % 3600L) / 60L}m"
        }
    }

    fun urlEncode(value: String): String {
        return URLEncoder.encode(value, "UTF-8").replace("+", "%20")
    }

    fun parseQueryParams(query: String?): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        if (query.isNullOrEmpty()) return out
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            if (eq >= 0) {
                val k = URLDecoder.decode(pair.substring(0, eq), "UTF-8")
                val v = URLDecoder.decode(pair.substring(eq + 1), "UTF-8")
                out[k] = v
            } else {
                out[URLDecoder.decode(pair, "UTF-8")] = ""
            }
        }
        return out
    }

    fun safeResolvePath(rootDir: File, relativePath: String?): File? {
        return try {
            val canonicalRoot = rootDir.canonicalFile
            val normalizedRel = (relativePath ?: "").replace('\\', '/').trimStart('/')
            if (normalizedRel.isEmpty()) return canonicalRoot
            val candidate = File(canonicalRoot, normalizedRel).canonicalFile
            val rootStr = canonicalRoot.path.trimEnd(File.separatorChar)
            val candStr = candidate.path.trimEnd(File.separatorChar)
            if (candStr == rootStr || candStr.startsWith(rootStr + File.separatorChar)) {
                candidate
            } else {
                null
            }
        } catch (_: Exception) {
            null
        }
    }

    fun uniqueTargetFile(dir: File, filename: String): File {
        val base = File(dir, filename)
        if (!base.exists()) return base
        val dot = filename.lastIndexOf('.')
        val stem = if (dot > 0) filename.substring(0, dot) else filename
        val ext = if (dot > 0) filename.substring(dot) else ""
        for (i in 2 until 1000) {
            val cand = File(dir, "${stem}_$i$ext")
            if (!cand.exists()) return cand
        }
        return File(dir, "${UUID.randomUUID()}_$filename")
    }

    fun parseQrPayload(raw: String): ParsedQrEndpoint? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        val noScheme = trimmed
            .removePrefix("http://")
            .removePrefix("https://")
        val qIdx = noScheme.indexOf('?')
        val hostPart = (if (qIdx >= 0) noScheme.substring(0, qIdx) else noScheme)
            .substringBefore('/')
            .trim()
        if (hostPart.isEmpty()) return null
        val queryPart = if (qIdx >= 0) noScheme.substring(qIdx + 1) else ""
        val pin = parseQueryParams(queryPart)["pin"]?.trim()?.takeIf { it.isNotEmpty() }
        return ParsedQrEndpoint(endpoint = hostPart, pin = pin)
    }

    fun resolveTreeDocIdToPath(docId: String, primaryStorageRoot: String = "/storage/emulated/0"): String? {
        val parts = docId.split(':', limit = 2)
        if (parts.isEmpty()) return null
        val volume = parts[0]
        val rel = if (parts.size > 1) parts[1].trim('/') else ""
        return when {
            volume.equals("primary", ignoreCase = true) -> {
                if (rel.isEmpty()) primaryStorageRoot else "$primaryStorageRoot/$rel"
            }
            volume.isNotBlank() && !volume.equals("home", ignoreCase = true) -> {
                if (rel.isEmpty()) "/storage/$volume" else "/storage/$volume/$rel"
            }
            volume.equals("home", ignoreCase = true) -> {
                if (rel.isEmpty()) "$primaryStorageRoot/Documents" else "$primaryStorageRoot/Documents/$rel"
            }
            else -> null
        }
    }
}
