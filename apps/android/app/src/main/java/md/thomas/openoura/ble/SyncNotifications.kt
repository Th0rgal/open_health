package md.thomas.openoura.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.work.ForegroundInfo
import md.thomas.openoura.R

/**
 * The single ongoing notification shown while a sync is running. WorkManager runs the sync
 * on its own foreground service, so — unlike the old standalone RingSyncService — this only
 * has to build the notification and the [ForegroundInfo] the worker hands to `setForeground`.
 *
 * The notification is deliberately minimal: the platform requires one for a foreground
 * service, and it lets the user know the app is talking to the ring. It is `setOngoing`, so
 * it clears the moment the worker finishes.
 */
object SyncNotifications {
    const val ID = 1
    private const val CHANNEL = "ring-sync"

    fun ensureChannel(context: Context) {
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

    fun build(context: Context, text: String): Notification {
        ensureChannel(context)
        return Notification.Builder(context, CHANNEL)
            .setContentTitle(context.getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_sync)
            .setOngoing(true)
            .build()
    }

    /**
     * A `connectedDevice` foreground service: the sync only makes sense while a BLE device is
     * within reach, and it is the type the app already declares (both the permission and the
     * merged WorkManager SystemForegroundService entry in the manifest).
     */
    fun foregroundInfo(context: Context, text: String): ForegroundInfo {
        val notification = build(context, text)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            ForegroundInfo(ID, notification)
        }
    }
}
