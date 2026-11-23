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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.core.content.ContextCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.File

private val BgCanvas = Color(0xFF0B1120)
private val CardBg = Color(0xFF131C31)
private val CardBorder = Color(0xFF24324D)
private val InputBg = Color(0xFF0F172A)
private val TextPrimary = Color(0xFFF8FAFC)
private val TextSecondary = Color(0xFF94A3B8)
private val AccentBlue = Color(0xFF2563EB)
private val AccentCyan = Color(0xFF38BDF8)
private val SuccessGreen = Color(0xFF4ADE80)
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

@Composable
private fun WQGlassTransferApp(discovery: DiscoveryService) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("wqglass_transfer", Context.MODE_PRIVATE) }
    var selectedTab by remember { mutableIntStateOf(0) }
    val hostState by TransferForegroundService.server.state.collectAsState()

    val notifPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { }

    Scaffold(
        containerColor = BgCanvas,
        bottomBar = {
            NavigationBar(containerColor = CardBg) {
                NavigationBarItem(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    icon = { Icon(Icons.Default.Wifi, contentDescription = null) },
                    label = { Text("Connect (Client)") }
                )
                NavigationBarItem(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    icon = { Icon(Icons.Default.Upload, contentDescription = null) },
                    label = {
                        Text(if (hostState.isRunning) "Share · Live" else "Share Device")
                    }
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
            if (selectedTab == 0) {
                ClientScreen(discovery = discovery, prefs = prefs)
            } else {
                HostScreen(
                    prefs = prefs,
                    onRequestNotifications = {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            notifPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                        }
                    }
                )
            }
        }
    }
}

