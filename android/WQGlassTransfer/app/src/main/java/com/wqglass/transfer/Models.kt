package com.wqglass.transfer

import java.io.File
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.Locale
import java.util.UUID

data class DiscoveredPeer(
    val app: String = "WQGlass",
    val version: String = "1.1",
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
}

data class RemoteFileItem(
    val name: String,
    val path: String,
    val isDir: Boolean,
    val size: Long,
    val mtime: Long
)

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
}

data class ParsedQrEndpoint(
    val endpoint: String,
    val pin: String?
)

object ProtocolUtils {
    const val DISCOVERY_PORT = 45888
    const val BASE_HTTP_PORT = 8765
    const val CHUNK_BYTES = 256 * 1024

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
}
