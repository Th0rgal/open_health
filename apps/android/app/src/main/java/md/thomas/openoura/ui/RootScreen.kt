package md.thomas.openoura.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import md.thomas.openoura.data.Summary
import md.thomas.openoura.data.VitalKind

/**
 * The home screen: one scrolling column, no bottom nav — the same shape as `RootView` in
 * apps/ios/OuraApp/OuraApp.swift. The hero is the most recent day; "show all N days"
 * opens the rest.
 */
@Composable
fun RootScreen(
    vm: SummaryViewModel,
    syncBusy: Boolean,
    recentlySynced: Boolean,
    onOpenSync: () -> Unit,
    onOpenProfile: () -> Unit,
    onOpenDay: (String, Boolean) -> Unit,
    onOpenAllDays: () -> Unit,
    onOpenSleepDebt: () -> Unit,
    onOpenVital: (VitalKind) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Obs.colors
    val s = vm.summary

    LazyColumn(
        modifier = modifier,
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        item {
            Header(
                loading = vm.loading,
                progress = vm.modelProgress,
                syncBusy = syncBusy,
                recentlySynced = recentlySynced,
                onOpenSync = onOpenSync,
                onOpenProfile = onOpenProfile,
            )
        }

        if (s == null) {
            item { EmptyNote("Loading…") }
            return@LazyColumn
        }

        s.error?.let { error ->
            item {
                Column(
                    Modifier.fillMaxWidth().obsCard(),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    ObsTag("no data yet")
                    Text(error, fontFamily = Obs.prose, fontSize = 14.sp, color = colors.ink2)
                    Text(
                        "Pair the ring and run a sync to populate the local database.",
                        fontFamily = Obs.prose,
                        fontSize = 13.sp,
                        color = colors.muted,
                    )
                }
            }
        }

        s.digest?.takeIf { it.isNotBlank() }?.let { digest ->
            item { Text(digest, fontFamily = Obs.prose, fontSize = 16.sp, color = colors.ink) }
        }

        val days = s.days
        days.firstOrNull()?.let { today ->
            item {
                TodayCard(
                    s = s,
                    day = today,
                    onSleep = { onOpenDay(today, true) },
                    onActivity = { onOpenDay(today, false) },
                )
            }
        }

        item { VitalsGrid(s, onOpenVital) }

        s.sleepDebt?.let { debt ->
            item { SleepDebtCard(debt, onOpenSleepDebt) }
        }

        s.illness?.let { illness ->
            item { IllnessCard(illness) }
        }

        item { CardioCard(s.cardio, s.fitness) }

        if (days.size > 1) {
            item {
                Text(
                    "show all ${days.size} days ›",
                    modifier = Modifier.clickable(onClick = onOpenAllDays),
                    fontFamily = Obs.mono,
                    fontSize = 13.sp,
                    color = colors.link,
                )
            }
        }

        if (s.modelErrors.isNotEmpty()) {
            item {
                Column(
                    Modifier.fillMaxWidth().obsCard(),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Rule("on-device models")
                    for (e in s.modelErrors) {
                        Text(e, fontFamily = Obs.mono, fontSize = 11.sp, color = colors.bad)
                    }
                }
            }
        }

        s.device?.let { device ->
            item {
                Column(
                    Modifier.fillMaxWidth().obsCard(),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Rule("device & data health")
                    ObsStat("serial", device.serial ?: "—")
                    ObsStat("firmware", device.firmware ?: "—")
                    ObsStat(
                        "battery",
                        device.batteryPct?.let { "$it%" } ?: "—",
                        accent = if ((device.batteryPct ?: 100) < 20) colors.bad else colors.ink,
                    )
                    ObsStat("synced", listOfNotNull(device.synced, device.syncedHm).joinToString(" "))
                    ObsStat("days of data", fmt(device.daysOfData))
                    ObsStat("nights", device.nights?.toString() ?: "—")
                }
            }
        }
    }
}

@Composable
private fun Header(
    loading: Boolean,
    progress: String?,
    syncBusy: Boolean,
    recentlySynced: Boolean,
    onOpenSync: () -> Unit,
    onOpenProfile: () -> Unit,
) {
    val colors = Obs.colors
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Open Oura",
                fontFamily = Obs.serif,
                fontSize = 26.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink,
            )
            Spacer(Modifier.width(10.dp))
            ObsTag("beta")
            Spacer(Modifier.weight(1f))
            Text(
                "profile",
                modifier = Modifier.clickable(onClick = onOpenProfile),
                fontFamily = Obs.mono,
                fontSize = 12.sp,
                color = colors.ink2,
            )
            Spacer(Modifier.width(14.dp))
            Row(
                modifier = Modifier.clickable(onClick = onOpenSync),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // The status light from iOS's SyncIndicatorButton: ink while busy, green
                // when a sync landed recently, otherwise a quiet outline.
                Box(
                    Modifier.size(8.dp).background(
                        when {
                            syncBusy -> colors.ink
                            recentlySynced -> colors.good
                            else -> colors.rule
                        },
                        CircleShape,
                    )
                )
                Spacer(Modifier.width(6.dp))
                Text("sync", fontFamily = Obs.mono, fontSize = 12.sp, color = colors.ink2)
            }
        }
        val note = progress ?: if (loading) "reading ring data…" else null
        if (note != null) {
            Text(note, fontFamily = Obs.mono, fontSize = 11.sp, color = colors.muted)
        }
    }
}

/** The 2×2 vitals grid: nightly HRV, heart rate, skin temp, blood O₂. */
@Composable
private fun VitalsGrid(s: Summary, onOpenVital: (VitalKind) -> Unit) {
    val kinds = listOf(VitalKind.HRV, VitalKind.HEART_RATE, VitalKind.TEMP, VitalKind.OXYGEN)
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        for (row in kinds.chunked(2)) {
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                for (kind in row) {
                    val points = kind.series(s)
                    VitalCell(
                        tag = kind.title,
                        value = fmt(points.lastOrNull()?.value, kind.decimals),
                        unit = kind.unit,
                        modifier = Modifier.weight(1f),
                        delta = when (kind) {
                            VitalKind.HRV -> s.vitals.hrv.deltaPct
                            VitalKind.HEART_RATE -> s.vitals.rhr.deltaPct
                            else -> null
                        },
                        series = points.map { it.value },
                        baseline = kind.baseline(s),
                        deltaGoodWhenPositive = kind.goodWhenPositive,
                        onClick = { onOpenVital(kind) },
                    )
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}
