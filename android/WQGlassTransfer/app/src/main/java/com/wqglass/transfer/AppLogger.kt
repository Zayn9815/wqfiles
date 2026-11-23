package com.wqglass.transfer

import android.content.Context
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class DiagnosticLogEntry(
    val timestamp: String,
    val level: String,
    val source: String,
    val message: String,
    val detail: String? = null
) {
    fun formattedLine(): String {
        return if (detail.isNullOrBlank()) {
            "[$timestamp] [$level] [$source] $message"
        } else {
            val indented = detail.trim().replace("\r\n", "\n").replace("\n", "\n    ")
            "[$timestamp] [$level] [$source] $message\n    $indented"
        }
    }
}

/**
 * Thread-safe diagnostic, error, and crash logger for WQGlass Transfer (Android).
 * Captures uncaught exceptions on all threads, persists logs to internal app storage,
 * and exposes live reactive state for the Logs & Crash Reports tab.
 */
object AppLogger {
    private const val MAX_ENTRIES = 600
    private const val MAX_FILE_BYTES = 2 * 1024 * 1024L

    private val lock = Any()
    private var logDir: File? = null
    private var installedHandler = false

    private val _entries = MutableStateFlow<List<DiagnosticLogEntry>>(emptyList())
    val entries: StateFlow<List<DiagnosticLogEntry>> = _entries.asStateFlow()

    private val _crashDiskText = MutableStateFlow("")
    val crashDiskText: StateFlow<String> = _crashDiskText.asStateFlow()

    fun init(context: Context) {
        synchronized(lock) {
            val dir = File(context.filesDir, "logs").apply { mkdirs() }
            logDir = dir
            rotateIfLarge(File(dir, "wqglass-transfer.log"))
            rotateIfLarge(File(dir, "wqglass-crashes.log"))
            refreshCrashDiskTextLocked()

            if (!installedHandler) {
                installedHandler = true
                val prev = Thread.getDefaultUncaughtExceptionHandler()
                Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
                    try {
                        crash("Uncaught-${thread.name}", throwable.message ?: "Fatal uncaught exception", throwable)
                    } catch (_: Exception) {
                    } finally {
                        prev?.uncaughtException(thread, throwable)
                    }
                }
            }
        }
        info(
            "Startup",
            "WQ Glass Studio v3.0.1 started on ${Build.MANUFACTURER} ${Build.MODEL} (Android ${Build.VERSION.RELEASE}, SDK ${Build.VERSION.SDK_INT}) · ifaces: ${TransferServer.getActiveInterfacesSummary()}"
        )
    }

    fun info(source: String, message: String, detail: String? = null) =
        record("INFO", source, message, detail, isCrash = false)

    fun warn(source: String, message: String, detail: String? = null) =
        record("WARN", source, message, detail, isCrash = false)

    fun error(source: String, message: String, throwable: Throwable? = null) =
        record("ERROR", source, message, throwable?.stackTraceToString(), isCrash = false)

    fun error(source: String, message: String, detail: String?) =
        record("ERROR", source, message, detail, isCrash = false)

    fun crash(source: String, message: String, throwable: Throwable?) =
        record("CRASH", source, message, throwable?.stackTraceToString() ?: "Unknown crash", isCrash = true)

    private fun record(level: String, source: String, message: String, detail: String?, isCrash: Boolean) {
        val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
        val entry = DiagnosticLogEntry(ts, level, source, message, detail)
        val line = entry.formattedLine() + "\n"

        synchronized(lock) {
            _entries.value = (listOf(entry) + _entries.value).take(MAX_ENTRIES)
            val dir = logDir
            if (dir != null) {
                try {
                    dir.mkdirs()
                    File(dir, "wqglass-transfer.log").appendText(line, Charsets.UTF_8)
                    if (isCrash || level == "ERROR") {
                        File(dir, "wqglass-crashes.log").appendText(line, Charsets.UTF_8)
                        refreshCrashDiskTextLocked()
                    }
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun refreshCrashDiskTextLocked() {
        val dir = logDir ?: return
        val crashFile = File(dir, "wqglass-crashes.log")
        _crashDiskText.value = try {
            if (crashFile.exists()) crashFile.readText(Charsets.UTF_8) else ""
        } catch (_: Exception) {
            ""
        }
    }

    fun clearAll() {
        synchronized(lock) {
            _entries.value = emptyList()
            _crashDiskText.value = ""
            val dir = logDir
            if (dir != null) {
                runCatching { File(dir, "wqglass-transfer.log").delete() }
                runCatching { File(dir, "wqglass-crashes.log").delete() }
            }
        }
        info("Logger", "Diagnostic, error & crash logs cleared by user.")
    }

    fun buildFullReport(filter: String = "ALL"): String {
        val sb = StringBuilder()
        val now = SimpleDateFormat("yyyy-MM-dd HH:mm:ss Z", Locale.US).format(Date())
        val hs = TransferForegroundService.server.state.value
        val hostSummary = if (hs.isRunning) "Running (${hs.ipAddress}:${hs.port} · PIN ${hs.pin} · /${hs.rootLabel})" else "Stopped"
        sb.appendLine("==================================================================")
        sb.appendLine("WQ Glass Studio — Diagnostic, Error & Crash Report (Android)")
        sb.appendLine("==================================================================")
        sb.appendLine("Generated   : $now")
        sb.appendLine("App Version : 3.0.1 (301)")
        sb.appendLine("Device      : ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE})")
        sb.appendLine("Android OS  : Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        sb.appendLine("ABIs        : ${Build.SUPPORTED_ABIS.joinToString(", ")}")
        sb.appendLine("Host Server : $hostSummary")
        sb.appendLine("Active IPs  : ${TransferServer.getActiveInterfacesSummary()}")
        sb.appendLine("==================================================================")
        sb.appendLine()

        val crashTxt = _crashDiskText.value.trim()
        if (crashTxt.isNotEmpty()) {
            sb.appendLine("--- PERSISTED ERROR & CRASH LOG (wqglass-crashes.log) ---")
            sb.appendLine(crashTxt)
            sb.appendLine()
        } else {
            sb.appendLine("--- PERSISTED ERROR & CRASH LOG: None recorded ---")
            sb.appendLine()
        }

        sb.appendLine("--- SESSION LOGS (Filter: $filter) ---")
        val list = _entries.value.filter { matchesFilter(it, filter) }
        if (list.isEmpty()) {
            sb.appendLine("(No entries matching filter $filter)")
        } else {
            for (item in list) {
                sb.appendLine(item.formattedLine())
            }
        }
        return sb.toString()
    }

    fun matchesFilter(item: DiagnosticLogEntry, filter: String): Boolean {
        return when (filter.uppercase(Locale.ROOT)) {
            "ERRORS" -> item.level == "ERROR" || item.level == "WARN" || item.level == "CRASH"
            "CRASHES" -> item.level == "CRASH"
            else -> true
        }
    }

    private fun rotateIfLarge(file: File) {
        try {
            if (file.exists() && file.length() > MAX_FILE_BYTES) {
                val prev = File(file.parentFile, file.name + ".prev")
                if (prev.exists()) prev.delete()
                file.renameTo(prev)
            }
        } catch (_: Exception) {
        }
    }
}
