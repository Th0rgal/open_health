package md.thomas.openoura.ble

import android.content.Context
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import kotlinx.coroutines.flow.Flow
import java.util.concurrent.TimeUnit

/**
 * Enqueues [RingSyncWorker] and exposes its state for the UI. Every sync path funnels
 * through here so there is a single WorkManager work item per kind.
 *
 * "Only if a background sync isn't already running" is enforced twice over: [ExistingWorkPolicy.KEEP]
 * stops a second one-shot stacking while one is enqueued/running, and the process-wide lock
 * in [SyncEngine.run] stops a one-shot overlapping the periodic run (it returns immediately
 * instead of contending for the ring's single BLE link).
 */
object SyncScheduler {
    private const val PERIODIC_NAME = "ring-sync-periodic"
    private const val ONESHOT_NAME = "ring-sync-now"
    private const val TAG = "ring-sync"

    private const val PERIOD_HOURS = 6L

    /** Register the recurring 6-hour background sync. Idempotent — safe to call every launch. */
    fun schedulePeriodic(context: Context) {
        val request = PeriodicWorkRequestBuilder<RingSyncWorker>(PERIOD_HOURS, TimeUnit.HOURS)
            .setInputData(workDataOf(RingSyncWorker.KEY_SOURCE to RingSyncWorker.SOURCE_SCHEDULED))
            .addTag(TAG)
            .build()
        // KEEP: don't reset the 6-hour clock (or the current run) on every app launch.
        WorkManager.getInstance(context)
            .enqueueUniquePeriodicWork(PERIODIC_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    /**
     * Run a sync now. `source` is [RingSyncWorker.SOURCE_AUTOMATIC] (app start — honours the
     * cooldown/resume decision) or [RingSyncWorker.SOURCE_MANUAL] (the Sync button).
     * Expedited so it starts promptly, falling back to a normal job if the app is out of
     * expedited quota.
     */
    fun syncNow(context: Context, source: String) {
        val request = OneTimeWorkRequestBuilder<RingSyncWorker>()
            .setInputData(workDataOf(RingSyncWorker.KEY_SOURCE to source))
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag(TAG)
            .build()
        WorkManager.getInstance(context)
            .enqueueUniqueWork(ONESHOT_NAME, ExistingWorkPolicy.KEEP, request)
    }

    /** All sync work items (periodic + one-shot), for the UI to derive busy/status from. */
    fun observe(context: Context): Flow<List<WorkInfo>> =
        WorkManager.getInstance(context).getWorkInfosByTagFlow(TAG)
}
