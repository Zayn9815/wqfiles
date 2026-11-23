package com.wqglass.transfer

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.util.Base64
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Build
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CleaningServices
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FileCopy
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PieChart
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.launch
import java.io.ByteArrayInputStream
import java.io.File
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

@Composable
fun ThemedGlassCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit
) {
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val style by WQThemeEngine.currentStyle.collectAsState()
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(style.cornerRadiusDp.dp),
        colors = CardDefaults.cardColors(containerColor = theme.cardBg),
        border = BorderStroke(style.borderWidthDp.dp, theme.cardBorder)
    ) {
        Box(modifier = Modifier.padding(style.cardPaddingDp.dp)) {
            content()
        }
    }
}

@Composable
fun themedTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = WQThemeEngine.currentTheme.collectAsState().value.textPrimary,
    unfocusedTextColor = WQThemeEngine.currentTheme.collectAsState().value.textPrimary,
    focusedContainerColor = WQThemeEngine.currentTheme.collectAsState().value.inputBg,
    unfocusedContainerColor = WQThemeEngine.currentTheme.collectAsState().value.inputBg,
    focusedBorderColor = WQThemeEngine.currentTheme.collectAsState().value.secondaryAccent,
    unfocusedBorderColor = WQThemeEngine.currentTheme.collectAsState().value.cardBorder,
    focusedLabelColor = WQThemeEngine.currentTheme.collectAsState().value.secondaryAccent,
    unfocusedLabelColor = WQThemeEngine.currentTheme.collectAsState().value.textSecondary
)

// ============================================================================
// 1. LOCAL FILE STUDIO & INSPECTOR (Text, Hex, SQLite, Checksums, ZIP, .wqenc)
// ============================================================================

