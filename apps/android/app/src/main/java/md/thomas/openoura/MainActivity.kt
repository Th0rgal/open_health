package md.thomas.openoura

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import md.thomas.openoura.ble.RingSync
import md.thomas.openoura.ui.AppNav
import md.thomas.openoura.ui.OpenOuraTheme
import md.thomas.openoura.ui.SummaryViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            OpenOuraTheme {
                val vm: SummaryViewModel = viewModel()
                val ring: RingSync = viewModel()
                // System-bar insets are applied once inside AppNav, so every destination
                // gets them rather than only the ones that accept a modifier.
                AppNav(vm = vm, ring = ring)
            }
        }
    }
}
