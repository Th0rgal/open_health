package md.thomas.openoura.ble

import android.app.NotificationManager
import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import md.thomas.openoura.diag.Diagnostics.log
import uniffi.oura_core.SyncReport

/**
 * The one place a BLE sync actually runs: every path — the 6-hour schedule, the app-start
 * refresh, and the manual "Connect & Sync" button — enqueues this worker (see
 * [SyncScheduler]). It runs the headless [SyncEngine] on a foreground service so a
 * multi-minute history drain survives the app being backgrounded, and forwards live status
 * to both WorkManager progress (for the UI) and the ongoing notification.
 *
 * The `source` input selects the retry policy:
 *  - `scheduled` → 5 attempts, exponential backoff capped at 1 min (patient background run)
 *  - `automatic` → the cooldown/resume decision in [SyncEngine.syncAutomaticallyIfNeeded]
 *  - `manual`    → 6 attempts, fixed 3 s (unchanged from the old foreground behaviour)
 *
 * The ring key is never passed through Data — the engine reads it from the Keystore — so no
 * key material is persisted in WorkManager's job database.
 */
class RingSyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun getForegroundInfo(): ForegroundInfo =
        SyncNotifications.foregroundInfo(applicationContext, "syncing with your ring…")

    private var lastStatus: String = ""

    override suspend fun doWork(): Result = coroutineScope {
        val source = inputData.getString(KEY_SOURCE) ?: SOURCE_SCHEDULED
        // Promote to a foreground service up front so the ongoing notification shows for the
        // whole run and the drain is not killed when the app leaves the foreground.
        runCatching { setForeground(getForegroundInfo()) }
            .onFailure { log("sync", "setForeground failed ($it) — continuing without it") }

        // The engine's onStatus fires synchronously — sometimes from a tokio callback thread
        // — so it can't call the suspending setProgress directly. Funnel status lines through
        // a conflated channel and drain them on this worker coroutine, updating WorkManager
        // progress (which the UI observes) and the ongoing notification in step.
        val statuses = Channel<String>(Channel.CONFLATED)
        val publisher = launch {
            for (status in statuses) {
                lastStatus = status
                runCatching { setProgress(workDataOf(KEY_STATUS to status)) }
                runCatching {
                    val nm = applicationContext.getSystemService(NotificationManager::class.java)
                    nm?.notify(SyncNotifications.ID, SyncNotifications.build(applicationContext, status))
                }
            }
        }
        val onStatus: (String) -> Unit = { statuses.trySend(it) }

        val engine = SyncEngine(applicationContext)
        val report = when (source) {
            SOURCE_MANUAL -> engine.run(
                maxAttempts = SyncEngine.MANUAL_MAX_ATTEMPTS,
                source = source,
                backoff = SyncEngine.FIXED_3S,
                onStatus = onStatus,
            )
            SOURCE_AUTOMATIC -> engine.syncAutomaticallyIfNeeded(onStatus = onStatus)
            else -> engine.run(
                maxAttempts = SyncEngine.SCHEDULED_MAX_ATTEMPTS,
                source = SOURCE_SCHEDULED,
                backoff = SyncEngine.SCHEDULED_BACKOFF,
                onStatus = onStatus,
            )
        }
        statuses.close()
        publisher.join()

        // Return success either way: the engine already ran its own in-run retries, and a
        // periodic worker reschedules itself in six hours regardless. Reporting `retry`
        // here would only add a second, redundant backoff on top of the engine's.
        Result.success(report?.let(::successData) ?: workDataOf(KEY_STATUS to lastStatus))
    }

    private fun successData(report: SyncReport): Data = workDataOf(
        KEY_OK to true,
        KEY_STATUS to lastStatus,
        KEY_SERIAL to report.serial,
        KEY_EVENTS to report.eventsSynced.toLong(),
        KEY_INSERTED to report.inserted.toLong(),
        KEY_CURSOR to report.nextCursor.toLong(),
    )

    companion object {
        const val SOURCE_SCHEDULED = "scheduled"
        const val SOURCE_AUTOMATIC = "automatic"
        const val SOURCE_MANUAL = "manual"

        const val KEY_SOURCE = "source"
        const val KEY_STATUS = "status"
        const val KEY_OK = "ok"
        const val KEY_SERIAL = "serial"
        const val KEY_EVENTS = "events"
        const val KEY_INSERTED = "inserted"
        const val KEY_CURSOR = "cursor"
    }
}

/**
 * The display-only scalars the sync screen shows, marshalled out of a succeeded worker's
 * output Data. Replaces the UniFFI `SyncReport` on the UI side, which cannot be reconstructed
 * from `Data` (WorkManager stores plain scalars, not the FFI record).
 */
data class SyncSummary(
    val serial: String,
    val eventsSynced: Long,
    val inserted: Long,
    val nextCursor: Long,
) {
    companion object {
        fun fromData(data: Data): SyncSummary? {
            if (!data.getBoolean(RingSyncWorker.KEY_OK, false)) return null
            val serial = data.getString(RingSyncWorker.KEY_SERIAL) ?: return null
            return SyncSummary(
                serial = serial,
                eventsSynced = data.getLong(RingSyncWorker.KEY_EVENTS, 0),
                inserted = data.getLong(RingSyncWorker.KEY_INSERTED, 0),
                nextCursor = data.getLong(RingSyncWorker.KEY_CURSOR, 0),
            )
        }
    }
}