@Composable
fun LocalFilesStudioScreen(
    onOpenTool: (String) -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val allowDeleting by WQThemeEngine.allowDeleting.collectAsState()
    val showHidden by WQThemeEngine.showHiddenFiles.collectAsState()
    val showCounts by WQThemeEngine.showItemCounts.collectAsState()
    val safeReadOnly by WQThemeEngine.safeReadOnlyMode.collectAsState()

    val primaryRoot = remember { Environment.getExternalStorageDirectory() }
    var currentDir by remember { mutableStateOf(primaryRoot) }
    var files by remember { mutableStateOf<List<File>>(emptyList()) }
    var selectedPaths by remember { mutableStateOf<Set<String>>(emptySet()) }
    var searchQuery by remember { mutableStateOf("") }
    var activeCategory by remember { mutableStateOf("All") }
    var sortMode by remember { mutableIntStateOf(0) } // 0=Name, 1=Size, 2=Newest
    var statusBanner by remember { mutableStateOf("Tap any file to inspect, edit, encrypt (.wqenc), zip, or convert.") }

    var inspectedFile by remember { mutableStateOf<File?>(null) }
    var inspectorMode by remember { mutableStateOf("") } // TEXT, HEX, SQLITE, HASH, CRYPTO, MEDIA
    var showNewFolderDialog by remember { mutableStateOf(false) }
    var showNewFileDialog by remember { mutableStateOf(false) }
    var showGoToPathDialog by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<File?>(null) }

    fun reloadDir(dir: File = currentDir) {
        currentDir = dir
        val raw = dir.listFiles()?.toList() ?: emptyList()
        files = raw.filter { showHidden || !it.name.startsWith(".") }
        selectedPaths = emptySet()
    }

    LaunchedEffect(currentDir, showHidden) {
        reloadDir(currentDir)
    }

    val visibleFiles = remember(files, searchQuery, activeCategory, sortMode) {
        val q = searchQuery.trim()
        val filtered = files.filter { f ->
            val cat = if (f.isDirectory) "Folders" else ProtocolUtils.categorizeFileName(f.name)
            (activeCategory == "All" || cat.equals(activeCategory, ignoreCase = true)) &&
                (q.isEmpty() || f.name.contains(q, ignoreCase = true))
        }
        when (sortMode) {
            1 -> filtered.sortedWith(compareByDescending<File> { it.isDirectory }.thenByDescending { if (it.isDirectory) 0L else it.length() })
            2 -> filtered.sortedWith(compareByDescending<File> { it.isDirectory }.thenByDescending { it.lastModified() })
            else -> filtered.sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase(Locale.ROOT) })
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // Quick Root Bookmarks + Quick Studio Launchers
        ThemedGlassCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("WQ Glass · File Studio", color = theme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                        Text(
                            text = currentDir.absolutePath,
                            color = theme.secondaryAccent,
                            fontSize = 11.5.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    OutlinedButton(
                        onClick = { showGoToPathDialog = true },
                        border = BorderStroke(1.dp, theme.cardBorder)
                    ) {
                        Text("Go to Path…", color = theme.secondaryAccent, fontSize = 11.5.sp)
                    }
                }

                // Quick storage roots
                val roots = remember {
                    listOf(
                        "Internal Storage" to Environment.getExternalStorageDirectory(),
                        "WQGlass Downloads" to WqIdmDownloadEngine.defaultDownloadsDir(),
                        "Downloads" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                        "DCIM / Camera" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
                        "Movies" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
                        "Pictures" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                        "Documents" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
                        "App Sandbox" to context.filesDir
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    roots.forEach { (label, dir) ->
                        FilterChip(
                            selected = currentDir.absolutePath == dir.absolutePath,
                            onClick = { dir.mkdirs(); reloadDir(dir) },
                            label = { Text(label, fontSize = 11.5.sp) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = theme.activePill.copy(alpha = 0.28f),
                                selectedLabelColor = theme.secondaryAccent
                            )
                        )
                    }
                }

                // Toolbar actions
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    OutlinedButton(
                        onClick = { currentDir.parentFile?.let { reloadDir(it) } },
                        enabled = currentDir.parentFile != null,
                        border = BorderStroke(1.dp, theme.cardBorder)
                    ) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null, modifier = Modifier.size(16.dp), tint = theme.secondaryAccent)
                        Spacer(Modifier.width(4.dp))
                        Text("Up", color = theme.textPrimary, fontSize = 12.sp)
                    }

                    OutlinedButton(
                        onClick = { reloadDir(currentDir) },
                        border = BorderStroke(1.dp, theme.cardBorder)
                    ) {
                        Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp), tint = theme.secondaryAccent)
                        Spacer(Modifier.width(4.dp))
                        Text("Refresh", color = theme.textPrimary, fontSize = 12.sp)
                    }

                    if (!safeReadOnly) {
                        OutlinedButton(
                            onClick = { showNewFolderDialog = true },
                            border = BorderStroke(1.dp, theme.cardBorder)
                        ) {
                            Icon(Icons.Default.CreateNewFolder, contentDescription = null, modifier = Modifier.size(16.dp), tint = theme.secondaryAccent)
                            Spacer(Modifier.width(4.dp))
                            Text("+ Folder", color = theme.textPrimary, fontSize = 12.sp)
                        }
                        OutlinedButton(
                            onClick = { showNewFileDialog = true },
                            border = BorderStroke(1.dp, theme.cardBorder)
                        ) {
                            Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(16.dp), tint = theme.secondaryAccent)
                            Spacer(Modifier.width(4.dp))
                            Text("+ Text File", color = theme.textPrimary, fontSize = 12.sp)
                        }
                    }

                    OutlinedButton(
                        onClick = { selectedPaths = visibleFiles.map { it.absolutePath }.toSet() },
                        border = BorderStroke(1.dp, theme.cardBorder)
                    ) { Text("Select All", color = theme.textPrimary, fontSize = 11.5.sp) }

                    if (selectedPaths.isNotEmpty()) {
                        OutlinedButton(
                            onClick = { selectedPaths = emptySet() },
                            border = BorderStroke(1.dp, theme.cardBorder)
                        ) { Text("Deselect (${selectedPaths.size})", color = theme.textSecondary, fontSize = 11.5.sp) }

                        if (!safeReadOnly) {
                            Button(
                                onClick = {
                                    val chosen = visibleFiles.filter { selectedPaths.contains(it.absolutePath) }
                                    if (chosen.isNotEmpty()) {
                                        val zipOut = ProtocolUtils.uniqueTargetFile(currentDir, "Archive_${System.currentTimeMillis()}.zip")
                                        scope.launch {
                                            statusBanner = "Creating ZIP archive (${chosen.size} items)…"
                                            WqCryptoVaultTools.zipFiles(chosen, zipOut)
                                                .onSuccess {
                                                    statusBanner = "Created ${it.name} (${ProtocolUtils.formatBytes(it.length())})"
                                                    reloadDir(currentDir)
                                                }
                                                .onFailure { statusBanner = "ZIP failed: ${it.message}" }
                                        }
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = theme.accent)
                            ) {
                                Icon(Icons.Default.Archive, contentDescription = null, modifier = Modifier.size(15.dp))
                                Spacer(Modifier.width(4.dp))
                                Text("ZIP (${selectedPaths.size})", fontSize = 11.5.sp)
                            }
                        }

                        if (!safeReadOnly && allowDeleting) {
                            Button(
                                onClick = {
                                    val chosen = visibleFiles.filter { selectedPaths.contains(it.absolutePath) }
                                    var deleted = 0
                                    for (f in chosen) {
                                        if (f.deleteRecursively()) deleted++
                                    }
                                    statusBanner = "Deleted $deleted item(s)."
                                    reloadDir(currentDir)
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFDC2626))
                            ) {
                                Text("Delete (${selectedPaths.size})", fontSize = 11.5.sp)
                            }
                        }
                    }
                }

                // Category filter + Search
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    listOf("All", "Folders", "Videos", "Photos", "Audio", "Docs", "Archives").forEach { cat ->
                        FilterChip(
                            selected = activeCategory == cat,
                            onClick = { activeCategory = cat },
                            label = { Text(cat, fontSize = 11.5.sp) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = theme.activePill.copy(alpha = 0.28f),
                                selectedLabelColor = theme.secondaryAccent
                            )
                        )
                    }
                    OutlinedButton(
                        onClick = { sortMode = (sortMode + 1) % 3 },
                        border = BorderStroke(1.dp, theme.cardBorder)
                    ) {
                        val lbl = when (sortMode) { 1 -> "Sort: Size ↓"; 2 -> "Sort: Newest"; else -> "Sort: Name" }
                        Text(lbl, color = theme.secondaryAccent, fontSize = 11.5.sp)
                    }
                }

                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    label = { Text("Search in ${currentDir.name.ifBlank { "/" }} (${visibleFiles.size} items)…", fontSize = 11.5.sp) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = themedTextFieldColors()
                )
            }
        }

        // File List
        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp)
        ) {
            if (visibleFiles.isEmpty()) {
                item {
                    ThemedGlassCard {
                        Text(
                            "Folder is empty (or grant Storage Access in Share / Settings).",
                            color = theme.textSecondary,
                            fontSize = 13.sp
                        )
                    }
                }
            } else {
                items(visibleFiles, key = { it.absolutePath }) { file ->
                    val isChecked = selectedPaths.contains(file.absolutePath)
                    val subText = remember(file, showCounts) {
                        val dateStr = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(Date(file.lastModified()))
                        if (file.isDirectory) {
                            val cnt = if (showCounts) (file.list()?.size ?: 0) else -1
                            if (cnt >= 0) "Folder · $cnt items · $dateStr" else "Folder · $dateStr"
                        } else {
                            "${ProtocolUtils.formatBytes(file.length())} · $dateStr"
                        }
                    }

                    ThemedGlassCard(
                        modifier = Modifier.clickable {
                            if (file.isDirectory) {
                                reloadDir(file)
                            } else {
                                inspectedFile = file
                                inspectorMode = "MENU"
                            }
                        }
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Checkbox(
                                checked = isChecked,
                                onCheckedChange = { chk ->
                                    selectedPaths = if (chk) selectedPaths + file.absolutePath else selectedPaths - file.absolutePath
                                },
                                colors = CheckboxDefaults.colors(checkedColor = theme.accent, checkmarkColor = Color.White)
                            )
                            Icon(
                                imageVector = when {
                                    file.isDirectory -> Icons.Default.Folder
                                    file.name.endsWith(".wqenc", ignoreCase = true) -> Icons.Default.Lock
                                    file.name.endsWith(".zip", ignoreCase = true) -> Icons.Default.Archive
                                    else -> Icons.Default.Description
                                },
                                contentDescription = null,
                                tint = if (file.isDirectory) theme.secondaryAccent else theme.textSecondary
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(file.name, color = theme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(subText, color = theme.textSecondary, fontSize = 11.5.sp)
                            }
                        }
                    }
                }
            }
        }

        Text(statusBanner, color = theme.textSecondary, fontSize = 11.5.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }

    // Inspector & File Studio Action Sheet / Modal
    inspectedFile?.let { file ->
        when (inspectorMode) {
            "MENU" -> {
                AlertDialog(
                    onDismissRequest = { inspectedFile = null },
                    containerColor = theme.cardBg,
                    title = { Text(file.name, color = theme.textPrimary, maxLines = 2, fontSize = 15.sp) },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("Size: ${ProtocolUtils.formatBytes(file.length())}", color = theme.secondaryAccent, fontSize = 12.sp)

                            OutlinedButton(
                                onClick = { inspectorMode = "TEXT" },
                                modifier = Modifier.fillMaxWidth()
                            ) { Text("📝 Text / Code / JSON / XML Editor", color = theme.textPrimary) }

                            OutlinedButton(
                                onClick = { inspectorMode = "HEX" },
                                modifier = Modifier.fillMaxWidth()
                            ) { Text("🔢 Hex Dump Inspector", color = theme.textPrimary) }

                            if (file.name.endsWith(".db", true) || file.name.endsWith(".sqlite", true) || file.name.endsWith(".sqlite3", true)) {
                                OutlinedButton(
                                    onClick = { inspectorMode = "SQLITE" },
                                    modifier = Modifier.fillMaxWidth()
                                ) { Text("🗄️ SQLite Database Table Viewer", color = theme.secondaryAccent) }
                            }

                            OutlinedButton(
                                onClick = { inspectorMode = "HASH" },
                                modifier = Modifier.fillMaxWidth()
                            ) { Text("#️⃣ Calculate MD5 / SHA-1 / SHA-256", color = theme.textPrimary) }

                            if (!safeReadOnly) {
                                OutlinedButton(
                                    onClick = { inspectorMode = "CRYPTO" },
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    val lbl = if (file.name.endsWith(".wqenc", true)) "🔓 Decrypt .wqenc File…" else "🔐 Encrypt to .wqenc Locker…"
                                    Text(lbl, color = theme.secondaryAccent)
                                }

                                if (file.name.endsWith(".zip", true)) {
                                    OutlinedButton(
                                        onClick = {
                                            val targetFile = file
                                            inspectedFile = null
                                            val outDir = File(currentDir, targetFile.nameWithoutExtension)
                                            scope.launch {
                                                statusBanner = "Extracting ${targetFile.name}…"
                                                WqCryptoVaultTools.unzipFile(targetFile, outDir)
                                                    .onSuccess { cnt ->
                                                        statusBanner = "Extracted $cnt file(s) to ${outDir.name}"
                                                        reloadDir(currentDir)
                                                    }
                                                    .onFailure { statusBanner = "Unzip failed: ${it.message}" }
                                            }
                                        },
                                        modifier = Modifier.fillMaxWidth()
                                    ) { Text("📦 Extract ZIP Archive Here", color = theme.secondaryAccent) }
                                } else {
                                    OutlinedButton(
                                        onClick = {
                                            val targetFile = file
                                            inspectedFile = null
                                            val zipOut = ProtocolUtils.uniqueTargetFile(currentDir, "${targetFile.name}.zip")
                                            scope.launch {
                                                WqCryptoVaultTools.zipFiles(listOf(targetFile), zipOut)
                                                    .onSuccess {
                                                        statusBanner = "Created ${it.name}"
                                                        reloadDir(currentDir)
                                                    }
                                            }
                                        },
                                        modifier = Modifier.fillMaxWidth()
                                    ) { Text("📦 Compress to .ZIP", color = theme.textPrimary) }
                                }

                                val ext = file.extension.lowercase(Locale.ROOT)
                                if (ext in listOf("mp4", "mov", "m4v", "mkv", "ts", "webm", "m4a", "aac")) {
                                    OutlinedButton(
                                        onClick = {
                                            val targetFile = file
                                            inspectedFile = null
                                            scope.launch {
                                                statusBanner = "Extracting M4A audio from ${targetFile.name}…"
                                                WqIdmDownloadEngine.remuxOrExtractMedia(targetFile, audioOnlyM4a = true)
                                                    .onSuccess {
                                                        statusBanner = "Saved audio: ${it.name}"
                                                        reloadDir(currentDir)
                                                    }
                                                    .onFailure { statusBanner = "Convert error: ${it.message}" }
                                            }
                                        },
                                        modifier = Modifier.fillMaxWidth()
                                    ) { Text("🎵 Extract Audio (.M4A) / Remux MP4", color = theme.secondaryAccent) }
                                }

                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    OutlinedButton(
                                        onClick = {
                                            renameTarget = file
                                            inspectedFile = null
                                        },
                                        modifier = Modifier.weight(1f)
                                    ) { Text("Rename", color = theme.textPrimary) }

                                    if (allowDeleting) {
                                        OutlinedButton(
                                            onClick = {
                                                val target = file
                                                inspectedFile = null
                                                if (target.delete()) {
                                                    statusBanner = "Deleted ${target.name}"
                                                    reloadDir(currentDir)
                                                }
                                            },
                                            modifier = Modifier.weight(1f),
                                            border = BorderStroke(1.dp, Color(0xFFDC2626))
                                        ) { Text("Delete", color = Color(0xFFFCA5A5)) }
                                    }
                                }
                            }
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = { inspectedFile = null }) { Text("Close", color = theme.secondaryAccent) }
                    }
                )
            }

            "TEXT" -> {
                var content by remember(file) {
                    mutableStateOf(
                        runCatching {
                            file.inputStream().bufferedReader().use { it.readText().take(48_000) }
                        }.getOrDefault("Unable to read file as UTF-8 text.")
                    )
                }
                AlertDialog(
                    onDismissRequest = { inspectedFile = null },
                    containerColor = theme.cardBg,
                    title = { Text("Text / Code Editor · ${file.name}", color = theme.textPrimary, fontSize = 15.sp) },
                    text = {
                        OutlinedTextField(
                            value = content,
                            onValueChange = { if (!safeReadOnly) content = it },
                            modifier = Modifier.fillMaxWidth().height(340.dp),
                            colors = themedTextFieldColors()
                        )
                    },
                    confirmButton = {
                        if (!safeReadOnly) {
                            TextButton(onClick = {
                                runCatching { file.writeText(content) }
                                    .onSuccess {
                                        statusBanner = "Saved ${file.name}"
                                        reloadDir(currentDir)
                                    }
                                    .onFailure { statusBanner = "Save failed: ${it.message}" }
                                inspectedFile = null
                            }) { Text("Save", color = theme.secondaryAccent) }
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { inspectedFile = null }) { Text("Close", color = theme.textSecondary) }
                    }
                )
            }

            "HEX" -> {
                val hexDump = remember(file) { runCatching { WqCryptoVaultTools.formatHexPreview(file, 4096) }.getOrDefault("Cannot read bytes.") }
                AlertDialog(
                    onDismissRequest = { inspectedFile = null },
                    containerColor = theme.cardBg,
                    title = { Text("Hex Viewer (First 4 KB) · ${file.name}", color = theme.textPrimary, fontSize = 14.5.sp) },
                    text = {
                        LazyColumn(modifier = Modifier.height(340.dp)) {
                            item {
                                Text(hexDump, color = theme.secondaryAccent, fontSize = 10.5.sp, fontFamily = FontFamily.Monospace)
                            }
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = { inspectedFile = null }) { Text("Close", color = theme.secondaryAccent) }
                    }
                )
            }

            "SQLITE" -> {
                val sqliteRes = remember(file) { WqCryptoVaultTools.inspectSqliteTables(file) }
                AlertDialog(
                    onDismissRequest = { inspectedFile = null },
                    containerColor = theme.cardBg,
                    title = { Text("SQLite Viewer · ${file.name}", color = theme.textPrimary, fontSize = 15.sp) },
                    text = {
                        LazyColumn(modifier = Modifier.height(340.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            sqliteRes.onSuccess { (tables, rowsByTable) ->
                                item {
                                    Text("Tables (${tables.size}): ${tables.joinToString(", ")}", color = theme.secondaryAccent, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                }
                                rowsByTable.forEach { (table, rows) ->
                                    item {
                                        Text("▼ Table: $table (${(rows.size - 1).coerceAtLeast(0)} rows shown)", color = theme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.5.sp)
                                        rows.take(15).forEach { r ->
                                            Text(r.joinToString(" | "), color = theme.textSecondary, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                                        }
                                    }
                                }
                            }.onFailure { err ->
                                item { Text("SQLite open error: ${err.message}", color = Color(0xFFFCA5A5)) }
                            }
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = { inspectedFile = null }) { Text("Close", color = theme.secondaryAccent) }
                    }
                )
            }

            "HASH" -> {
                var hashes by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
                LaunchedEffect(file) {
                    hashes = runCatching { WqCryptoVaultTools.computeFileHashes(file) }.getOrDefault(emptyMap())
                }
                AlertDialog(
                    onDismissRequest = { inspectedFile = null },
                    containerColor = theme.cardBg,
                    title = { Text("Checksums · ${file.name}", color = theme.textPrimary, fontSize = 15.sp) },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (hashes.isEmpty()) {
                                Text("Computing MD5, SHA-1 & SHA-256…", color = theme.secondaryAccent)
                            } else {
                                hashes.forEach { (algo, hex) ->
                                    Text(algo, color = theme.secondaryAccent, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                                    Text(hex, color = theme.textPrimary, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
                                }
                            }
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("Hashes", hashes.entries.joinToString("\n") { "${it.key}: ${it.value}" }))
                            Toast.makeText(context, "Copied checksums", Toast.LENGTH_SHORT).show()
                            inspectedFile = null
                        }) { Text("Copy All", color = theme.secondaryAccent) }
                    },
                    dismissButton = {
                        TextButton(onClick = { inspectedFile = null }) { Text("Close", color = theme.textSecondary) }
                    }
                )
            }

            "CRYPTO" -> {
                val isEncrypted = file.name.endsWith(".wqenc", ignoreCase = true)
                var password by remember { mutableStateOf("") }
                AlertDialog(
                    onDismissRequest = { inspectedFile = null },
                    containerColor = theme.cardBg,
                    title = {
                        Text(
                            if (isEncrypted) "Decrypt .wqenc File" else "Encrypt File to .wqenc (AES-256 + HMAC)",
                            color = theme.textPrimary,
                            fontSize = 15.sp
                        )
                    },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                "Compatible with WQ Glass on iPhone and Android.",
                                color = theme.textSecondary,
                                fontSize = 12.sp
                            )
                            OutlinedTextField(
                                value = password,
                                onValueChange = { password = it },
                                label = { Text("Password") },
                                singleLine = true,
                                colors = themedTextFieldColors()
                            )
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            val pass = password
                            val target = file
                            inspectedFile = null
                            if (pass.isNotEmpty()) {
                                scope.launch {
                                    val res = if (isEncrypted) {
                                        WqCryptoVaultTools.decryptWqEncFile(target, pass)
                                    } else {
                                        WqCryptoVaultTools.encryptFileToWqEnc(target, pass)
                                    }
                                    res.onSuccess { out ->
                                        statusBanner = "Saved ${out.name} (${ProtocolUtils.formatBytes(out.length())})"
                                        reloadDir(currentDir)
                                    }.onFailure { err ->
                                        statusBanner = "Crypto error: ${err.message}"
                                        Toast.makeText(context, err.message ?: "Crypto failed", Toast.LENGTH_LONG).show()
                                    }
                                }
                            }
                        }) { Text(if (isEncrypted) "Decrypt" else "Encrypt", color = theme.secondaryAccent) }
                    },
                    dismissButton = {
                        TextButton(onClick = { inspectedFile = null }) { Text("Cancel", color = theme.textSecondary) }
                    }
                )
            }
        }
    }

    if (showNewFolderDialog) {
        var name by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showNewFolderDialog = false },
            containerColor = theme.cardBg,
            title = { Text("Create New Folder", color = theme.textPrimary) },
            text = { OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Folder name") }, singleLine = true, colors = themedTextFieldColors()) },
            confirmButton = {
                TextButton(onClick = {
                    val clean = name.trim()
                    showNewFolderDialog = false
                    if (clean.isNotEmpty()) {
                        File(currentDir, clean).mkdirs()
                        reloadDir(currentDir)
                    }
                }) { Text("Create", color = theme.secondaryAccent) }
            },
            dismissButton = { TextButton(onClick = { showNewFolderDialog = false }) { Text("Cancel", color = theme.textSecondary) } }
        )
    }

    if (showNewFileDialog) {
        var name by remember { mutableStateOf("notes.txt") }
        var body by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showNewFileDialog = false },
            containerColor = theme.cardBg,
            title = { Text("New Text / Code File", color = theme.textPrimary) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("File name") }, singleLine = true, colors = themedTextFieldColors())
                    OutlinedTextField(value = body, onValueChange = { body = it }, label = { Text("Contents") }, modifier = Modifier.height(140.dp), colors = themedTextFieldColors())
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    val clean = name.trim()
                    showNewFileDialog = false
                    if (clean.isNotEmpty()) {
                        runCatching { File(currentDir, clean).writeText(body) }
                        reloadDir(currentDir)
                    }
                }) { Text("Create", color = theme.secondaryAccent) }
            },
            dismissButton = { TextButton(onClick = { showNewFileDialog = false }) { Text("Cancel", color = theme.textSecondary) } }
        )
    }

    if (showGoToPathDialog) {
        var pathInput by remember { mutableStateOf(currentDir.absolutePath) }
        AlertDialog(
            onDismissRequest = { showGoToPathDialog = false },
            containerColor = theme.cardBg,
            title = { Text("Go to Path", color = theme.textPrimary) },
            text = { OutlinedTextField(value = pathInput, onValueChange = { pathInput = it }, label = { Text("Directory path") }, singleLine = true, colors = themedTextFieldColors()) },
            confirmButton = {
                TextButton(onClick = {
                    showGoToPathDialog = false
                    val f = File(pathInput.trim())
                    if (f.exists() && f.isDirectory) reloadDir(f)
                    else Toast.makeText(context, "Directory does not exist", Toast.LENGTH_SHORT).show()
                }) { Text("Go", color = theme.secondaryAccent) }
            },
            dismissButton = { TextButton(onClick = { showGoToPathDialog = false }) { Text("Cancel", color = theme.textSecondary) } }
        )
    }

    renameTarget?.let { target ->
        var newName by remember { mutableStateOf(target.name) }
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            containerColor = theme.cardBg,
            title = { Text("Rename", color = theme.textPrimary) },
            text = { OutlinedTextField(value = newName, onValueChange = { newName = it }, singleLine = true, colors = themedTextFieldColors()) },
            confirmButton = {
                TextButton(onClick = {
                    val clean = newName.trim()
                    renameTarget = null
                    if (clean.isNotEmpty() && clean != target.name) {
                        target.renameTo(File(target.parentFile, clean))
                        reloadDir(currentDir)
                    }
                }) { Text("Rename", color = theme.secondaryAccent) }
            },
            dismissButton = { TextButton(onClick = { renameTarget = null }) { Text("Cancel", color = theme.textSecondary) } }
        )
    }
}

