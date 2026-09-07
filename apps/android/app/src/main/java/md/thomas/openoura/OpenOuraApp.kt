package md.thomas.openoura

import android.app.Application
import md.thomas.openoura.ble.SyncScheduler
import md.thomas.openoura.diag.Diagnostics

class OpenOuraApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Diagnostics.bootstrap(this)
        // Register the recurring 6-hour background sync (idempotent). The app-start and
        // manual syncs are enqueued on demand elsewhere; this is the only autonomous one.
        SyncScheduler.schedulePeriodic(this)
    }
}
