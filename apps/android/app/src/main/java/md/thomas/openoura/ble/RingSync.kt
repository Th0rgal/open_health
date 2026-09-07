package md.thomas.openoura.ble

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.WorkInfo
import kotlinx.coroutines.launch
import md.thomas.openoura.diag.Diagnostics.log
import md.thomas.openoura.store.DB
import md.thomas.openoura.store.Prefs
import md.thomas.openoura.store.RingKeyStore

/**
 * UI-facing controller over the WorkManager-driven sync. The BLE work itself runs in
 * [RingSyncWorker] / [SyncEngine]; this ViewModel only enqueues it and mirrors the observed
 * [WorkInfo] into Compose state for the sync screen and the home header. Mirrors the surface
 * RingSync.swift exposes on iOS, minus the sync loop (which moved to the worker so it can run
 * in the background).
 */
class RingSync(app: android.app.Application) : AndroidViewModel(app) {

    var status by mutableStateOf("")
        private set
    var busy by mutableStateOf(false)
        private set
    var lastSummary by mutableStateOf<SyncSummary?>(null)
        private set
    var lastSuccessfulSyncAtMs by mutableStateOf<Long?>(null)
        private set

    private val context: Context get() = getApplication()

    init {
        lastSuccessfulSyncAtMs = Prefs.of(app).getLong(Prefs.LAST_SUCCESSFUL_SYNC_AT, 0L).takeIf { it > 0 }
        // Reflect every sync — scheduled, app-start, or manual — into Compose state.
        viewModelScope.launch {
            SyncScheduler.observe(context).collect(::onWorkInfos)
        }
    }

    private fun onWorkInfos(infos: List<WorkInfo>) {
        val running = infos.firstOrNull { it.state == WorkInfo.State.RUNNING }
        busy = running != null

        val succeeded = infos.filter { it.state == WorkInfo.State.SUCCEEDED }
        if (running != null) {
            running.progress.getString(RingSyncWorker.KEY_STATUS)
                ?.takeIf { it.isNotEmpty() }
                ?.let { status = it }
        } else {
            // A finished run leaves its terminal message in output Data — prefer a success,
            // otherwise any finished run's message (the failure explanation).
            val terminal = succeeded.ifEmpty { infos.filter { it.state.isFinished } }
            terminal.firstNotNullOfOrNull {
                it.outputData.getString(RingSyncWorker.KEY_STATUS)?.takeIf { s -> s.isNotEmpty() }
            }?.let { status = it }
        }

        // A newly succeeded run publishes its summary; refresh the last-sync timestamp from
        // the same prefs the worker wrote.
        val summary = succeeded.firstNotNullOfOrNull { SyncSummary.fromData(it.outputData) }
        if (summary != null && summary != lastSummary) {
            lastSummary = summary
            lastSuccessfulSyncAtMs =
                Prefs.of(context).getLong(Prefs.LAST_SUCCESSFUL_SYNC_AT, 0L).takeIf { it > 0 }
        }
    }

    fun wasRecentlySynced(nowMs: Long = System.currentTimeMillis()): Boolean =
        lastSuccessfulSyncAtMs?.let { nowMs - it < SyncEngine.AUTOMATIC_SYNC_COOLDOWN_MS } ?: false

    fun hasStoredKey(): Boolean = RingKeyStore.load(context) != null

    /** Manual "Connect & Sync". The key is read from the Keystore inside the worker. */
    fun sync() = SyncScheduler.syncNow(context, RingSyncWorker.SOURCE_MANUAL)

    fun resetLocalDatabase() {
        if (SyncEngine.isRunning()) {
            status = "can't reset while a sync is running — wait for it to finish"
            return
        }
        DB.resetWritableStore(context)
        lastSummary = null
        lastSuccessfulSyncAtMs = null
        Prefs.of(context).edit()
            .remove(Prefs.LAST_SUCCESSFUL_SYNC_AT)
            .remove(Prefs.SYNC_INCOMPLETE)
            .remove(Prefs.LAST_AUTOMATIC_ATTEMPT_AT)
            .apply()
        status = "local sync database reset — run Connect & Sync again"
        log("db", "writable sync database reset")
    }
}