// ============================================================================
// 2. IDM BROWSER + MEDIA GRABBER + MULTI-PART DOWNLOAD MANAGER
// ============================================================================

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun IdmAndBrowserStudioScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val tasks by WqIdmDownloadEngine.tasks.collectAsState()
    val defaultParts by WqIdmDownloadEngine.defaultParts.collectAsState()

    var subTab by remember { mutableIntStateOf(0) } // 0 = IDM Queue, 1 = 1DM Ad-Block Browser & Sniffer
    var newUrl by remember { mutableStateOf("") }
    var customName by remember { mutableStateOf("") }
    var selectedParts by remember { mutableIntStateOf(defaultParts) }

    // Browser state
    var browserUrlInput by remember { mutableStateOf("https://") }
    var activeWebUrl by remember { mutableStateOf("https://en.m.wikipedia.org") }
    var adBlockEnabled by remember { mutableStateOf(true) }
    val sniffedMediaLinks = remember { mutableStateListOf<String>() }

    val adHosts = remember {
        setOf("doubleclick.net", "googlesyndication.com", "googleadservices.com", "adnxs.com", "taboola.com", "outbrain.com", "popads.net")
    }
    val mediaRegex = remember {
        Regex(".*\\.(mp4|m3u8|mkv|webm|mov|mp3|m4a|flac|wav|zip|rar|7z|apk|ipa|pdf)(\\?.*)?$", RegexOption.IGNORE_CASE)
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // Sub-mode switcher
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
            Button(
                onClick = { subTab = 0 },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = if (subTab == 0) theme.accent else theme.cardElevated)
            ) {
                Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(6.dp))
                Text("IDM Queue (${tasks.size})", fontSize = 12.5.sp)
            }
            Button(
                onClick = { subTab = 1 },
                modifier = Modifier.weight(1f),
                colors = ButtonDefaults.buttonColors(containerColor = if (subTab == 1) theme.accent else theme.cardElevated)
            ) {
                Icon(Icons.Default.Language, contentDescription = null, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(6.dp))
                Text("1DM Browser (${sniffedMediaLinks.size})", fontSize = 12.5.sp)
            }
        }

        if (subTab == 0) {
            // Add IDM Multi-Part Download Card
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("IDM Multi-Part Accelerator & HLS (.m3u8) Grabber", color = theme.textPrimary, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                    OutlinedTextField(
                        value = newUrl,
                        onValueChange = { newUrl = it },
                        label = { Text("Direct File or .m3u8 Stream URL", fontSize = 11.5.sp) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = themedTextFieldColors()
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = customName,
                            onValueChange = { customName = it },
                            label = { Text("Filename (optional)", fontSize = 11.sp) },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                            colors = themedTextFieldColors()
                        )
                        Button(
                            onClick = {
                                if (newUrl.isBlank()) {
                                    Toast.makeText(context, "Paste a URL to download", Toast.LENGTH_SHORT).show()
                                } else {
                                    val url = if (!newUrl.startsWith("http://", true) && !newUrl.startsWith("https://", true)) "https://$newUrl" else newUrl
                                    WqIdmDownloadEngine.enqueueDownload(url, customName, selectedParts)
                                    newUrl = ""
                                    customName = ""
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = theme.accent)
                        ) {
                            Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Start")
                        }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text("Parallel Parts:", color = theme.textSecondary, fontSize = 11.5.sp)
                        listOf(1, 2, 4, 8, 16).forEach { parts ->
                            FilterChip(
                                selected = selectedParts == parts,
                                onClick = {
                                    selectedParts = parts
                                    WqIdmDownloadEngine.setDefaultParts(parts)
                                },
                                label = { Text("${parts}x", fontSize = 11.5.sp) },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = theme.activePill.copy(alpha = 0.3f),
                                    selectedLabelColor = theme.secondaryAccent
                                )
                            )
                        }
                        if (tasks.any { it.status == DownloadStatus.COMPLETED }) {
                            TextButton(onClick = { WqIdmDownloadEngine.clearCompleted() }) {
                                Text("Clear Done", color = theme.secondaryAccent, fontSize = 11.5.sp)
                            }
                        }
                    }
                }
            }

            // Active & Completed Downloads List
            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (tasks.isEmpty()) {
                    item {
                        ThemedGlassCard {
                            Text(
                                "No downloads yet. Paste any file or HLS (.m3u8) URL above, or switch to the 1DM Browser tab to auto-sniff videos and media links from web pages.",
                                color = theme.textSecondary,
                                fontSize = 12.5.sp
                            )
                        }
                    }
                } else {
                    items(tasks, key = { it.id }) { t ->
                        ThemedGlassCard {
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(t.fileName, color = theme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        val statusLine = when (t.status) {
                                            DownloadStatus.DOWNLOADING -> "${t.partsCount}x parts · ${ProtocolUtils.formatBytes(t.downloadedBytes)} / ${ProtocolUtils.formatBytes(t.totalBytes)} · ${ProtocolUtils.formatSpeed(t.speedBytesPerSec)} · ETA ${t.etaText}"
                                            DownloadStatus.COMPLETED -> "✓ Completed · ${ProtocolUtils.formatBytes(t.totalBytes)} · Saved to Downloads/WQGlass"
                                            DownloadStatus.PAUSED -> "⏸ Paused · ${ProtocolUtils.formatBytes(t.downloadedBytes)} / ${ProtocolUtils.formatBytes(t.totalBytes)}"
                                            DownloadStatus.FAILED -> "✕ Failed: ${t.errorText ?: "Error"}"
                                            else -> "Queued…"
                                        }
                                        Text(statusLine, color = if (t.status == DownloadStatus.COMPLETED) Color(0xFF4ADE80) else theme.secondaryAccent, fontSize = 11.5.sp)
                                    }

                                    Row {
                                        if (t.status == DownloadStatus.DOWNLOADING) {
                                            IconButton(onClick = { WqIdmDownloadEngine.pauseTask(t.id) }) {
                                                Icon(Icons.Default.Pause, contentDescription = "Pause", tint = Color(0xFFFBBF24))
                                            }
                                        } else if (t.status == DownloadStatus.PAUSED || t.status == DownloadStatus.FAILED) {
                                            IconButton(onClick = { WqIdmDownloadEngine.resumeTask(t.id) }) {
                                                Icon(Icons.Default.PlayArrow, contentDescription = "Resume", tint = Color(0xFF4ADE80))
                                            }
                                        }
                                        if (t.status == DownloadStatus.COMPLETED &&
                                            (t.fileName.endsWith(".mp4", true) || t.fileName.endsWith(".ts", true) || t.fileName.endsWith(".mkv", true))
                                        ) {
                                            IconButton(onClick = {
                                                scope.launch {
                                                    WqIdmDownloadEngine.remuxOrExtractMedia(File(t.destinationPath), audioOnlyM4a = true)
                                                        .onSuccess { out -> Toast.makeText(context, "Extracted audio: ${out.name}", Toast.LENGTH_SHORT).show() }
                                                        .onFailure { err -> Toast.makeText(context, "Convert failed: ${err.message}", Toast.LENGTH_SHORT).show() }
                                                }
                                            }) {
                                                Icon(Icons.Default.Movie, contentDescription = "Extract Audio M4A", tint = theme.secondaryAccent)
                                            }
                                        }
                                        IconButton(onClick = { WqIdmDownloadEngine.cancelAndRemoveTask(t.id) }) {
                                            Icon(Icons.Default.Close, contentDescription = "Remove", tint = Color(0xFFF87171))
                                        }
                                    }
                                }

                                if (t.status == DownloadStatus.DOWNLOADING || t.status == DownloadStatus.PAUSED) {
                                    LinearProgressIndicator(
                                        progress = { t.progressFraction },
                                        modifier = Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(4.dp)),
                                        color = theme.secondaryAccent,
                                        trackColor = theme.inputBg
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // 1DM Ad-Block Browser & Media Sniffer
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = browserUrlInput,
                            onValueChange = { browserUrlInput = it },
                            label = { Text("Enter URL or search…", fontSize = 11.sp) },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                            colors = themedTextFieldColors()
                        )
                        Button(
                            onClick = {
                                val raw = browserUrlInput.trim()
                                activeWebUrl = when {
                                    raw.startsWith("http://", true) || raw.startsWith("https://", true) -> raw
                                    raw.contains('.') && !raw.contains(' ') -> "https://$raw"
                                    else -> "https://duckduckgo.com/?q=${ProtocolUtils.urlEncode(raw)}"
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = theme.accent)
                        ) { Text("Go") }
                    }

                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Switch(checked = adBlockEnabled, onCheckedChange = { adBlockEnabled = it })
                            Text(if (adBlockEnabled) "🛡️ Ad-Block Active" else "Ad-Block Off", color = theme.secondaryAccent, fontSize = 11.5.sp)
                        }
                        if (sniffedMediaLinks.isNotEmpty()) {
                            TextButton(onClick = { sniffedMediaLinks.clear() }) {
                                Text("Clear Sniffed (${sniffedMediaLinks.size})", color = theme.textSecondary, fontSize = 11.5.sp)
                            }
                        }
                    }
                }
            }

            if (sniffedMediaLinks.isNotEmpty()) {
                ThemedGlassCard {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("🎥 Sniffed Media & Downloadable Links (${sniffedMediaLinks.size})", color = Color(0xFF4ADE80), fontWeight = FontWeight.Bold, fontSize = 12.5.sp)
                        LazyColumn(modifier = Modifier.height(110.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            items(sniffedMediaLinks) { mediaUrl ->
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        mediaUrl.substringAfterLast('/').substringBefore('?').ifBlank { mediaUrl },
                                        color = theme.textPrimary,
                                        fontSize = 11.5.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f)
                                    )
                                    TextButton(onClick = {
                                        WqIdmDownloadEngine.enqueueDownload(mediaUrl)
                                        Toast.makeText(context, "Added to IDM Queue!", Toast.LENGTH_SHORT).show()
                                        subTab = 0
                                    }) {
                                        Text("⬇ Grab", color = theme.secondaryAccent, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Card(
                modifier = Modifier.weight(1f).fillMaxWidth(),
                shape = RoundedCornerShape(14.dp),
                border = BorderStroke(1.dp, theme.cardBorder)
            ) {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        WebView(ctx).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            settings.mediaPlaybackRequiresUserGesture = false
                            webViewClient = object : WebViewClient() {
                                override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                                    val reqUrl = request?.url?.toString() ?: return null
                                    val host = request.url?.host?.lowercase(Locale.ROOT) ?: ""
                                    if (adBlockEnabled && adHosts.any { host == it || host.endsWith(".$it") }) {
                                        return WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                                    }
                                    if (mediaRegex.matches(reqUrl) && !sniffedMediaLinks.contains(reqUrl)) {
                                        view?.post {
                                            if (!sniffedMediaLinks.contains(reqUrl)) {
                                                sniffedMediaLinks.add(0, reqUrl)
                                            }
                                        }
                                    }
                                    return super.shouldInterceptRequest(view, request)
                                }
                            }
                            setDownloadListener { url, userAgent, _, _, _ ->
                                WqIdmDownloadEngine.enqueueDownload(url, userAgent = userAgent)
                                Toast.makeText(ctx, "Intercepted download → IDM Queue", Toast.LENGTH_SHORT).show()
                            }
                            loadUrl(activeWebUrl)
                        }
                    },
                    update = { webView ->
                        if (webView.url != activeWebUrl) {
                            webView.loadUrl(activeWebUrl)
                        }
                    }
                )
            }
        }
    }
}