@Composable
private fun ClientScreen(
    discovery: DiscoveryService,
    prefs: android.content.SharedPreferences
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val peers by discovery.peers.collectAsState()

    var endpoint by remember { mutableStateOf(prefs.getString("last_endpoint", "") ?: "") }
    var pin by remember { mutableStateOf(prefs.getString("last_pin", "") ?: "") }
    var client by remember { mutableStateOf<TransferClient?>(null) }
    var remoteInfo by remember { mutableStateOf<RemoteInfo?>(null) }
    var currentPath by remember { mutableStateOf("") }
    var items by remember { mutableStateOf<List<RemoteFileItem>>(emptyList()) }
    var statusText by remember { mutableStateOf("Tap a discovered device, enter IP:Port, or scan a QR code.") }
    var progress by remember { mutableStateOf<TransferProgress?>(null) }
    var activeJob by remember { mutableStateOf<Job?>(null) }
    var showNewFolderDialog by remember { mutableStateOf(false) }
    var renameTarget by remember { mutableStateOf<RemoteFileItem?>(null) }
    var deleteTarget by remember { mutableStateOf<RemoteFileItem?>(null) }
    var actionTarget by remember { mutableStateOf<RemoteFileItem?>(null) }

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
                items = activeClient.list(path)
                statusText = "Connected · /${remoteInfo?.root ?: "Shared"}${if (path.isEmpty()) "" else "/$path"} (${items.size} items)"
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
                refreshList(c, "")
            } catch (e: Exception) {
                statusText = "Connection failed: ${e.message}"
                Toast.makeText(context, e.message ?: "Could not connect", Toast.LENGTH_LONG).show()
            }
        }
    }

    val qrLauncher = rememberLauncherForActivityResult(ScanContract()) { result ->
        val contents = result.contents ?: return@rememberLauncherForActivityResult
        val parsed = ProtocolUtils.parseQrPayload(contents)
        if (parsed != null) {
            endpoint = parsed.endpoint
            if (!parsed.pin.isNullOrBlank()) {
                pin = parsed.pin
                doConnect(parsed.endpoint, parsed.pin)
            } else {
                statusText = "Scanned ${parsed.endpoint} — enter PIN and tap Connect."
            }
        } else {
            Toast.makeText(context, "Unrecognized QR code", Toast.LENGTH_SHORT).show()
        }
    }

    val uploadPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        val activeClient = client ?: return@rememberLauncherForActivityResult
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        activeJob?.cancel()
        activeJob = scope.launch {
            try {
                uris.forEachIndexed { idx, uri ->
                    activeClient.uploadUri(
                        contentResolver = context.contentResolver,
                        uri = uri,
                        remoteDir = currentPath,
                        fileIndex = idx + 1,
                        fileCount = uris.size
                    ) { p -> progress = p }
                }
                progress = null
                statusText = "Uploaded ${uris.size} file(s) successfully!"
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

    fun startDownload(item: RemoteFileItem) {
        val activeClient = client ?: return
        activeJob?.cancel()
        activeJob = scope.launch {
            try {
                val destDir = resolveLocalDownloadDir()
                val saved = activeClient.downloadFile(
                    remotePath = item.path,
                    destinationDir = destDir,
                    fileName = item.name,
                    fileIndex = 1,
                    fileCount = 1
                ) { p -> progress = p }
                progress = null
                statusText = "Saved to ${saved.absolutePath}"
                Toast.makeText(context, "Saved ${saved.name} to Downloads/WQGlass", Toast.LENGTH_SHORT).show()
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
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        // Header card
        GlassCard {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = if (remoteInfo != null) {
                            "${remoteInfo!!.device} · ${remoteInfo!!.osSummary}"
                        } else {
                            "WQGlass Transfer"
                        },
                        color = TextPrimary,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = if (remoteInfo != null) {
                            "Free: ${ProtocolUtils.formatBytes(remoteInfo!!.freeBytes)} / ${ProtocolUtils.formatBytes(remoteInfo!!.totalBytes)}"
                        } else {
                            "iPhone · Android · Windows PC"
                        },
                        color = if (remoteInfo != null) SuccessGreen else TextSecondary,
                        fontSize = 12.sp
                    )
                }
                if (client != null) {
                    OutlinedButton(
                        onClick = {
                            activeJob?.cancel()
                            client = null
                            remoteInfo = null
                            items = emptyList()
                            currentPath = ""
                            progress = null
                            statusText = "Disconnected."
                        },
                        border = BorderStroke(1.dp, DangerRed)
                    ) {
                        Text("Disconnect", color = Color(0xFFFCA5A5))
                    }
                } else {
                    IconButton(onClick = {
                        val opts = ScanOptions().apply {
                            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                            setPrompt("Scan WQGlass QR code on PC or iPhone")
                            setBeepEnabled(false)
                            setOrientationLocked(false)
                        }
                        qrLauncher.launch(opts)
                    }) {
                        Icon(Icons.Default.QrCodeScanner, contentDescription = "Scan QR", tint = AccentCyan)
                    }
                }
            }
        }

        if (client == null) {
            // Manual connection card
            GlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        OutlinedTextField(
                            value = endpoint,
                            onValueChange = { endpoint = it },
                            label = { Text("IP:Port (e.g. 192.168.1.42:8765)", fontSize = 11.sp) },
                            singleLine = true,
                            modifier = Modifier.weight(1.7f),
                            colors = glassTextFieldColors()
                        )
                        OutlinedTextField(
                            value = pin,
                            onValueChange = { if (it.length <= 8) pin = it },
                            label = { Text("PIN", fontSize = 11.sp) },
                            singleLine = true,
                            modifier = Modifier.weight(1f),
                            colors = glassTextFieldColors()
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        Button(
                            onClick = { doConnect(endpoint, pin) },
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.buttonColors(containerColor = AccentBlue)
                        ) {
                            Text("Connect")
                        }
                        OutlinedButton(
                            onClick = {
                                discovery.sendProbeNow()
                                statusText = "Scanning Wi-Fi for PC, iPhone & Android…"
                            },
                            border = BorderStroke(1.dp, CardBorder)
                        ) {
                            Icon(Icons.Default.Refresh, contentDescription = null, tint = AccentCyan, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Scan", color = TextPrimary)
                        }
                    }
                }
            }

            Text(
                text = "Nearby Devices on Wi-Fi (${peers.size})",
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
                                fontSize = 13.sp
                            )
                        }
                    }
                } else {
                    items(peers, key = { it.endpoint }) { peer ->
                        GlassCard(
                            modifier = Modifier.clickable {
                                endpoint = peer.endpoint
                                if (pin.length >= 4) {
                                    doConnect(peer.endpoint, pin)
                                } else {
                                    statusText = "Selected ${peer.device}. Enter PIN above and tap Connect."
                                }
                            }
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = "${peer.platformEmoji} ${peer.device}",
                                        color = TextPrimary,
                                        fontWeight = FontWeight.SemiBold,
                                        fontSize = 15.sp
                                    )
                                    Text(
                                        text = "${peer.platformBadge}${if (peer.osVersion.isNotBlank()) " ${peer.osVersion}" else ""} · ${peer.endpoint} · /${peer.root}",
                                        color = TextSecondary,
                                        fontSize = 12.sp
                                    )
                                }
                                Text("Tap", color = AccentCyan, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
        } else {
            // Connected Remote Explorer Toolbar
            GlassCard {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(
                        enabled = currentPath.isNotEmpty(),
                        onClick = {
                            val idx = currentPath.lastIndexOf('/')
                            currentPath = if (idx > 0) currentPath.substring(0, idx) else ""
                            refreshList(client, currentPath)
                        }
                    ) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Up", tint = if (currentPath.isNotEmpty()) AccentCyan else TextSecondary)
                    }
                    IconButton(onClick = { refreshList(client, currentPath) }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = AccentCyan)
                    }
                    IconButton(onClick = { showNewFolderDialog = true }) {
                        Icon(Icons.Default.CreateNewFolder, contentDescription = "New Folder", tint = AccentCyan)
                    }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { uploadPicker.launch(arrayOf("*/*")) },
                        colors = ButtonDefaults.buttonColors(containerColor = AccentBlue)
                    ) {
                        Icon(Icons.Default.Upload, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Send Files")
                    }
                }
            }

            // Active progress banner
            progress?.let { p ->
                GlassCard {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "${p.verb} (${p.fileIndex}/${p.fileCount}): ${p.fileName}",
                                color = TextPrimary,
                                fontSize = 13.sp,
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
                            text = "${ProtocolUtils.formatBytes(p.transferredBytes)} / ${ProtocolUtils.formatBytes(p.totalBytes)} · ${ProtocolUtils.formatSpeed(p.bytesPerSec)}",
                            color = AccentCyan,
                            fontSize = 12.sp
                        )
                    }
                }
            }

            // File list
            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (items.isEmpty()) {
                    item {
                        GlassCard {
                            Text("Folder is empty.", color = TextSecondary, fontSize = 13.sp)
                        }
                    }
                } else {
                    items(items, key = { it.path }) { item ->
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
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                Icon(
                                    imageVector = if (item.isDir) Icons.Default.Folder else Icons.Default.Description,
                                    contentDescription = null,
                                    tint = if (item.isDir) AccentCyan else TextSecondary
                                )
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = item.name,
                                        color = TextPrimary,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis
                                    )
                                    Text(
                                        text = if (item.isDir) "Folder" else ProtocolUtils.formatBytes(item.size),
                                        color = TextSecondary,
                                        fontSize = 11.5.sp
                                    )
                                }
                                if (!item.isDir) {
                                    IconButton(onClick = { startDownload(item) }) {
                                        Icon(Icons.Default.Download, contentDescription = "Download", tint = AccentCyan)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Text(
            text = statusText,
            color = TextSecondary,
            fontSize = 11.5.sp,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis
        )
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
                    startDownload(item)
                }) { Text("Download", color = AccentCyan) }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = {
                        actionTarget = null
                        renameTarget = item
                    }) { Text("Rename", color = TextPrimary) }
                    TextButton(onClick = {
                        actionTarget = null
                        deleteTarget = item
                    }) { Text("Delete", color = DangerRed) }
                }
            }
        )
    }

    // New Folder Dialog
    if (showNewFolderDialog) {
        var name by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showNewFolderDialog = false },
            containerColor = CardBg,
            title = { Text("Create Remote Folder", color = TextPrimary) },
            text = {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Folder name") },
                    singleLine = true,
                    colors = glassTextFieldColors()
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val clean = name.trim()
                    showNewFolderDialog = false
                    if (clean.isNotEmpty() && client != null) {
                        val target = if (currentPath.isEmpty()) clean else "$currentPath/$clean"
                        scope.launch {
                            try {
                                client!!.createFolder(target)
                                refreshList(client, currentPath)
                            } catch (e: Exception) {
                                statusText = "Create folder failed: ${e.message}"
                            }
                        }
                    }
                }) { Text("Create", color = AccentCyan) }
            },
            dismissButton = {
                TextButton(onClick = { showNewFolderDialog = false }) { Text("Cancel", color = TextSecondary) }
            }
        )
    }

    // Rename Dialog
    renameTarget?.let { item ->
        var newName by remember { mutableStateOf(item.name) }
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            containerColor = CardBg,
            title = { Text("Rename Item", color = TextPrimary) },
            text = {
                OutlinedTextField(
                    value = newName,
                    onValueChange = { newName = it },
                    singleLine = true,
                    colors = glassTextFieldColors()
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    val clean = newName.trim()
                    renameTarget = null
                    if (clean.isNotEmpty() && clean != item.name && client != null) {
                        scope.launch {
                            try {
                                client!!.rename(item.path, clean)
                                refreshList(client, currentPath)
                            } catch (e: Exception) {
                                statusText = "Rename failed: ${e.message}"
                            }
                        }
                    }
                }) { Text("Rename", color = AccentCyan) }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) { Text("Cancel", color = TextSecondary) }
            }
        )
    }

    // Delete Dialog
    deleteTarget?.let { item ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            containerColor = CardBg,
            title = { Text("Delete \"${item.name}\"?", color = TextPrimary) },
            text = { Text("This will delete the item on ${remoteInfo?.device ?: "the remote device"}.", color = TextSecondary) },
            confirmButton = {
                TextButton(onClick = {
                    deleteTarget = null
                    scope.launch {
                        try {
                            client?.delete(item.path)
                            refreshList(client, currentPath)
                        } catch (e: Exception) {
                            statusText = "Delete failed: ${e.message}"
                        }
                    }
                }) { Text("Delete", color = DangerRed) }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Cancel", color = TextSecondary) }
            }
        )
    }
}

