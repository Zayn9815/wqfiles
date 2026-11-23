package com.wqglass.transfer

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
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
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.DriveFolderUpload
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Wifi
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val BgCanvas = Color(0xFF070D19)
private val CardBg = Color(0xFF101B30)
private val CardElevated = Color(0xFF15233E)
private val CardBorder = Color(0xFF223556)
private val InputBg = Color(0xFF091020)
private val TextPrimary = Color(0xFFF8FAFC)
private val TextSecondary = Color(0xFF94A3B8)
private val AccentBlue = Color(0xFF2563EB)
private val AccentCyan = Color(0xFF38BDF8)
private val AccentEmerald = Color(0xFF059669)
private val SuccessGreen = Color(0xFF4ADE80)
private val WarnAmber = Color(0xFFFBBF24)
private val DangerRed = Color(0xFFDC2626)

class MainActivity : ComponentActivity() {
    private lateinit var discovery: DiscoveryService

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        discovery = DiscoveryService(this) {
            TransferForegroundService.server.currentPort()
        }
        discovery.start()

        setContent {
            MaterialTheme(
                colorScheme = darkColorScheme(
                    primary = AccentBlue,
                    secondary = AccentCyan,
                    background = BgCanvas,
                    surface = CardBg,
                    onBackground = TextPrimary,
                    onSurface = TextPrimary,
                    error = DangerRed
                )
            ) {
                WQGlassTransferApp(discovery = discovery)
            }
        }
    }

    override fun onDestroy() {
        discovery.close()
        super.onDestroy()
    }
}

private fun hasFullStorageAccess(context: Context): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        Environment.isExternalStorageManager()
    } else {
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }
}

private fun openStorageAccessSettings(context: Context) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        try {
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                data = Uri.parse("package:${context.packageName}")
            }
            context.startActivity(intent)
        } catch (_: Exception) {
            context.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        }
    }
}

@Composable
private fun WQGlassTransferApp(discovery: DiscoveryService) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("wqglass_transfer", Context.MODE_PRIVATE) }
    var selectedTab by remember { mutableIntStateOf(0) }
    val hostState by TransferForegroundService.server.state.collectAsState()
    val history = remember { mutableStateListOf<TransferHistoryItem>() }

    val notifPermLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    val legacyStorageLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {}

    fun recordHistory(dir: String, name: String, bytes: Long, bps: Double, status: String) {
        val ts = SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
        history.add(0, TransferHistoryItem(ts, dir, name, bytes, bps, status))
        if (history.size > 120) history.removeAt(history.lastIndex)
    }

    Scaffold(
        containerColor = BgCanvas,
        bottomBar = {
            NavigationBar(containerColor = CardBg) {
                NavigationBarItem(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    icon = { Icon(Icons.Default.Wifi, contentDescription = null) },
                    label = { Text("Connect") }
                )
                NavigationBarItem(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    icon = { Icon(Icons.Default.Upload, contentDescription = null) },
                    label = { Text(if (hostState.isRunning) "Share · Live" else "Share Device") }
                )
                NavigationBarItem(
                    selected = selectedTab == 2,
                    onClick = { selectedTab = 2 },
                    icon = { Icon(Icons.Default.History, contentDescription = null) },
                    label = { Text("History (${history.size})") }
                )
            }
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(BgCanvas)
        ) {
            when (selectedTab) {
                0 -> ClientScreen(
                    discovery = discovery,
                    prefs = prefs,
                    onRecordHistory = ::recordHistory
                )
                1 -> HostScreen(
                    prefs = prefs,
                    onRequestRuntimePermissions = {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            notifPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                        }
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                            legacyStorageLauncher.launch(
                                arrayOf(
                                    Manifest.permission.READ_EXTERNAL_STORAGE,
                                    Manifest.permission.WRITE_EXTERNAL_STORAGE
                                )
                            )
                        }
                    }
                )
                else -> HistoryScreen(
                    history = history,
                    onClear = { history.clear() }
                )
            }
        }
    }
}

