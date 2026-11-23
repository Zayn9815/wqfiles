package com.wqglass.transfer

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.os.Environment
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

data class StorageCategorySummary(
    val category: String,
    val bytes: Long,
    val count: Int
)

data class DuplicateGroupItem(
    val sha256: String,
    val sizeBytes: Long,
    val files: List<File>
)

data class InstalledAppSummary(
    val appName: String,
    val packageName: String,
    val versionName: String,
    val apkPath: String,
    val apkSizeBytes: Long,
    val isSystemApp: Boolean
)

/**
 * Core engines for WQ Glass Android Studio:
 * - AES-256-CBC + HMAC-SHA256 (.wqenc Portable File Locker & Private Vault)
 * - ZIP Archive Creation & Extraction
 * - SQLite Database Inspector, Hex Dump Viewer, Hash Calculator (MD5, SHA-1, SHA-256, SHA-512)
 * - Storage Analyzer, Duplicate File Finder, Cache & Junk Cleaner, and Installed Apps APK Backup Manager.
 */
object WqCryptoVaultTools {
    private val MAGIC = "WQENC1".toByteArray(Charsets.US_ASCII)

    fun encryptBytes(plain: ByteArray, password: String): ByteArray {
        require(password.isNotEmpty()) { "Password cannot be empty" }
        val rng = SecureRandom()
        val salt = ByteArray(16).also { rng.nextBytes(it) }
        val iv = ByteArray(16).also { rng.nextBytes(it) }
        val (encKey, macKey) = deriveKeys(password, salt)

        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(encKey, "AES"), IvParameterSpec(iv))
        val cipherBytes = cipher.doFinal(plain)

        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(macKey, "HmacSHA256"))
        mac.update(MAGIC)
        mac.update(salt)
        mac.update(iv)
        val tag = mac.doFinal(cipherBytes)

        val out = ByteArrayOutputStream(MAGIC.size + 16 + 16 + 32 + cipherBytes.size)
        out.write(MAGIC)
        out.write(salt)
        out.write(iv)
        out.write(tag)
        out.write(cipherBytes)
        return out.toByteArray()
    }

    fun decryptBytes(blob: ByteArray, password: String): ByteArray {
        require(blob.size >= MAGIC.size + 16 + 16 + 32) { "Not a valid .wqenc encrypted file" }
        for (i in MAGIC.indices) {
            require(blob[i] == MAGIC[i]) { "File header is not a WQ Glass (.wqenc) container" }
        }
        val salt = blob.copyOfRange(6, 22)
        val iv = blob.copyOfRange(22, 38)
        val expectedTag = blob.copyOfRange(38, 70)
        val cipherBytes = blob.copyOfRange(70, blob.size)

        val (encKey, macKey) = deriveKeys(password, salt)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(macKey, "HmacSHA256"))
        mac.update(MAGIC)
        mac.update(salt)
        mac.update(iv)
        val actualTag = mac.doFinal(cipherBytes)
        require(MessageDigest.isEqual(expectedTag, actualTag)) { "Incorrect password or corrupted .wqenc file (HMAC verification failed)" }

        val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(encKey, "AES"), IvParameterSpec(iv))
        return cipher.doFinal(cipherBytes)
    }

    private fun deriveKeys(password: String, salt: ByteArray): Pair<ByteArray, ByteArray> {
        val spec = PBEKeySpec(password.toCharArray(), salt, 60_000, 512)
        val skf = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val full = skf.generateSecret(spec).encoded
        return full.copyOfRange(0, 32) to full.copyOfRange(32, 64)
    }

    suspend fun encryptFileToWqEnc(inputFile: File, password: String): Result<File> = withContext(Dispatchers.IO) {
        runCatching {
            val encrypted = encryptBytes(inputFile.readBytes(), password)
            val out = ProtocolUtils.uniqueTargetFile(
                inputFile.parentFile ?: Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "${inputFile.name}.wqenc"
            )
            out.writeBytes(encrypted)
            AppLogger.info("Crypto", "Encrypted ${inputFile.name} → ${out.name}")
            out
        }
    }

    suspend fun decryptWqEncFile(inputFile: File, password: String): Result<File> = withContext(Dispatchers.IO) {
        runCatching {
            val plain = decryptBytes(inputFile.readBytes(), password)
            val baseName = if (inputFile.name.endsWith(".wqenc", ignoreCase = true)) {
                inputFile.name.dropLast(6).ifBlank { "decrypted.bin" }
            } else {
                "decrypted_${inputFile.name}"
            }
            val out = ProtocolUtils.uniqueTargetFile(
                inputFile.parentFile ?: Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                baseName
            )
            out.writeBytes(plain)
            AppLogger.info("Crypto", "Decrypted ${inputFile.name} → ${out.name}")
            out
        }
    }

    // ZIP Archive creation & extraction
    suspend fun zipFiles(sources: List<File>, outputZip: File): Result<File> = withContext(Dispatchers.IO) {
        runCatching {
            ZipOutputStream(BufferedOutputStream(FileOutputStream(outputZip))).use { zos ->
                val buf = ByteArray(128 * 1024)
                fun addNode(node: File, prefix: String) {
                    val entryName = if (prefix.isEmpty()) node.name else "$prefix/${node.name}"
                    if (node.isDirectory) {
                        node.listFiles()?.forEach { child -> addNode(child, entryName) }
                    } else if (node.isFile) {
                        zos.putNextEntry(ZipEntry(entryName))
                        FileInputStream(node).use { fis ->
                            while (true) {
                                val r = fis.read(buf)
                                if (r <= 0) break
                                zos.write(buf, 0, r)
                            }
                        }
                        zos.closeEntry()
                    }
                }
                sources.forEach { addNode(it, "") }
            }
            AppLogger.info("Archive", "Created ZIP archive: ${outputZip.name} (${ProtocolUtils.formatBytes(outputZip.length())})")
            outputZip
        }
    }

    suspend fun unzipFile(zipFile: File, destDir: File): Result<Int> = withContext(Dispatchers.IO) {
        runCatching {
            destDir.mkdirs()
            val canonicalDest = destDir.canonicalPath
            var count = 0
            val buf = ByteArray(128 * 1024)
            ZipInputStream(BufferedInputStream(FileInputStream(zipFile))).use { zis ->
                while (true) {
                    val entry = zis.nextEntry ?: break
                    val outTarget = File(destDir, entry.name).canonicalFile
                    if (!outTarget.path.startsWith(canonicalDest)) {
                        zis.closeEntry()
                        continue
                    }
                    if (entry.isDirectory) {
                        outTarget.mkdirs()
                    } else {
                        outTarget.parentFile?.mkdirs()
                        FileOutputStream(outTarget).use { fos ->
                            while (true) {
                                val r = zis.read(buf)
                                if (r <= 0) break
                                fos.write(buf, 0, r)
                            }
                        }
                        count++
                    }
                    zis.closeEntry()
                }
            }
            AppLogger.info("Archive", "Extracted $count file(s) from ${zipFile.name} → ${destDir.name}")
            count
        }
    }

    // Checksums & Hex Viewer
    suspend fun computeFileHashes(file: File): Map<String, String> = withContext(Dispatchers.IO) {
        val md5 = MessageDigest.getInstance("MD5")
        val sha1 = MessageDigest.getInstance("SHA-1")
        val sha256 = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(128 * 1024)
        FileInputStream(file).use { fis ->
            while (true) {
                val r = fis.read(buf)
                if (r <= 0) break
                md5.update(buf, 0, r)
                sha1.update(buf, 0, r)
                sha256.update(buf, 0, r)
            }
        }
        linkedMapOf(
            "MD5" to md5.digest().toHex(),
            "SHA-1" to sha1.digest().toHex(),
            "SHA-256" to sha256.digest().toHex()
        )
    }

    fun formatHexPreview(file: File, maxBytes: Int = 4096): String {
        val bytes = ByteArray(maxBytes)
        val readCount = FileInputStream(file).use { it.read(bytes) }.coerceAtLeast(0)
        val sb = StringBuilder()
        var offset = 0
        while (offset < readCount) {
            val lineLen = (readCount - offset).coerceAtMost(16)
            sb.append(String.format(Locale.US, "%08X  ", offset))
            for (i in 0 until 16) {
                if (i < lineLen) sb.append(String.format(Locale.US, "%02X ", bytes[offset + i]))
                else sb.append("   ")
                if (i == 7) sb.append(' ')
            }
            sb.append(" |")
            for (i in 0 until lineLen) {
                val b = bytes[offset + i].toInt() and 0xFF
                sb.append(if (b in 32..126) b.toChar() else '.')
            }
            sb.appendLine("|")
            offset += 16
        }
        return sb.toString()
    }

    // SQLite Inspector
    fun inspectSqliteTables(file: File): Result<Pair<List<String>, Map<String, List<List<String>>>>> {
        return runCatching {
            val db = SQLiteDatabase.openDatabase(file.absolutePath, null, SQLiteDatabase.OPEN_READONLY)
            db.use {
                val tables = mutableListOf<String>()
                it.rawQuery("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", null).use { c ->
                    while (c.moveToNext()) tables.add(c.getString(0))
                }
                val tablePreview = LinkedHashMap<String, List<List<String>>>()
                for (t in tables.take(15)) {
                    val rows = mutableListOf<List<String>>()
                    runCatching {
                        it.rawQuery("SELECT * FROM \"$t\" LIMIT 40", null).use { rc ->
                            val cols = rc.columnNames.toList()
                            rows.add(cols)
                            while (rc.moveToNext()) {
                                val r = (0 until rc.columnCount).map { idx ->
                                    runCatching { rc.getString(idx) ?: "NULL" }.getOrDefault("[BLOB]")
                                }
                                rows.add(r)
                            }
                        }
                    }
                    tablePreview[t] = rows
                }
                tables to tablePreview
            }
        }
    }

    // Storage Analyzer
    suspend fun analyzeStorageRoot(root: File): Pair<List<StorageCategorySummary>, List<File>> = withContext(Dispatchers.IO) {
        val totals = LinkedHashMap<String, Pair<Long, Int>>()
        val largestFiles = mutableListOf<File>()

        fun walk(dir: File, depth: Int) {
            if (depth > 8) return
            val list = dir.listFiles() ?: return
            for (f in list) {
                if (f.name.startsWith(".")) continue
                if (f.isDirectory) {
                    walk(f, depth + 1)
                } else if (f.isFile) {
                    val sz = f.length()
                    val cat = ProtocolUtils.categorizeFileName(f.name)
                    val cur = totals[cat] ?: (0L to 0)
                    totals[cat] = (cur.first + sz) to (cur.second + 1)
                    if (sz > 1024 * 1024L) {
                        largestFiles.add(f)
                    }
                }
            }
        }
        walk(root, 0)
        val summaries = totals.entries
            .map { StorageCategorySummary(it.key, it.value.first, it.value.second) }
            .sortedByDescending { it.bytes }
        val topFiles = largestFiles.sortedByDescending { it.length() }.take(30)
        summaries to topFiles
    }

    // Duplicate File Finder
    suspend fun findDuplicateFiles(root: File): List<DuplicateGroupItem> = withContext(Dispatchers.IO) {
        val bySize = HashMap<Long, MutableList<File>>()
        fun walk(dir: File, depth: Int) {
            if (depth > 6) return
            val list = dir.listFiles() ?: return
            for (f in list) {
                if (f.name.startsWith(".")) continue
                if (f.isDirectory) walk(f, depth + 1)
                else if (f.isFile && f.length() >= 32 * 1024L && f.length() <= 500L * 1024 * 1024) {
                    bySize.getOrPut(f.length()) { mutableListOf() }.add(f)
                }
            }
        }
        walk(root, 0)

        val groups = mutableListOf<DuplicateGroupItem>()
        val buf = ByteArray(64 * 1024)
        for ((size, candidates) in bySize) {
            if (candidates.size < 2) continue
            val byHash = HashMap<String, MutableList<File>>()
            for (file in candidates) {
                val hash = runCatching {
                    val md = MessageDigest.getInstance("SHA-256")
                    FileInputStream(file).use { fis ->
                        while (true) {
                            val r = fis.read(buf)
                            if (r <= 0) break
                            md.update(buf, 0, r)
                        }
                    }
                    md.digest().toHex()
                }.getOrNull() ?: continue
                byHash.getOrPut(hash) { mutableListOf() }.add(file)
            }
            for ((hash, dupes) in byHash) {
                if (dupes.size >= 2) {
                    groups.add(DuplicateGroupItem(hash.take(16), size, dupes))
                }
            }
        }
        groups.sortedByDescending { it.sizeBytes * it.files.size }
    }

    // Cache & Junk Cleaner
    suspend fun scanCleanableJunk(context: Context): List<File> = withContext(Dispatchers.IO) {
        val found = mutableListOf<File>()
        context.cacheDir?.listFiles()?.forEach { found.add(it) }
        context.externalCacheDir?.listFiles()?.forEach { found.add(it) }

        val storageRoot = Environment.getExternalStorageDirectory()
        val junkExts = setOf("tmp", "temp", "log", "bak", "old")
        fun walk(dir: File, depth: Int) {
            if (depth > 4) return
            val list = dir.listFiles() ?: return
            for (f in list) {
                if (f.isDirectory) {
                    if (f.name.equals("cache", ignoreCase = true) || f.name.equals(".thumbnails", ignoreCase = true)) {
                        found.add(f)
                    } else if (!f.name.equals("Android", ignoreCase = true)) {
                        walk(f, depth + 1)
                    }
                } else if (f.isFile) {
                    val ext = f.extension.lowercase(Locale.ROOT)
                    if (junkExts.contains(ext) || f.length() == 0L) {
                        found.add(f)
                    }
                }
            }
        }
        runCatching { walk(storageRoot, 0) }
        found.distinctBy { it.absolutePath }
    }

    fun calculateSizeRecursive(file: File): Long {
        if (!file.exists()) return 0L
        if (file.isFile) return file.length()
        return file.listFiles()?.sumOf { calculateSizeRecursive(it) } ?: 0L
    }

    // Installed Apps & APK Backup Manager
    suspend fun listInstalledApps(context: Context, includeSystem: Boolean): List<InstalledAppSummary> = withContext(Dispatchers.IO) {
        val pm = context.packageManager
        val packages = pm.getInstalledPackages(0)
        val list = mutableListOf<InstalledAppSummary>()
        for (pkg in packages) {
            val appInfo = pkg.applicationInfo ?: continue
            val isSys = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (!includeSystem && isSys) continue
            val label = runCatching { pm.getApplicationLabel(appInfo).toString() }.getOrDefault(pkg.packageName)
            val apkPath = appInfo.sourceDir ?: ""
            val size = if (apkPath.isNotEmpty()) File(apkPath).length() else 0L
            list.add(
                InstalledAppSummary(
                    appName = label,
                    packageName = pkg.packageName,
                    versionName = pkg.versionName ?: "1.0",
                    apkPath = apkPath,
                    apkSizeBytes = size,
                    isSystemApp = isSys
                )
            )
        }
        list.sortedBy { it.appName.lowercase(Locale.ROOT) }
    }

    suspend fun backupAppApk(app: InstalledAppSummary): Result<File> = withContext(Dispatchers.IO) {
        runCatching {
            val src = File(app.apkPath)
            require(src.exists() && src.canRead()) { "Cannot read base APK at ${app.apkPath}" }
            val backupDir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "WQGlass_APK_Backups"
            ).apply { mkdirs() }
            val safeName = app.appName.replace(Regex("[^a-zA-Z0-9._-]"), "_")
            val dest = ProtocolUtils.uniqueTargetFile(backupDir, "${safeName}_${app.versionName}.apk")
            src.copyTo(dest, overwrite = true)
            AppLogger.info("AppsBackup", "Backed up APK: ${app.appName} → ${dest.absolutePath}")
            dest
        }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