// ============================================================================
// 3. UNIFIED SUPER-UTILITY HUB & APPEARANCE / THEME STUDIO
// ============================================================================

@Composable
fun UtilityHubStudioScreen(
    activeSubScreen: String,
    onSelectSubScreen: (String) -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val style by WQThemeEngine.currentStyle.collectAsState()
    val allowDeleting by WQThemeEngine.allowDeleting.collectAsState()
    val showHidden by WQThemeEngine.showHiddenFiles.collectAsState()
    val showCounts by WQThemeEngine.showItemCounts.collectAsState()
    val safeReadOnly by WQThemeEngine.safeReadOnlyMode.collectAsState()

    if (activeSubScreen.isNotEmpty()) {
        Column(modifier = Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedButton(
                    onClick = { onSelectSubScreen("") },
                    border = BorderStroke(1.dp, theme.cardBorder)
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null, modifier = Modifier.size(16.dp), tint = theme.secondaryAccent)
                    Spacer(Modifier.width(6.dp))
                    Text("Back to Utility Hub", color = theme.textPrimary, fontSize = 12.5.sp)
                }
            }

            when (activeSubScreen) {
                "VAULT" -> PrivateVaultSubScreen()
                "STORAGE" -> StorageAnalyzerSubScreen()
                "DUPLICATES" -> DuplicateFinderSubScreen()
                "CLEANER" -> CacheCleanerSubScreen()
                "APPS" -> InstalledAppsBackupSubScreen()
                "WORKBENCH" -> EverydayWorkbenchSubScreen()
                "LOGS" -> LogsScreen()
            }
        }
        return
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("WQ Glass · All-in-One Android Super-Utility", color = theme.textPrimary, fontSize = 17.5.sp, fontWeight = FontWeight.Bold)
                    Text(
                        "100% offline · 5 live Liquid Glass themes · Multi-part IDM · AES-256 Vault · PC/iPhone Transfer",
                        color = theme.secondaryAccent,
                        fontSize = 12.sp
                    )
                }
            }
        }

        // Studio Tools Grid
        val hubTools = listOf(
            Triple("VAULT", "🔐 Private Encrypted Vault & .wqenc Locker", "PIN-protected AES-256-CBC + HMAC encrypted vault files & secure notes"),
            Triple("STORAGE", "📊 DaisyDisk Storage Analyzer", "Visual category breakdown & top 30 largest files across Internal Storage"),
            Triple("DUPLICATES", "🧬 SHA-256 Duplicate File Finder", "Find and clean byte-identical duplicate files wasting storage"),
            Triple("CLEANER", "✨ Cache & Junk Cleaner", "Clean app caches, .tmp/.log remnants, and empty 0-byte files"),
            Triple("APPS", "📦 Installed Apps & APK Backup Manager", "Inspect all installed Android apps & back up their base .APK to Downloads"),
            Triple("WORKBENCH", "🛠️ Everyday Utility Workbench", "QR Generator, Password & UUID Generator, Base64/Hex/URL/Epoch Converter & Scratchpad"),
            Triple("LOGS", "🐞 Diagnostic, Error & Crash Reports", "Inspect, filter, copy, or share session logs and uncaught crash stack traces")
        )

        items(hubTools) { (id, title, desc) ->
            ThemedGlassCard(modifier = Modifier.clickable { onSelectSubScreen(id) }) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(title, color = theme.textPrimary, fontSize = 14.5.sp, fontWeight = FontWeight.Bold)
                    Text(desc, color = theme.textSecondary, fontSize = 12.sp)
                }
            }
        }

        // Appearance & Theme Studio (All 5 iOS WQ Glass Themes!)
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("🎨 Appearance & Theme Studio (Live Switch)", color = theme.textPrimary, fontSize = 15.5.sp, fontWeight = FontWeight.Bold)
                    Text("Identical 5 color themes from WQ Glass on iOS — switches live with zero restart.", color = theme.textSecondary, fontSize = 11.5.sp)

                    WQThemeEngine.allThemes.forEach { tSpec ->
                        val active = tSpec.id == theme.id
                        Card(
                            modifier = Modifier.fillMaxWidth().clickable { WQThemeEngine.selectTheme(context, tSpec.id) },
                            shape = RoundedCornerShape(12.dp),
                            colors = CardDefaults.cardColors(containerColor = tSpec.cardBg),
                            border = BorderStroke(if (active) 2.dp else 1.dp, if (active) tSpec.accent else tSpec.cardBorder)
                        ) {
                            Row(
                                modifier = Modifier.padding(10.dp).fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(tSpec.title, color = tSpec.textPrimary, fontWeight = FontWeight.Bold, fontSize = 13.5.sp)
                                    Text(tSpec.subtitle, color = tSpec.textSecondary, fontSize = 11.sp)
                                }
                                if (active) {
                                    Icon(Icons.Default.CheckCircle, contentDescription = null, tint = tSpec.accent)
                                }
                            }
                        }
                    }
                }
            }
        }

        // UI Layout & Chrome Presets (All 3 iOS Presets!)
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("📐 UI Layout & Chrome Preset", color = theme.textPrimary, fontSize = 15.5.sp, fontWeight = FontWeight.Bold)
                    WQThemeEngine.allStyles.forEach { sSpec ->
                        val active = sSpec.id == style.id
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { WQThemeEngine.selectStyle(context, sSpec.id) }
                                .padding(vertical = 4.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(sSpec.title, color = theme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp)
                                Text(sSpec.subtitle, color = theme.textSecondary, fontSize = 11.5.sp)
                            }
                            if (active) {
                                Icon(Icons.Default.CheckCircle, contentDescription = null, tint = theme.accent)
                            }
                        }
                    }
                }
            }
        }

        // Global WQ Glass Safety & File Preferences
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("⚙️ Safety & File Studio Preferences", color = theme.textPrimary, fontSize = 15.5.sp, fontWeight = FontWeight.Bold)

                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Safe Read-Only Mode", color = theme.textPrimary, fontSize = 13.5.sp, fontWeight = FontWeight.Medium)
                            Text("Disables file modifications, folder creation, and deletions", color = theme.textSecondary, fontSize = 11.sp)
                        }
                        Switch(checked = safeReadOnly, onCheckedChange = { WQThemeEngine.setSafeReadOnlyMode(context, it) })
                    }

                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Allow Deleting", color = theme.textPrimary, fontSize = 13.5.sp, fontWeight = FontWeight.Medium)
                            Text("When off, hides Delete actions in File Studio and Cache Cleaner", color = theme.textSecondary, fontSize = 11.sp)
                        }
                        Switch(checked = allowDeleting, onCheckedChange = { WQThemeEngine.setAllowDeleting(context, it) })
                    }

                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Show Hidden Dotfiles (.file)", color = theme.textPrimary, fontSize = 13.5.sp, fontWeight = FontWeight.Medium)
                            Text("Include files and folders starting with '.'", color = theme.textSecondary, fontSize = 11.sp)
                        }
                        Switch(checked = showHidden, onCheckedChange = { WQThemeEngine.setShowHiddenFiles(context, it) })
                    }

                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Show Folder Item Counts", color = theme.textPrimary, fontSize = 13.5.sp, fontWeight = FontWeight.Medium)
                            Text("Counts children inside each listed subfolder", color = theme.textSecondary, fontSize = 11.sp)
                        }
                        Switch(checked = showCounts, onCheckedChange = { WQThemeEngine.setShowItemCounts(context, it) })
                    }
                }
            }
        }
    }
}

