package com.wqglass.transfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import java.io.File

class TransferForegroundService : Service() {
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                server.stop()
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_START -> {
                val rootPath = intent.getStringExtra(EXTRA_ROOT_PATH) ?: return START_NOT_STICKY
                val rootLabel = intent.getStringExtra(EXTRA_ROOT_LABEL) ?: "Downloads"
                val pin = intent.getStringExtra(EXTRA_PIN) ?: TransferServer.generateRandomPin()

                ensureChannel()
                acquireLocks()
                val ok = server.start(File(rootPath), rootLabel, pin)
                if (!ok) {
                    releaseLocks()
                    stopSelf()
                    return START_NOT_STICKY
                }
                val st = server.state.value
                val notif = buildNotification("Live at http://${st.ipAddress}:${st.port} · PIN ${st.pin}")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                } else {
                    startForeground(NOTIF_ID, notif)
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        server.stop()
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wm?.createWifiLock(mode, "WQGlassTransfer:Host")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    private fun releaseLocks() {
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {
        }
        wifiLock = null
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(NotificationManager::class.java)
            val ch = NotificationChannel(
                CHANNEL_ID,
                "WQGlass LAN Transfer Host",
                NotificationManager.IMPORTANCE_LOW
            )
            mgr?.createNotificationChannel(ch)
        }
    }

    private fun buildNotification(text: String): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stopIntent = PendingIntent.getService(
            this,
            1,
            Intent(this, TransferForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("WQGlass Transfer Host Active")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopIntent)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "wqglass_transfer_host"
        private const val NOTIF_ID = 45888

        const val ACTION_START = "com.wqglass.transfer.START_HOST"
        const val ACTION_STOP = "com.wqglass.transfer.STOP_HOST"
        const val EXTRA_ROOT_PATH = "root_path"
        const val EXTRA_ROOT_LABEL = "root_label"
        const val EXTRA_PIN = "pin"

        val server = TransferServer()

        fun startHost(context: Context, rootDir: File, rootLabel: String, pin: String) {
            val intent = Intent(context, TransferForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ROOT_PATH, rootDir.absolutePath)
                putExtra(EXTRA_ROOT_LABEL, rootLabel)
                putExtra(EXTRA_PIN, pin)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopHost(context: Context) {
            val intent = Intent(context, TransferForegroundService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