@Composable
private fun ClientScreen(
    discovery: DiscoveryService,
    prefs: android.content.SharedPreferences,
    onRecordHistory: (String, String, Long, Double, String) -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val peers by discovery.peers.collectAsState()

    var endpoint by remember { mutableStateOf(prefs.getString("last_endpoint", "") ?: "") }
    var pin by remember { mutableStateOf(prefs.getString("last_pin", "") ?: "") }
    var client by remember { mutableStateOf<TransferClient?>(null) }
    var remoteInfo by remember { mutableStateOf<RemoteInfo?>(null) }
    var currentPath by remember { mutableStateOf("") }
    var allItems by remember { mutableStateOf<List<RemoteFileItem>>(emptyList()) }
    var selectedPaths by remember { mutableStateOf<Set<String>>(emptySet()) }
    var activeCategory by remember { mutableStateOf("All") }
    var searchQuery by remember { mutableStateOf("") }
    var sortMode by remember { mutableIntStateOf(0) } // 0=Name, 1=Size, 2=Newest
    var statusText by remember { mutableStateOf("Scan QR, tap a Wi-Fi device, or enter IP:Port & PIN.") }
    var progress by remember { mutableStateOf<TransferProgress?>(null) }
    var activeJob by remember { mutableStateOf<Job?>(null) }

    var showNewFolderDialog by remember { mutableStateOf(false) }
    var showSendTextDialog by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<RemoteFileItem?>(null) }
    var deleteTargets by remember { mutableStateOf<List<RemoteFileItem>>(emptyList()) }
    var actionTarget by remember { mutableStateOf<RemoteFileItem?>(null) }

    val visibleItems = remember(allItems, activeCategory, searchQuery, sortMode) {
        val q = searchQuery.trim()
        val filtered = allItems.filter { item ->
            (activeCategory == "All" || item.category.equals(activeCategory, ignoreCase = true)) &&
                (q.isEmpty() || item.name.contains(q, ignoreCase = true))
        }
        when (sortMode) {
            1 -> filtered.sortedWith(compareByDescending<RemoteFileItem> { it.isDir }.thenByDescending { it.size })
            2 -> filtered.sortedWith(compareByDescending<RemoteFileItem> { it.isDir }.thenByDescending { it.mtime })
            else -> filtered.sortedWith(compareByDescending<RemoteFileItem> { it.isDir }.thenBy { it.name.lowercase(Locale.ROOT) })
        }
    }

    fun resolveLocalDownloadDir(): File {
        val publicDl = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val preferred = File(publicDl, "WQGlass")
        if (preferred.exists() || preferred.mkdirs()) return preferred
        val fallback = File(context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: context.filesDir, "WQGlass")
        fallback.mkdirs()
        return fallback
    }

    fun refreshList(activeClient: TransferClient?, path: String) {
        if (activeClient == null) return
        scope.launch {
            try {
                allItems = activeClient.list(path)
                selectedPaths = emptySet()
                statusText = "/${remoteInfo?.root ?: "Shared"}${if (path.isEmpty()) "" else "/$path"} (${allItems.size} items)"
            } catch (e: Exception) {
                statusText = "List error: ${e.message}"
            }
        }
    }

    fun doConnect(ep: String, p: String) {
        val cleanEp = ep.trim()
        val cleanPin = p.trim()
        if (cleanEp.isEmpty() || cleanPin.length < 4) {
            Toast.makeText(context, "Enter a valid IP:Port and 4–8 digit PIN", Toast.LENGTH_SHORT).show()
            return
        }
        statusText = "Connecting to $cleanEp…"
        scope.launch {
            try {
                val c = TransferClient(cleanEp, cleanPin)
                val info = c.getInfo()
                prefs.edit().putString("last_endpoint", cleanEp).putString("last_pin", cleanPin).apply()
                client = c
                remoteInfo = info
                currentPath = ""
                activeCategory = "All"
                searchQuery = ""
                refreshList(c, "")
            } catch (e: Exception) {
                statusText = "Connection failed: ${e.message}"
                Toast.makeText(context, e.message ?: "Could not connect", Toast.LENGTH_LONG).show()
            }
        }
    }

    fun handleQrString(raw: String) {
        val parsed = ProtocolUtils.parseQrPayload(raw)
        if (parsed != null) {
            endpoint = parsed.endpoint
            if (!parsed.pin.isNullOrBlank()) {
                pin = parsed.pin
                doConnect(parsed.endpoint, parsed.pin)
            } else {
                statusText = "Scanned ${parsed.endpoint} — enter PIN and tap Connect."
            }
        } else {
            Toast.makeText(context, "Unrecognized WQGlass QR code", Toast.LENGTH_SHORT).show()
        }
    }

    val qrCameraLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let { handleQrString(it) }
    }

    val qrImagePicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        val decoded = QrHelper.decodeQrFromUri(context.contentResolver, uri)
        if (!decoded.isNullOrBlank()) handleQrString(decoded)
        else Toast.makeText(context, "No readable QR code found in image", Toast.LENGTH_SHORT).show()
    }

    val uploadFilesPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        val activeClient = client ?: return@rememberLauncherForActivityResult
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        activeJob?.cancel()
        activeJob = scope.launch {
            val startNs = System.nanoTime()
            var totalBytes = 0L
            try {
                uris.forEachIndexed { idx, uri ->
                    val fStart = System.nanoTime()
                    val (name, sent) = activeClient.uploadUri(
                        context = context,
                        uri = uri,
                        remoteDir = currentPath,
                        fileIndex = idx + 1,
                        fileCount = uris.size
                    ) { p -> progress = p }
                    totalBytes += sent
                    val sec = ((System.nanoTime() - fStart) / 1e9).coerceAtLeast(0.01)
                    onRecordHistory("↑", name, sent, sent / sec, "Completed")
                }
                progress = null
                val totalSec = ((System.nanoTime() - startNs) / 1e9).coerceAtLeast(0.01)
                statusText = "Sent ${uris.size} file(s) (${ProtocolUtils.formatBytes(totalBytes)}) at ${ProtocolUtils.formatSpeed(totalBytes / totalSec)}!"
                refreshList(activeClient, currentPath)
            } catch (_: CancellationException) {
                progress = null
                statusText = "Upload cancelled."
            } catch (e: Exception) {
                progress = null
                statusText = "Upload failed: ${e.message}"
                Toast.makeText(context, e.message ?: "Upload failed", Toast.LENGTH_LONG).show()
            }
        }
    }

    val uploadFolderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { treeUri: Uri? ->
        val activeClient = client ?: return@rememberLauncherForActivityResult
        if (treeUri == null) return@rememberLauncherForActivityResult
        activeJob?.cancel()
        activeJob = scope.launch {
            val startNs = System.nanoTime()
            var totalBytes = 0L
            try {
                statusText = "Scanning selected folder…"
                val jobs = activeClient.collectTreeUploads(context, treeUri, currentPath)
                if (jobs.isEmpty()) {
                    statusText = "Selected folder contains no files."
                    return@launch
                }
                jobs.forEachIndexed { idx, (uri, remoteDir, name) ->
                    val fStart = System.nanoTime()
                    val (uploadedName, sent) = activeClient.uploadUri(
                        context = context,
                        uri = uri,
                        remoteDir = remoteDir,
                        overrideName = name,
                        fileIndex = idx + 1,
                        fileCount = jobs.size
                    ) { p -> progress = p }
                    totalBytes += sent
                    val sec = ((System.nanoTime() - fStart) / 1e9).coerceAtLeast(0.01)
                    onRecordHistory("↑", uploadedName, sent, sent / sec, "Completed")
                }
                progress = null
                val totalSec = ((System.nanoTime() - startNs) / 1e9).coerceAtLeast(0.01)
                statusText = "Uploaded folder (${jobs.size} files, ${ProtocolUtils.formatBytes(totalBytes)}) at ${ProtocolUtils.formatSpeed(totalBytes / totalSec)}!"
                refreshList(activeClient, currentPath)
            } catch (_: CancellationException) {
                progress = null
                statusText = "Folder upload cancelled."
            } catch (e: Exception) {
                progress = null
                statusText = "Folder upload failed: ${e.message}"
                Toast.makeText(context, e.message ?: "Folder upload failed", Toast.LENGTH_LONG).show()
            }
        }
    }

    fun downloadItems(targets: List<RemoteFileItem>) {
        val activeClient = client ?: return
        if (targets.isEmpty()) return
        activeJob?.cancel()
        activeJob = scope.launch {
            val startNs = System.nanoTime()
            var totalBytes = 0L
            try {
                statusText = "Preparing download list…"
                val destDir = resolveLocalDownloadDir()
                val jobs = activeClient.collectRemoteDownloads(targets, destDir)
                if (jobs.isEmpty()) {
                    statusText = "Selected folder(s) contain no files."
                    return@launch
                }
                jobs.forEachIndexed { idx, (remotePath, localDir, fileName) ->
                    val fStart = System.nanoTime()
                    val (savedFile, received) = activeClient.downloadFile(
                        remotePath = remotePath,
                        destinationDir = localDir,
                        fileName = fileName,
                        fileIndex = idx + 1,
                        fileCount = jobs.size
                    ) { p -> progress = p }
                    totalBytes += received
                    val sec = ((System.nanoTime() - fStart) / 1e9).coerceAtLeast(0.01)
                    onRecordHistory("↓", savedFile.name, received, received / sec, "Completed")
                }
                progress = null
                val totalSec = ((System.nanoTime() - startNs) / 1e9).coerceAtLeast(0.01)
                statusText = "Saved ${jobs.size} file(s) (${ProtocolUtils.formatBytes(totalBytes)}) at ${ProtocolUtils.formatSpeed(totalBytes / totalSec)} → Downloads/WQGlass"
                Toast.makeText(context, "Saved ${jobs.size} file(s) to Downloads/WQGlass", Toast.LENGTH_SHORT).show()
            } catch (_: CancellationException) {
                progress = null
                statusText = "Download cancelled."
            } catch (e: Exception) {
                progress = null
                statusText = "Download failed: ${e.message}"
                Toast.makeText(context, e.message ?: "Download failed", Toast.LENGTH_LONG).show()
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // Brand & Connection Header Card
        GlassCard {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Image(
                        painter = painterResource(id = R.drawable.wq_brand_logo),
                        contentDescription = "WQGlass Logo",
                        modifier = Modifier.size(38.dp).clip(RoundedCornerShape(10.dp))
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = if (remoteInfo != null) "${remoteInfo!!.device} · ${remoteInfo!!.osSummary}" else "WQGlass Transfer",
                            color = TextPrimary,
                            fontSize = 16.5.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = if (remoteInfo != null) {
                                "Free: ${ProtocolUtils.formatBytes(remoteInfo!!.freeBytes)} / ${ProtocolUtils.formatBytes(remoteInfo!!.totalBytes)}"
                            } else {
                                "v2.0 · High-Speed iPhone · Android · PC"
                            },
                            color = if (remoteInfo != null) SuccessGreen else AccentCyan,
                            fontSize = 11.5.sp
                        )
                    }
                    if (client != null) {
                        OutlinedButton(
                            onClick = {
                                activeJob?.cancel()
                                client = null
                                remoteInfo = null
                                allItems = emptyList()
                                selectedPaths = emptySet()
                                currentPath = ""
                                progress = null
                                statusText = "Disconnected."
                            },
                            border = BorderStroke(1.dp, DangerRed)
                        ) {
                            Text("Disconnect", color = Color(0xFFFCA5A5), fontSize = 12.sp)
                        }
                    }
                }

                if (remoteInfo != null && remoteInfo!!.totalBytes > 0L) {
                    LinearProgressIndicator(
                        progress = { remoteInfo!!.usedFraction },
                        modifier = Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(3.dp)),
                        color = AccentCyan,
                        trackColor = InputBg
                    )
                }
            }
        }

        if (client == null) {
            // Quick QR Connect Bar (Camera + Gallery Image)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                Button(
                    onClick = {
                        val opts = ScanOptions().apply {
                            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                            setPrompt("Scan WQGlass QR code on PC, iPhone, or Android")
                            setBeepEnabled(false)
                            setOrientationLocked(false)
                        }
                        qrCameraLauncher.launch(opts)
                    },
                    modifier = Modifier.weight(1.3f),
                    colors = ButtonDefaults.buttonColors(containerColor = AccentEmerald)
                ) {
                    Icon(Icons.Default.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Scan QR Code", fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
                OutlinedButton(
                    onClick = { qrImagePicker.launch("image/*") },
                    modifier = Modifier.weight(1f),
                    border = BorderStroke(1.dp, CardBorder)
                ) {
                    Icon(Icons.Default.Image, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(5.dp))
                    Text("QR Image", color = TextPrimary, fontSize = 12.5.sp)
                }
            }

            // Manual Connection Card
            GlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        OutlinedTextField(
                            value = endpoint,
                            onValueChange = { endpoint = it },
                            label = { Text("IP:Port (192.168.1.x:8765)", fontSize = 11.sp) },
                            singleLine = true,
                            modifier = Modifier.weight(1.7f),
                            colors = glassTextFieldColors()
                        )
                        OutlinedTextField(
                            value = pin,
                            onValueChange = { if (it.length <= 8) pin = it },
                            label = { Text("PIN", fontSize = 11.sp) },
                            singleLine = true,
                            modifier = Modifier.weight(0.95f),
                            colors = glassTextFieldColors()
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        Button(
                            onClick = { doConnect(endpoint, pin) },
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.buttonColors(containerColor = AccentBlue)
                        ) { Text("Connect") }
                        OutlinedButton(
                            onClick = {
                                discovery.sendProbeNow()
                                statusText = "Scanning Wi-Fi for Windows PC, iPhone & Android…"
                            },
                            border = BorderStroke(1.dp, CardBorder)
                        ) {
                            Icon(Icons.Default.Refresh, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(17.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Scan", color = TextPrimary)
                        }
                    }
                }
            }

            Text(
                text = "Auto-Discovered Wi-Fi Devices (${peers.size})",
                color = TextSecondary,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 4.dp)
            )

            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (peers.isEmpty()) {
                    item {
                        GlassCard {
                            Text(
                                text = "Scanning LAN (UDP 45888)…\nOpen WQGlass Transfer on Windows PC (Share This PC), iPhone (WQ Glass), or another Android phone on the same Wi-Fi.",
                                color = TextSecondary,
                                fontSize = 12.5.sp
                            )
                        }
                    }
                } else {
                    items(peers, key = { it.endpoint }) { peer ->
                        GlassCard(
                            modifier = Modifier.clickable {
                                endpoint = peer.endpoint
                                if (pin.length >= 4) doConnect(peer.endpoint, pin)
                                else statusText = "Selected ${peer.device}. Enter PIN above and tap Connect."
                            }
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("${peer.platformEmoji} ${peer.device}", color = TextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                                    Text(
                                        text = "${peer.platformBadge}${if (peer.osVersion.isNotBlank()) " ${peer.osVersion}" else ""} · ${peer.endpoint} · /${peer.root}",
                                        color = TextSecondary,
                                        fontSize = 11.5.sp
                                    )
                                }
                                Text("Connect →", color = AccentCyan, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
        } else {
            // Connected Remote Explorer Actions
            GlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Button(
                            onClick = { uploadFilesPicker.launch(arrayOf("*/*")) },
                            colors = ButtonDefaults.buttonColors(containerColor = AccentBlue)
                        ) {
                            Icon(Icons.Default.Upload, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Send Files", fontSize = 12.sp)
                        }
                        Button(
                            onClick = { uploadFolderPicker.launch(null) },
                            colors = ButtonDefaults.buttonColors(containerColor = CardElevated)
                        ) {
                            Icon(Icons.Default.DriveFolderUpload, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Send Folder", fontSize = 12.sp)
                        }
                        val chosen = visibleItems.filter { selectedPaths.contains(it.path) }
                        Button(
                            enabled = chosen.isNotEmpty(),
                            onClick = { downloadItems(chosen) },
                            colors = ButtonDefaults.buttonColors(containerColor = AccentEmerald)
                        ) {
                            Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Download (${chosen.size})", fontSize = 12.sp)
                        }
                        OutlinedButton(
                            onClick = { showNewFolderDialog = true },
                            border = BorderStroke(1.dp, CardBorder)
                        ) {
                            Icon(Icons.Default.CreateNewFolder, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(16.dp))
                        }
                        OutlinedButton(
                            onClick = { showSendTextDialog = true },
                            border = BorderStroke(1.dp, CardBorder)
                        ) {
                            Icon(Icons.Default.Send, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(16.dp))
                        }
                        if (chosen.isNotEmpty()) {
                            OutlinedButton(
                                onClick = { deleteTargets = chosen },
                                border = BorderStroke(1.dp, DangerRed)
                            ) {
                                Icon(Icons.Default.Delete, contentDescription = null, tint = DangerRed, modifier = Modifier.size(16.dp))
                            }
                        }
                    }

                    // Select All / Deselect / Invert + Selection Summary + Up/Refresh/Sort
                    Row(
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(
                            enabled = currentPath.isNotEmpty(),
                            onClick = {
                                val idx = currentPath.lastIndexOf('/')
                                currentPath = if (idx > 0) currentPath.substring(0, idx) else ""
                                refreshList(client, currentPath)
                            },
                            modifier = Modifier.size(34.dp)
                        ) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Up", tint = if (currentPath.isNotEmpty()) AccentCyan else TextSecondary)
                        }
                        IconButton(onClick = { refreshList(client, currentPath) }, modifier = Modifier.size(34.dp)) {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = AccentCyan)
                        }
                        TextButton(onClick = { selectedPaths = visibleItems.map { it.path }.toSet() }) {
                            Icon(Icons.Default.CheckBox, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(15.dp))
                            Spacer(Modifier.width(3.dp))
                            Text("All", color = TextPrimary, fontSize = 12.sp)
                        }
                        TextButton(onClick = { selectedPaths = emptySet() }) {
                            Icon(Icons.Default.CheckBoxOutlineBlank, contentDescription = null, tint = TextSecondary, modifier = Modifier.size(15.dp))
                            Spacer(Modifier.width(3.dp))
                            Text("None", color = TextSecondary, fontSize = 12.sp)
                        }
                        TextButton(onClick = {
                            val all = visibleItems.map { it.path }.toSet()
                            selectedPaths = all - selectedPaths
                        }) {
                            Icon(Icons.Default.SwapHoriz, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(15.dp))
                            Spacer(Modifier.width(3.dp))
                            Text("Invert", color = TextPrimary, fontSize = 12.sp)
                        }
                        TextButton(onClick = { sortMode = (sortMode + 1) % 3 }) {
                            val lbl = when (sortMode) { 1 -> "Sort: Size"; 2 -> "Sort: Date"; else -> "Sort: Name" }
                            Text(lbl, color = AccentCyan, fontSize = 12.sp)
                        }
                    }

                    // Category filter chips
                    Row(
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        listOf("All", "Folders", "Videos", "Photos", "Audio", "Docs", "Archives").forEach { cat ->
                            FilterChip(
                                selected = activeCategory == cat,
                                onClick = { activeCategory = cat },
                                label = { Text(cat, fontSize = 11.5.sp) },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = Color(0xFF1B3A6B),
                                    selectedLabelColor = AccentCyan
                                )
                            )
                        }
                    }

                    OutlinedTextField(
                        value = searchQuery,
                        onValueChange = { searchQuery = it },
                        placeholder = { Text("Search current folder…", fontSize = 12.sp, color = TextSecondary) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        colors = glassTextFieldColors()
                    )
                }
            }

            // Active Transfer Progress Dock
            progress?.let { p ->
                GlassCard {
                    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "${p.verb} (${p.fileIndex}/${p.fileCount}): ${p.fileName}",
                                color = TextPrimary,
                                fontSize = 12.5.sp,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f)
                            )
                            IconButton(onClick = { activeJob?.cancel() }, modifier = Modifier.size(28.dp)) {
                                Icon(Icons.Default.Close, contentDescription = "Cancel", tint = DangerRed)
                            }
                        }
                        LinearProgressIndicator(
                            progress = { p.fraction },
                            modifier = Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(4.dp)),
                            color = AccentCyan,
                            trackColor = InputBg
                        )
                        Text(
                            text = "${ProtocolUtils.formatBytes(p.transferredBytes)} / ${ProtocolUtils.formatBytes(p.totalBytes)} · ${ProtocolUtils.formatSpeed(p.bytesPerSec)} · ETA ${p.etaText}",
                            color = AccentCyan,
                            fontSize = 11.5.sp
                        )
                    }
                }
            }

            // File Explorer List
            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (visibleItems.isEmpty()) {
                    item {
                        GlassCard {
                            Text("No matching files or folders here.", color = TextSecondary, fontSize = 13.sp)
                        }
                    }
                } else {
                    items(visibleItems, key = { it.path }) { item ->
                        val isChecked = selectedPaths.contains(item.path)
                        GlassCard(
                            modifier = Modifier.clickable {
                                if (item.isDir) {
                                    currentPath = item.path
                                    refreshList(client, currentPath)
                                } else {
                                    actionTarget = item
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
                                    onCheckedChange = { checked ->
                                        selectedPaths = if (checked) selectedPaths + item.path else selectedPaths - item.path
                                    },
                                    colors = CheckboxDefaults.colors(checkedColor = AccentBlue, checkmarkColor = Color.White)
                                )
                                Icon(
                                    imageVector = if (item.isDir) Icons.Default.Folder else Icons.Default.Description,
                                    contentDescription = null,
                                    tint = if (item.isDir) AccentCyan else TextSecondary
                                )
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(item.name, color = TextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(if (item.isDir) "Folder" else ProtocolUtils.formatBytes(item.size), color = TextSecondary, fontSize = 11.5.sp)
                                }
                                IconButton(onClick = { downloadItems(listOf(item)) }) {
                                    Icon(Icons.Default.Download, contentDescription = "Download", tint = AccentCyan)
                                }
                            }
                        }
                    }
                }
            }
        }

        Text(text = statusText, color = TextSecondary, fontSize = 11.5.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }

    // File Action Dialog
    actionTarget?.let { item ->
        AlertDialog(
            onDismissRequest = { actionTarget = null },
            containerColor = CardBg,
            title = { Text(item.name, color = TextPrimary, maxLines = 2) },
            text = { Text("Size: ${ProtocolUtils.formatBytes(item.size)}", color = TextSecondary) },
            confirmButton = {
                TextButton(onClick = {
                    actionTarget = null
                    downloadItems(listOf(item))
                }) { Text("Download", color = AccentCyan) }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { actionTarget = null; renameTarget = item }) { Text("Rename", color = TextPrimary) }
                    TextButton(onClick = { actionTarget = null; deleteTargets = listOf(item) }) { Text("Delete", color = DangerRed) }
                }
            }
        )
    }

    if (showNewFolderDialog) {
        var name by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showNewFolderDialog = false },
            containerColor = CardBg,
            title = { Text("Create Remote Folder", color = TextPrimary) },
            text = { OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Folder name") }, singleLine = true, colors = glassTextFieldColors()) },
            confirmButton = {
                TextButton(onClick = {
                    val clean = name.trim()
                    showNewFolderDialog = false
                    if (clean.isNotEmpty() && client != null) {
                        val target = if (currentPath.isEmpty()) clean else "$currentPath/$clean"
                        scope.launch {
                            try { client!!.createFolder(target); refreshList(client, currentPath) }
                            catch (e: Exception) { statusText = "Create folder failed: ${e.message}" }
                        }
                    }
                }) { Text("Create", color = AccentCyan) }
            },
            dismissButton = { TextButton(onClick = { showNewFolderDialog = false }) { Text("Cancel", color = TextSecondary) } }
        )
    }

    if (showSendTextDialog) {
        var text by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showSendTextDialog = false },
            containerColor = CardBg,
            title = { Text("Send Text / Link", color = TextPrimary) },
            text = { OutlinedTextField(value = text, onValueChange = { text = it }, label = { Text("Message or URL") }, colors = glassTextFieldColors()) },
            confirmButton = {
                TextButton(onClick = {
                    val clean = text.trim()
                    showSendTextDialog = false
                    if (clean.isNotEmpty() && client != null) {
                        scope.launch {
                            try {
                                client!!.sendText(clean)
                                statusText = "📋 Sent text/link to ${remoteInfo?.device ?: "device"}!"
                            } catch (e: Exception) {
                                statusText = "Send text failed: ${e.message}"
                            }
                        }
                    }
                }) { Text("Send", color = AccentCyan) }
            },
            dismissButton = { TextButton(onClick = { showSendTextDialog = false }) { Text("Cancel", color = TextSecondary) } }
        )
    }

    renameTarget?.let { item ->
        var newName by remember { mutableStateOf(item.name) }
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            containerColor = CardBg,
            title = { Text("Rename Item", color = TextPrimary) },
            text = { OutlinedTextField(value = newName, onValueChange = { newName = it }, singleLine = true, colors = glassTextFieldColors()) },
            confirmButton = {
                TextButton(onClick = {
                    val clean = newName.trim()
                    renameTarget = null
                    if (clean.isNotEmpty() && clean != item.name && client != null) {
                        scope.launch {
                            try { client!!.rename(item.path, clean); refreshList(client, currentPath) }
                            catch (e: Exception) { statusText = "Rename failed: ${e.message}" }
                        }
                    }
                }) { Text("Rename", color = AccentCyan) }
            },
            dismissButton = { TextButton(onClick = { renameTarget = null }) { Text("Cancel", color = TextSecondary) } }
        )
    }

    if (deleteTargets.isNotEmpty()) {
        val list = deleteTargets
        AlertDialog(
            onDismissRequest = { deleteTargets = emptyList() },
            containerColor = CardBg,
            title = { Text("Delete ${list.size} item(s)?", color = TextPrimary) },
            text = { Text("This will delete the selected item(s) on ${remoteInfo?.device ?: "the remote device"}.", color = TextSecondary) },
            confirmButton = {
                TextButton(onClick = {
                    deleteTargets = emptyList()
                    scope.launch {
                        try {
                            for (it in list) client?.delete(it.path)
                            refreshList(client, currentPath)
                        } catch (e: Exception) {
                            statusText = "Delete failed: ${e.message}"
                        }
                    }
                }) { Text("Delete", color = DangerRed) }
            },
            dismissButton = { TextButton(onClick = { deleteTargets = emptyList() }) { Text("Cancel", color = TextSecondary) } }
        )
    }
}