// ============================================================================
// SUB-SCREENS FOR UTILITY HUB
// ============================================================================

@Composable
private fun PrivateVaultSubScreen() {
    val context = LocalContext.current
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val prefs = remember { context.getSharedPreferences("wqglass_vault", Context.MODE_PRIVATE) }
    var savedPin by remember { mutableStateOf(prefs.getString("vault_pin", "") ?: "") }
    var unlocked by remember { mutableStateOf(false) }
    var pinInput by remember { mutableStateOf("") }
    var noteTitle by remember { mutableStateOf("") }
    var noteBody by remember { mutableStateOf("") }

    val vaultDir = remember { File(context.filesDir, "private_vault").apply { mkdirs() } }
    var vaultFiles by remember { mutableStateOf<List<File>>(emptyList()) }
    var decryptedPreview by remember { mutableStateOf<Pair<String, String>?>(null) }

    fun refreshVault() {
        vaultFiles = vaultDir.listFiles()?.toList()?.sortedByDescending { it.lastModified() } ?: emptyList()
    }

    if (!unlocked) {
        ThemedGlassCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    if (savedPin.isEmpty()) "🔐 Create Private AES-256 Vault Passcode" else "🔐 Unlock Private AES-256 Vault",
                    color = theme.textPrimary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    "All notes and files in the vault are encrypted with AES-256-CBC + HMAC-SHA256.",
                    color = theme.textSecondary,
                    fontSize = 12.sp
                )
                OutlinedTextField(
                    value = pinInput,
                    onValueChange = { pinInput = it },
                    label = { Text("Vault Passcode (4+ chars)") },
                    singleLine = true,
                    colors = themedTextFieldColors()
                )
                Button(
                    onClick = {
                        if (pinInput.length < 4) {
                            Toast.makeText(context, "Enter at least 4 characters", Toast.LENGTH_SHORT).show()
                        } else if (savedPin.isEmpty()) {
                            prefs.edit().putString("vault_pin", pinInput).apply()
                            savedPin = pinInput
                            unlocked = true
                            refreshVault()
                        } else if (pinInput == savedPin) {
                            unlocked = true
                            refreshVault()
                        } else {
                            Toast.makeText(context, "Incorrect vault passcode", Toast.LENGTH_SHORT).show()
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = theme.accent)
                ) {
                    Text(if (savedPin.isEmpty()) "Set Passcode & Open Vault" else "Unlock Vault")
                }
            }
        }
        return
    }

    Column(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ThemedGlassCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Add Encrypted Note to Vault", color = theme.textPrimary, fontWeight = FontWeight.Bold, fontSize = 14.5.sp)
                OutlinedTextField(
                    value = noteTitle,
                    onValueChange = { noteTitle = it },
                    label = { Text("Note title", fontSize = 11.5.sp) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = themedTextFieldColors()
                )
                OutlinedTextField(
                    value = noteBody,
                    onValueChange = { noteBody = it },
                    label = { Text("Secret note content…", fontSize = 11.5.sp) },
                    modifier = Modifier.fillMaxWidth().height(90.dp),
                    colors = themedTextFieldColors()
                )
                Button(
                    onClick = {
                        if (noteTitle.isNotBlank() && noteBody.isNotBlank()) {
                            val safe = noteTitle.trim().replace(Regex("[^a-zA-Z0-9._-]"), "_")
                            val out = File(vaultDir, "$safe.wqenc")
                            val enc = WqCryptoVaultTools.encryptBytes(noteBody.toByteArray(Charsets.UTF_8), savedPin)
                            out.writeBytes(enc)
                            noteTitle = ""
                            noteBody = ""
                            refreshVault()
                            Toast.makeText(context, "Encrypted & saved to Vault", Toast.LENGTH_SHORT).show()
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = theme.accent)
                ) { Text("Encrypt & Save to Vault") }
            }
        }

        LazyColumn(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(vaultFiles) { vf ->
                ThemedGlassCard(
                    modifier = Modifier.clickable {
                        runCatching {
                            val plain = WqCryptoVaultTools.decryptBytes(vf.readBytes(), savedPin).toString(Charsets.UTF_8)
                            decryptedPreview = vf.name to plain
                        }.onFailure {
                            Toast.makeText(context, "Decrypt error: ${it.message}", Toast.LENGTH_SHORT).show()
                        }
                    }
                ) {
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("🔒 ${vf.name}", color = theme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp)
                            Text("${ProtocolUtils.formatBytes(vf.length())} · Tap to decrypt & view", color = theme.secondaryAccent, fontSize = 11.5.sp)
                        }
                        IconButton(onClick = { vf.delete(); refreshVault() }) {
                            Icon(Icons.Default.Delete, contentDescription = null, tint = Color(0xFFF87171))
                        }
                    }
                }
            }
        }
    }

    decryptedPreview?.let { (title, text) ->
        AlertDialog(
            onDismissRequest = { decryptedPreview = null },
            containerColor = theme.cardBg,
            title = { Text(title, color = theme.textPrimary) },
            text = { Text(text, color = theme.secondaryAccent, fontFamily = FontFamily.Monospace) },
            confirmButton = {
                TextButton(onClick = { decryptedPreview = null }) { Text("Close", color = theme.secondaryAccent) }
            }
        )
    }
}