@Composable
private fun HostScreen(
    prefs: android.content.SharedPreferences,
    onRequestNotifications: () -> Unit
) {
    val context = LocalContext.current
    val hostState by TransferForegroundService.server.state.collectAsState()
    val logs by TransferForegroundService.server.logs.collectAsState()

    var fixedPin by remember { mutableStateOf(prefs.getString("host_fixed_pin", "") ?: "") }
    var shareInternal by remember { mutableStateOf(prefs.getBoolean("host_share_internal", false)) }

    fun selectedRootDir(): Pair<File, String> {
        return if (shareInternal) {
            Environment.getExternalStorageDirectory() to "Internal Storage"
        } else {
            val dl = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            if (dl.exists() || dl.mkdirs()) dl to "Downloads"
            else (context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: context.filesDir) to "Downloads"
        }
    }

    val url = if (hostState.isRunning && hostState.ipAddress.isNotBlank()) {
        "http://${hostState.ipAddress}:${hostState.port}"
    } else ""
    val qrBitmap = remember(url, hostState.pin) {
        if (url.isNotEmpty()) QrHelper.generateQrBitmap("$url/?pin=${ProtocolUtils.urlEncode(hostState.pin)}", 420)
        else null
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        item {
            GlassCard {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = if (hostState.isRunning) {
                            "● Live · Visible to Windows PC, iPhone & Android"
                        } else {
                            hostState.error ?: "Android Host Stopped"
                        },
                        color = if (hostState.isRunning) SuccessGreen else Color(0xFFFBBF24),
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
                        text = if (url.isNotEmpty()) url else "Tap Start Sharing to expose files on Wi-Fi",
                        color = TextPrimary,
                        fontSize = 13.sp,
                        fontFamily = FontFamily.Monospace
                    )

                    if (qrBitmap != null) {
                        Surface(
                            color = Color.White,
                            shape = RoundedCornerShape(14.dp),
                            modifier = Modifier.size(164.dp)
                        ) {
                            Image(
                                bitmap = qrBitmap.asImageBitmap(),
                                contentDescription = "Connection QR Code",
                                modifier = Modifier.fillMaxSize().padding(10.dp)
                            )
                        }
                    }

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = {
                                if (hostState.isRunning) {
                                    TransferForegroundService.stopHost(context)
                                } else {
                                    onRequestNotifications()
                                    val (dir, label) = selectedRootDir()
                                    val pinToUse = fixedPin.trim().takeIf { it.length in 4..8 }
                                        ?: TransferServer.generateRandomPin()
                                    TransferForegroundService.startHost(context, dir, label, pinToUse)
                                }
                            },
                            colors = ButtonDefaults.buttonColors(
                                containerColor = if (hostState.isRunning) DangerRed else AccentBlue
                            )
                        ) {
                            Icon(
                                imageVector = if (hostState.isRunning) Icons.Default.Stop else Icons.Default.PlayArrow,
                                contentDescription = null,
                                modifier = Modifier.size(18.dp)
                            )
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

        item {
            GlassCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Shared Folder & Permissions", color = TextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        Button(
                            onClick = {
                                shareInternal = false
                                prefs.edit().putBoolean("host_share_internal", false).apply()
                                val (dir, label) = selectedRootDir()
                                TransferForegroundService.server.updateRoot(dir, label)
                            },
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.buttonColors(containerColor = if (!shareInternal) AccentBlue else InputBg)
                        ) { Text("Downloads") }

                        Button(
                            onClick = {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
                                    val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                                        data = Uri.parse("package:${context.packageName}")
                                    }
                                    context.startActivity(intent)
                                }
                                shareInternal = true
                                prefs.edit().putBoolean("host_share_internal", true).apply()
                                val (dir, label) = selectedRootDir()
                                TransferForegroundService.server.updateRoot(dir, label)
                            },
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.buttonColors(containerColor = if (shareInternal) AccentBlue else InputBg)
                        ) { Text("Internal Storage") }
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
                    Text(
                        text = "Clear",
                        color = AccentCyan,
                        fontSize = 12.sp,
                        modifier = Modifier.clickable { TransferForegroundService.server.clearLogs() }
                    )
                }
            }
        }

        if (logs.isEmpty()) {
            item {
                GlassCard {
                    Text(
                        text = "Waiting for Windows PC, iPhone, or Browser connections…",
                        color = TextSecondary,
                        fontSize = 12.5.sp
                    )
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
private fun GlassCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = CardBg),
        border = BorderStroke(1.dp, CardBorder)
    ) {
        Box(modifier = Modifier.padding(14.dp)) {
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
