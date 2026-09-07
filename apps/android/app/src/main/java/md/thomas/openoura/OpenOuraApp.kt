package md.thomas.openoura

import android.app.Application
import md.thomas.openoura.diag.Diagnostics

class OpenOuraApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Diagnostics.bootstrap(this)
    }
}