@Composable
private fun StorageAnalyzerSubScreen() {
    val theme by WQThemeEngine.currentTheme.collectAsState()
    var categories by remember { mutableStateOf<List<StorageCategorySummary>>(emptyList()) }
    var largestFiles by remember { mutableStateOf<List<File>>(emptyList()) }
    var scanning by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        scanning = true
        val (cats, top) = WqCryptoVaultTools.analyzeStorageRoot(Environment.getExternalStorageDirectory())
        categories = cats
        largestFiles = top
        scanning = false
    }

    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    val root = Environment.getExternalStorageDirectory()
                    val total = root.totalSpace
                    val free = root.usableSpace
                    val used = (total - free).coerceAtLeast(0L)
                    Text("📊 Storage Breakdown", color = theme.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Text(
                        "Used: ${ProtocolUtils.formatBytes(used)} / ${ProtocolUtils.formatBytes(total)} (${ProtocolUtils.formatBytes(free)} free)",
                        color = theme.secondaryAccent,
                        fontSize = 12.5.sp
                    )
                    if (scanning) {
                        Text("Scanning storage categories…", color = theme.textSecondary, fontSize = 12.sp)
                    }
                }
            }
        }

        items(categories) { cat ->
            ThemedGlassCard {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("${cat.category} (${cat.count} files)", color = theme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp)
                    Text(ProtocolUtils.formatBytes(cat.bytes), color = theme.secondaryAccent, fontWeight = FontWeight.Bold, fontSize = 13.5.sp)
                }
            }
        }

        if (largestFiles.isNotEmpty()) {
            item {
                Text("Largest Files on Device", color = theme.secondaryAccent, fontWeight = FontWeight.Bold, fontSize = 13.5.sp)
            }
            items(largestFiles) { f ->
                ThemedGlassCard {
                    Column {
                        Text(f.name, color = theme.textPrimary, fontWeight = FontWeight.Medium, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text("${ProtocolUtils.formatBytes(f.length())} · ${f.parentFile?.name ?: ""}", color = theme.textSecondary, fontSize = 11.5.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun DuplicateFinderSubScreen() {
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val scope = rememberCoroutineScope()
    var groups by remember { mutableStateOf<List<DuplicateGroupItem>>(emptyList()) }
    var scanning by remember { mutableStateOf(true) }

    fun rescan() {
        scope.launch {
            scanning = true
            groups = WqCryptoVaultTools.findDuplicateFiles(Environment.getExternalStorageDirectory())
            scanning = false
        }
    }

    LaunchedEffect(Unit) { rescan() }

    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("🧬 SHA-256 Duplicate File Finder", color = theme.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Text(
                        if (scanning) "Scanning storage for byte-identical duplicate files…"
                        else "Found ${groups.size} duplicate group(s)",
                        color = theme.secondaryAccent,
                        fontSize = 12.sp
                    )
                }
            }
        }

        items(groups) { g ->
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        "SHA-256: ${g.sha256}… · ${ProtocolUtils.formatBytes(g.sizeBytes)} each (${g.files.size} copies)",
                        color = theme.secondaryAccent,
                        fontWeight = FontWeight.Bold,
                        fontSize = 12.sp
                    )
                    g.files.forEachIndexed { idx, file ->
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "${if (idx == 0) "[Keep] " else ""}${file.absolutePath}",
                                color = theme.textPrimary,
                                fontSize = 11.5.sp,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            if (idx > 0) {
                                TextButton(onClick = {
                                    file.delete()
                                    rescan()
                                }) {
                                    Text("Delete Copy", color = Color(0xFFF87171), fontSize = 11.5.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CacheCleanerSubScreen() {
    val context = LocalContext.current
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val allowDeleting by WQThemeEngine.allowDeleting.collectAsState()
    val scope = rememberCoroutineScope()
    var junkFiles by remember { mutableStateOf<List<File>>(emptyList()) }
    var scanning by remember { mutableStateOf(true) }
    var status by remember { mutableStateOf("") }

    fun rescan() {
        scope.launch {
            scanning = true
            junkFiles = WqCryptoVaultTools.scanCleanableJunk(context)
            scanning = false
        }
    }

    LaunchedEffect(Unit) { rescan() }

    val totalBytes = remember(junkFiles) { junkFiles.sumOf { WqCryptoVaultTools.calculateSizeRecursive(it) } }

    Column(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ThemedGlassCard {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("✨ Cache & Junk Cleaner", color = theme.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Text(
                        if (scanning) "Scanning cache & temporary files…"
                        else "${junkFiles.size} item(s) · ${ProtocolUtils.formatBytes(totalBytes)} reclaimable",
                        color = theme.secondaryAccent,
                        fontSize = 12.sp
                    )
                    if (status.isNotEmpty()) Text(status, color = Color(0xFF4ADE80), fontSize = 11.5.sp)
                }
                if (allowDeleting && junkFiles.isNotEmpty()) {
                    Button(
                        onClick = {
                            var freed = 0L
                            var count = 0
                            junkFiles.forEach { f ->
                                val sz = WqCryptoVaultTools.calculateSizeRecursive(f)
                                if (f.deleteRecursively()) {
                                    freed += sz
                                    count++
                                }
                            }
                            status = "Cleaned $count item(s), freed ${ProtocolUtils.formatBytes(freed)}!"
                            rescan()
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = theme.accent)
                    ) { Text("Clean All") }
                }
            }
        }

        LazyColumn(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(junkFiles) { f ->
                ThemedGlassCard {
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(f.name, color = theme.textPrimary, fontWeight = FontWeight.Medium, fontSize = 13.sp)
                            Text(f.absolutePath, color = theme.textSecondary, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Text(ProtocolUtils.formatBytes(WqCryptoVaultTools.calculateSizeRecursive(f)), color = theme.secondaryAccent, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

@Composable
private fun InstalledAppsBackupSubScreen() {
    val context = LocalContext.current
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val scope = rememberCoroutineScope()
    var apps by remember { mutableStateOf<List<InstalledAppSummary>>(emptyList()) }
    var includeSystem by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("Tap Backup APK on any app to save its installer to Downloads/WQGlass_APK_Backups.") }

    LaunchedEffect(includeSystem) {
        apps = WqCryptoVaultTools.listInstalledApps(context, includeSystem)
    }

    val filtered = remember(apps, search) {
        val q = search.trim()
        if (q.isEmpty()) apps
        else apps.filter { it.appName.contains(q, true) || it.packageName.contains(q, true) }
    }

    Column(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ThemedGlassCard {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text("📦 Installed Apps (${filtered.size})", color = theme.textPrimary, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("System", color = theme.textSecondary, fontSize = 11.5.sp)
                        Switch(checked = includeSystem, onCheckedChange = { includeSystem = it })
                    }
                }
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    label = { Text("Search apps or package ID…", fontSize = 11.5.sp) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = themedTextFieldColors()
                )
                Text(status, color = theme.secondaryAccent, fontSize = 11.5.sp)
            }
        }

        LazyColumn(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(filtered, key = { it.packageName }) { app ->
                ThemedGlassCard {
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(app.appName, color = theme.textPrimary, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp)
                            Text("${app.packageName} · v${app.versionName} · ${ProtocolUtils.formatBytes(app.apkSizeBytes)}", color = theme.textSecondary, fontSize = 11.5.sp)
                        }
                        OutlinedButton(
                            onClick = {
                                scope.launch {
                                    WqCryptoVaultTools.backupAppApk(app)
                                        .onSuccess { out ->
                                            status = "✓ Saved ${out.name} to Downloads/WQGlass_APK_Backups"
                                            Toast.makeText(context, status, Toast.LENGTH_SHORT).show()
                                        }
                                        .onFailure { err ->
                                            status = "Backup error: ${err.message}"
                                        }
                                }
                            },
                            border = BorderStroke(1.dp, theme.secondaryAccent)
                        ) {
                            Text("Backup APK", color = theme.secondaryAccent, fontSize = 11.5.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EverydayWorkbenchSubScreen() {
    val context = LocalContext.current
    val theme by WQThemeEngine.currentTheme.collectAsState()
    val prefs = remember { context.getSharedPreferences("wqglass_workbench", Context.MODE_PRIVATE) }

    var qrInput by remember { mutableStateOf("https://github.com/Zayn9815/wqfiles") }
    val qrBmp = remember(qrInput) { if (qrInput.isNotBlank()) QrHelper.generateQrBitmap(qrInput, 360) else null }

    var generatedPassword by remember { mutableStateOf(generateStrongPassword(20)) }
    var generatedUuid by remember { mutableStateOf(UUID.randomUUID().toString()) }

    var converterInput by remember { mutableStateOf("") }
    var converterOutput by remember { mutableStateOf("") }

    var scratchpad by remember { mutableStateOf(prefs.getString("scratchpad_text", "") ?: "") }

    LazyColumn(modifier = Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // QR Studio
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("QR Code Generator Studio", color = theme.textPrimary, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                    OutlinedTextField(
                        value = qrInput,
                        onValueChange = { qrInput = it },
                        label = { Text("Text, URL, or Wi-Fi credentials") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = themedTextFieldColors()
                    )
                    if (qrBmp != null) {
                        Image(bitmap = qrBmp.asImageBitmap(), contentDescription = "QR", modifier = Modifier.size(160.dp))
                    }
                }
            }
        }

        // Password & UUID Generator
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Cryptographic Password & UUID v4 Generator", color = theme.textPrimary, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                    Text(generatedPassword, color = theme.secondaryAccent, fontFamily = FontFamily.Monospace, fontSize = 13.5.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { generatedPassword = generateStrongPassword(20) }, colors = ButtonDefaults.buttonColors(containerColor = theme.accent)) {
                            Text("New 20-Char Password", fontSize = 12.sp)
                        }
                        OutlinedButton(onClick = {
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("Password", generatedPassword))
                            Toast.makeText(context, "Copied password", Toast.LENGTH_SHORT).show()
                        }) { Text("Copy", color = theme.textPrimary, fontSize = 12.sp) }
                    }

                    Text("UUID: $generatedUuid", color = theme.textSecondary, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { generatedUuid = UUID.randomUUID().toString() }) { Text("New UUID", color = theme.textPrimary, fontSize = 12.sp) }
                        OutlinedButton(onClick = {
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("UUID", generatedUuid))
                            Toast.makeText(context, "Copied UUID", Toast.LENGTH_SHORT).show()
                        }) { Text("Copy UUID", color = theme.textPrimary, fontSize = 12.sp) }
                    }
                }
            }
        }

        // Dev Converters (Base64, Hex, URL, Epoch)
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Developer Encoder / Decoder (Base64 · Hex · URL)", color = theme.textPrimary, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                    OutlinedTextField(
                        value = converterInput,
                        onValueChange = { converterInput = it },
                        label = { Text("Input string") },
                        modifier = Modifier.fillMaxWidth(),
                        colors = themedTextFieldColors()
                    )
                    Row(modifier = Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        OutlinedButton(onClick = {
                            converterOutput = Base64.encodeToString(converterInput.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
                        }) { Text("Base64 Enc", color = theme.secondaryAccent, fontSize = 11.5.sp) }

                        OutlinedButton(onClick = {
                            converterOutput = runCatching { String(Base64.decode(converterInput.trim(), Base64.DEFAULT), Charsets.UTF_8) }.getOrDefault("Invalid Base64")
                        }) { Text("Base64 Dec", color = theme.secondaryAccent, fontSize = 11.5.sp) }

                        OutlinedButton(onClick = {
                            converterOutput = converterInput.toByteArray(Charsets.UTF_8).joinToString("") { "%02x".format(it) }
                        }) { Text("To Hex", color = theme.secondaryAccent, fontSize = 11.5.sp) }

                        OutlinedButton(onClick = {
                            converterOutput = ProtocolUtils.urlEncode(converterInput)
                        }) { Text("URL Enc", color = theme.secondaryAccent, fontSize = 11.5.sp) }
                    }
                    if (converterOutput.isNotEmpty()) {
                        Text(converterOutput, color = theme.secondaryAccent, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
                    }
                }
            }
        }

        // Persistent Scratchpad
        item {
            ThemedGlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Persistent Quick Scratchpad", color = theme.textPrimary, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                    OutlinedTextField(
                        value = scratchpad,
                        onValueChange = {
                            scratchpad = it
                            prefs.edit().putString("scratchpad_text", it).apply()
                        },
                        label = { Text("Auto-saved notes, commands & snippets…") },
                        modifier = Modifier.fillMaxWidth().height(140.dp),
                        colors = themedTextFieldColors()
                    )
                }
            }
        }
    }
}

private fun generateStrongPassword(length: Int): String {
    val chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*()-_=+"
    val rng = SecureRandom()
    return (1..length).map { chars[rng.nextInt(chars.length)] }.joinToString("")
}
