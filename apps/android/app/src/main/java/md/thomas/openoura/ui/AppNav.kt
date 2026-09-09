package md.thomas.openoura.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.DisposableEffect
import md.thomas.openoura.ble.RingSync
import md.thomas.openoura.ble.RingSyncWorker
import md.thomas.openoura.ble.SyncScheduler
import md.thomas.openoura.data.VitalKind
import md.thomas.openoura.health.HealthExport
import md.thomas.openoura.store.ProfileStore

/**
 * Destinations. iOS presents these as sheets over a single root; here they are
 * full-screen destinations with system-back wired up, which is the platform's idiom for
 * the same "drill in and come back" shape.
 */
sealed interface Route {
    data object Home : Route
    data class DayReport(val day: String, val sleep: Boolean) : Route
    data object AllDays : Route
    data object Sync : Route
    data object Profile : Route
    data object SleepDebt : Route
    data class Vital(val kind: VitalKind) : Route
}

@Composable
fun AppNav(vm: SummaryViewModel, ring: RingSync, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    val context = LocalContext.current
    var route by remember { mutableStateOf<Route>(Route.Home) }
    var healthNote by remember { mutableStateOf<String?>(null) }
    var healthExportEnabled by remember { mutableStateOf(HealthExport.isEnabled(context)) }

    BackHandler(enabled = route != Route.Home) { route = Route.Home }

    // Opportunistic refresh on launch and when returning to the app — the same policy as
    // iOS's scenePhase hook, now routed through the same WorkManager worker as every other
    // sync. The worker applies the cooldown / eager-resume decision, and the KEEP policy
    // plus the engine's process lock make it a no-op when a background sync is already
    // running.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) {
                SyncScheduler.syncNow(context, RingSyncWorker.SOURCE_AUTOMATIC)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // A sync that lands while a screen is open should refresh the rendered summary.
    LaunchedEffect(ring.lastSummary) {
        if (ring.lastSummary != null) vm.reload()
    }

    val s = vm.summary
    // enableEdgeToEdge() lets the Quiet Ink paper fill the window, but then EVERY
    // destination must keep its controls out from under the system bars — a header drawn
    // there is not merely ugly, it is untappable, because the system consumes the touch.
    // Applying it once here covers destinations that take no modifier of their own.
    val base = Modifier.fillMaxSize()

    Box(
        modifier
            .fillMaxSize()
            .background(colors.paper)
            .windowInsetsPadding(WindowInsets.safeDrawing)
    ) {
    when (val r = route) {
        Route.Home -> RootScreen(
            vm = vm,
            syncBusy = ring.busy,
            recentlySynced = ring.wasRecentlySynced(),
            onOpenSync = { route = Route.Sync },
            onOpenProfile = { route = Route.Profile },
            onOpenDay = { day, sleep -> route = Route.DayReport(day, sleep) },
            onOpenAllDays = { route = Route.AllDays },
            onOpenSleepDebt = { route = Route.SleepDebt },
            onOpenVital = { route = Route.Vital(it) },
            modifier = base,
        )

        is Route.DayReport -> if (s == null) route = Route.Home else DayReportScreen(
            s = s,
            day = r.day,
            startOnSleep = r.sleep,
            onBack = { route = Route.Home },
            modifier = base,
        )

        Route.AllDays -> if (s == null) route = Route.Home else AllDaysScreen(
            s = s,
            onOpenDay = { route = Route.DayReport(it, true) },
            onBack = { route = Route.Home },
        )

        Route.SleepDebt -> {
            val debt = s?.sleepDebt
            if (debt == null) route = Route.Home
            else SleepDebtScreen(debt) { route = Route.Home }
        }

        is Route.Vital -> if (s == null) route = Route.Home else VitalTrendScreen(
            s = s,
            kind = r.kind,
            onBack = { route = Route.Home },
        )

        Route.Sync -> SyncScreen(
            ring = ring,
            onBack = { route = Route.Home },
            onSynced = { vm.reload() },
        )

        Route.Profile -> ProfileScreen(
            initial = s?.profile ?: ProfileStore.load(context),
            onSave = {
                ProfileStore.save(context, it)
                // profile.json feeds build_summary (BMR, VO₂max, the CVA demographics),
                // so a change means the summary has to be rebuilt.
                vm.reload()
            },
            onImportHealth = {
                HealthExport.importProfile(context) { imported, note ->
                    healthNote = note
                    imported?.let { ProfileStore.save(context, it); vm.reload() }
                }
            },
            healthExportEnabled = healthExportEnabled,
            onHealthExportChange = {
                healthExportEnabled = it
                HealthExport.setEnabled(context, it)
                healthNote = if (it) "Ring data will be written to Health Connect after each load."
                else "Health Connect export is off."
            },
            onRemoveHealthSamples = {
                HealthExport.removeAll(context) { note -> healthNote = note }
            },
            healthNote = healthNote,
            onBack = { route = Route.Home },
        )
    }
    }
}