@Composable
private fun HostScreen(
    prefs: android.content.SharedPreferences,
    onRequestRuntimePermissions: () -> Unit
) {
    val context = LocalContext.current
    val hostState by TransferForegroundService.server.state.collectAsState()
    val logs by TransferForegroundService.server.logs.collectAsState()
    val receivedText by TransferForegroundService.server.receivedText.collectAsState()

    var fixedPin by remember { mutableStateOf(prefs.getString("host_fixed_pin", "") ?: "") }
    val primaryRoot = remember { Environment.getExternalStorageDirectory().absolutePath }
    var sharedPath by remember {
        mutableStateOf(
            prefs.getString("host_shared_path", null)
                ?: Environment.getExternalStorageDirectory().absolutePath
        )
    }
    var sharedLabel by remember {
        mutableStateOf(prefs.getString("host_shared_label", "Internal Storage") ?: "Internal Storage")
    }
    var hasAllAccess by remember { mutableStateOf(hasFullStorageAccess(context)) }

    val hostStoragePermLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        hasAllAccess = hasFullStorageAccess(context)
        if (hasAllAccess) {
            Toast.makeText(context, "Storage access granted! PC & iPhone can now see all folders.", Toast.LENGTH_SHORT).show()
        }
    }

    // Refresh permission flag whenever HostScreen resumes from Android Settings or permission dialog
    val lifecycleOwner = context as? LifecycleOwner
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                hasAllAccess = hasFullStorageAccess(context)
            }
        }
        lifecycleOwner?.lifecycle?.addObserver(observer)
        onDispose { lifecycleOwner?.lifecycle?.removeObserver(observer) }
    }

    LaunchedEffect(hostState.isRunning, sharedPath) {
        hasAllAccess = hasFullStorageAccess(context)
    }

    val customFolderPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { treeUri: Uri? ->
        if (treeUri == null) return@rememberLauncherForActivityResult
        val docId = runCatching { DocumentsContract.getTreeDocumentId(treeUri) }.getOrNull()
        val resolved = docId?.let { ProtocolUtils.resolveTreeDocIdToPath(it, primaryRoot) }
        if (resolved != null) {
            val f = File(resolved)
            val lbl = f.name.ifBlank { "Shared" }
            sharedPath = f.absolutePath
            sharedLabel = lbl
            prefs.edit().putString("host_shared_path", sharedPath).putString("host_shared_label", sharedLabel).apply()
            TransferForegroundService.server.updateRoot(f, lbl)
            Toast.makeText(context, "Sharing folder: $resolved", Toast.LENGTH_SHORT).show()
        } else {
            Toast.makeText(context, "Could not resolve that folder path; try choosing a folder under Internal Storage or SD Card.", Toast.LENGTH_LONG).show()
        }
    }

    fun selectPreset(dir: File, label: String) {
        sharedPath = dir.absolutePath
        sharedLabel = label
        prefs.edit().putString("host_shared_path", sharedPath).putString("host_shared_label", sharedLabel).apply()
        TransferForegroundService.server.updateRoot(dir, label)
    }

    val url = if (hostState.isRunning && hostState.ipAddress.isNotBlank()) {
        "http://${hostState.ipAddress}:${hostState.port}"
    } else ""
    val qrBitmap = remember(url, hostState.pin) {
        if (url.isNotEmpty()) QrHelper.generateQrBitmap("$url/?pin=${ProtocolUtils.urlEncode(hostState.pin)}", 440)
        else null
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        // Prominent Full Storage Access banner (prevents empty/unreadable folder bugs on Android 10 & 11+!)
        if (!hasAllAccess) {
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    colors = CardDefaults.cardColors(containerColor = Color(0xFF2B1C0E)),
                    border = BorderStroke(1.dp, WarnAmber)
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        Icon(Icons.Default.Security, contentDescription = null, tint = WarnAmber)
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Storage / All Files Access Required", color = WarnAmber, fontWeight = FontWeight.Bold, fontSize = 13.5.sp)
                            Text(
                                "Android hides Downloads, DCIM, and Internal Storage from PC until you grant Storage Access.",
                                color = TextPrimary,
                                fontSize = 11.5.sp
                            )
                        }
                        Button(
                            onClick = {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                    onRequestRuntimePermissions()
                                    openStorageAccessSettings(context)
                                } else {
                                    hostStoragePermLauncher.launch(
                                        arrayOf(
                                            Manifest.permission.READ_EXTERNAL_STORAGE,
                                            Manifest.permission.WRITE_EXTERNAL_STORAGE
                                        )
                                    )
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = WarnAmber)
                        ) {
                            Text("Grant", color = Color.Black, fontWeight = FontWeight.Bold, fontSize = 12.sp)
                        }
                    }
                }
            }
        }

        // Received Clipboard / Link Card
        receivedText?.let { txt ->
            item {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                    colors = CardDefaults.cardColors(containerColor = Color(0xFF0E2A36)),
                    border = BorderStroke(1.dp, AccentCyan)
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("📋 Received Text / Link", color = AccentCyan, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                            Text(txt, color = TextPrimary, fontSize = 13.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
                        }
                        TextButton(onClick = {
                            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("WQGlass", txt))
                            Toast.makeText(context, "Copied to clipboard", Toast.LENGTH_SHORT).show()
                        }) { Text("Copy", color = AccentCyan) }
                        IconButton(onClick = { TransferForegroundService.server.clearReceivedText() }) {
                            Icon(Icons.Default.Close, contentDescription = "Dismiss", tint = TextSecondary)
                        }
                    }
                }
            }
        }

        // Hero QR + PIN + Start/Stop Card
        item {
            GlassCard {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = if (hostState.isRunning) "● Live · Visible to Windows PC, iPhone & Android" else (hostState.error ?: "Android Host Stopped"),
                        color = if (hostState.isRunning) SuccessGreen else WarnAmber,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold
                    )

                    Text(
                        text = if (hostState.isRunning) "PIN  ${hostState.pin}" else "----",
                        color = AccentCyan,
                        fontSize = 32.sp,
                        fontWeight = FontWeight.ExtraBold,
                        fontFamily = FontFamily.Monospace
                    )

                    Text(
                        text = if (url.isNotEmpty()) url else "Tap Start Sharing to expose \"$sharedLabel\" over Wi-Fi",
                        color = TextPrimary,
                        fontSize = 13.sp,
                        fontFamily = FontFamily.Monospace
                    )

                    if (qrBitmap != null) {
                        Surface(color = Color.White, shape = RoundedCornerShape(14.dp), modifier = Modifier.size(172.dp)) {
                            Image(bitmap = qrBitmap.asImageBitmap(), contentDescription = "QR Code", modifier = Modifier.fillMaxSize().padding(10.dp))
                        }
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = {
                                hasAllAccess = hasFullStorageAccess(context)
                                if (hostState.isRunning) {
                                    TransferForegroundService.stopHost(context)
                                } else {
                                    onRequestRuntimePermissions()
                                    if (!hasAllAccess) {
                                        Toast.makeText(context, "Tip: Grant All Files Access above so PC/iPhone can read all folders.", Toast.LENGTH_LONG).show()
                                    }
                                    val pinToUse = fixedPin.trim().takeIf { it.length in 4..8 } ?: TransferServer.generateRandomPin()
                                    TransferForegroundService.startHost(context, File(sharedPath), sharedLabel, pinToUse)
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = if (hostState.isRunning) DangerRed else AccentEmerald)
                        ) {
                            Icon(if (hostState.isRunning) Icons.Default.Stop else Icons.Default.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(if (hostState.isRunning) "Stop Sharing" else "Start Sharing")
                        }

                        if (hostState.isRunning) {
                            OutlinedButton(
                                onClick = {
                                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                    cm.setPrimaryClip(ClipData.newPlainText("WQGlass", "$url (PIN: ${hostState.pin})"))
                                    Toast.makeText(context, "Copied Wi-Fi address & PIN", Toast.LENGTH_SHORT).show()
                                },
                                border = BorderStroke(1.dp, CardBorder)
                            ) {
                                Icon(Icons.Default.ContentCopy, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(4.dp))
                                Text("Copy", color = TextPrimary)
                            }
                        }
                    }
                }
            }
        }

        // Wide Folder Share Selector Card
        item {
            GlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Wide Folder Share Root", color = TextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    Text(
                        text = "$sharedLabel  ($sharedPath)",
                        color = AccentCyan,
                        fontSize = 11.5.sp,
                        fontFamily = FontFamily.Monospace,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )

                    val presets = listOf(
                        "Internal Storage" to Environment.getExternalStorageDirectory(),
                        "Downloads" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                        "DCIM / Camera" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
                        "Pictures" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                        "Movies" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
                        "Documents" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
                        "Music" to Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
                    )

                    Row(
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        presets.forEach { (label, dir) ->
                            FilterChip(
                                selected = sharedPath == dir.absolutePath,
                                onClick = { selectPreset(dir, label) },
                                label = { Text(label, fontSize = 11.5.sp) },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = Color(0xFF1B3A6B),
                                    selectedLabelColor = AccentCyan
                                )
                            )
                        }
                    }

                    OutlinedButton(
                        onClick = { customFolderPicker.launch(null) },
                        modifier = Modifier.fillMaxWidth(),
                        border = BorderStroke(1.dp, CardBorder)
                    ) {
                        Icon(Icons.Default.FolderOpen, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(17.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Pick Any Custom Folder (Internal or SD Card)…", color = TextPrimary, fontSize = 12.5.sp)
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = fixedPin,
                            onValueChange = { if (it.length <= 8) fixedPin = it },
                            label = { Text("Fixed PIN (4–8 digits, optional)", fontSize = 11.sp) },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                            colors = glassTextFieldColors()
                        )
                        Button(
                            onClick = {
                                val clean = fixedPin.trim()
                                if (clean.isEmpty()) {
                                    prefs.edit().remove("host_fixed_pin").apply()
                                    TransferForegroundService.server.updatePin(TransferServer.generateRandomPin())
                                } else if (clean.length in 4..8) {
                                    prefs.edit().putString("host_fixed_pin", clean).apply()
                                    TransferForegroundService.server.updatePin(clean)
                                } else {
                                    Toast.makeText(context, "PIN must be 4–8 digits", Toast.LENGTH_SHORT).show()
                                }
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = AccentBlue)
                        ) { Text("Save") }
                    }
                }
            }
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("Live Activity Log", color = TextSecondary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                if (logs.isNotEmpty()) {
                    Text("Clear", color = AccentCyan, fontSize = 12.sp, modifier = Modifier.clickable { TransferForegroundService.server.clearLogs() })
                }
            }
        }

        if (logs.isEmpty()) {
            item {
                GlassCard {
                    Text("Waiting for Windows PC, iPhone, or Browser connections…", color = TextSecondary, fontSize = 12.5.sp)
                }
            }
        } else {
            items(logs) { line ->
                GlassCard {
                    Text(line, color = TextPrimary, fontSize = 12.sp, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}

@Composable
private fun HistoryScreen(
    history: List<TransferHistoryItem>,
    onClear: () -> Unit
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        GlassCard {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column {
                    Text("Transfer History", color = TextPrimary, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    val total = history.sumOf { it.bytes }
                    Text("${history.size} transfer(s) · ${ProtocolUtils.formatBytes(total)} moved", color = AccentCyan, fontSize = 12.sp)
                }
                if (history.isNotEmpty()) {
                    OutlinedButton(onClick = onClear, border = BorderStroke(1.dp, DangerRed)) {
                        Text("Clear", color = Color(0xFFFCA5A5), fontSize = 12.sp)
                    }
                }
            }
        }

        LazyColumn(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (history.isEmpty()) {
                item {
                    GlassCard {
                        Text("No transfers recorded in this session yet.", color = TextSecondary, fontSize = 13.sp)
                    }
                }
            } else {
                items(history) { h ->
                    GlassCard {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("${h.direction} ${h.fileName}", color = TextPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text("${h.timestamp} · ${ProtocolUtils.formatBytes(h.bytes)} · ${ProtocolUtils.formatSpeed(h.avgBytesPerSec)}", color = TextSecondary, fontSize = 11.5.sp)
                            }
                            Text(h.status, color = SuccessGreen, fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GlassCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = CardDefaults.cardColors(containerColor = CardBg),
        border = BorderStroke(1.dp, CardBorder)
    ) {
        Box(modifier = Modifier.padding(12.dp)) {
            content()
        }
    }
}

@Composable
private fun glassTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = TextPrimary,
    unfocusedTextColor = TextPrimary,
    focusedContainerColor = InputBg,
    unfocusedContainerColor = InputBg,
    focusedBorderColor = AccentCyan,
    unfocusedBorderColor = CardBorder,
    focusedLabelColor = AccentCyan,
    unfocusedLabelColor = TextSecondary
)
