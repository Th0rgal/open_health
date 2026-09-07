package md.thomas.openoura.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import md.thomas.openoura.R

/**
 * Keeps the process foreground for the duration of a sync.
 *
 * The ring holds a single BLE link and a full history drain can run for many minutes.
 * iOS cannot do this at all — `IdleTimerLock` there only stops the screen locking while
 * the app is in front (see docs/clients.md). On Android a `connectedDevice` foreground
 * service plus [WakeLockOwner] means the drain survives the user switching apps, which
 * is what the official client does too.
 *
 * The notification is deliberately minimal and non-dismissable-free: it exists because
 * the platform requires one, not to advertise anything.
 */
class RingSyncService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_STATUS) ?: "Syncing with your ring…"
        val notification = buildNotification(text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(ID, notification)
        }
        // Do not restart on its own if the process is killed: the sync itself is driven
        // by the app, and a service resurrected without it would hold the ring's single
        // BLE link for nothing.
        return START_NOT_STICKY
    }

    private fun buildNotification(text: String): Notification {
        ensureChannel(this)
        return Notification.Builder(this, CHANNEL)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_sync)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "ring-sync"
        private const val ID = 1
        private const val EXTRA_STATUS = "status"

        fun start(context: Context, status: String) {
            val intent = Intent(context, RingSyncService::class.java).putExtra(EXTRA_STATUS, status)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RingSyncService::class.java))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL) != null) return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Ring sync", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown only while Open Oura is talking to your ring."
                    setShowBadge(false)
                }
            )
        }
    }
}
