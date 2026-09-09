package md.thomas.openoura.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import md.thomas.openoura.data.Cardio
import md.thomas.openoura.data.Fitness
import md.thomas.openoura.data.IllnessResult
import md.thomas.openoura.data.SleepDebtSummary
import md.thomas.openoura.data.Summary
import kotlin.math.abs
import kotlin.math.roundToInt

// The home-screen cards: one day = last night + that day's activity, then sleep debt,
// Symptom Radar and the cardiovascular readout. Ports of `TodayCard`, `SleepDebtCard`,
// `IllnessCard` and the cardio section in apps/ios/OuraApp/OuraApp.swift + Reports.swift.

/**
 * One card = last night's sleep + that day's activity, each half tappable. The day unit
 * is defined by wake date — see "The day is one unit" in docs/clients.md.
 */
@Composable
fun TodayCard(
    s: Summary,
    day: String,
    onSleep: () -> Unit,
    onActivity: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Obs.colors
    val night = s.nightForDay(day)
    val daily = s.activityDaily[day]
    val profile = s.activityProfile[day].orEmpty()
    val sessions = s.workoutsOn(day)

    Column(modifier.fillMaxWidth().obsCard(), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            ObsTag("today")
            Text(day, fontFamily = Obs.mono, fontSize = 11.sp, color = colors.muted)
        }

        // ── night half ──
        Column(
            Modifier.fillMaxWidth().clickable(onClick = onSleep),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                Text(
                    fmtHours(night?.inBedH),
                    fontFamily = Obs.mono,
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.ink,
                )
                Spacer(Modifier.width(8.dp))
                Text("in bed", fontFamily = Obs.mono, fontSize = 11.sp, color = colors.ink2)
                Spacer(Modifier.weight(1f))
                if (night != null) {
                    Text(
                        "${night.start ?: "—"} → ${night.end ?: "—"}",
                        fontFamily = Obs.mono,
                        fontSize = 12.sp,
                        color = colors.ink2,
                    )
                }
            }
            val stages = night?.stages
            if (stages != null && stages.size > 1) {
                Hypnogram(stages, height = 34.dp)
            } else if (night?.efficiency != null) {
                ObsStat("efficiency", "${night.efficiency!!.roundToInt()}%")
            } else if (night == null) {
                EmptyNote("No sleep recorded for this morning.")
            }
        }

        Box(Modifier.fillMaxWidth().height(0.5.dp).background(colors.rule))

        // ── activity half ──
        Column(
            Modifier.fillMaxWidth().clickable(onClick = onActivity),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                Text(
                    fmtSteps(daily?.steps),
                    fontFamily = Obs.mono,
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.ink,
                )
                Spacer(Modifier.width(8.dp))
                Text("steps", fontFamily = Obs.mono, fontSize = 11.sp, color = colors.ink2)
                Spacer(Modifier.weight(1f))
                Text(
                    "${fmt(daily?.activeKcal)} kcal",
                    fontFamily = Obs.mono,
                    fontSize = 12.sp,
                    color = colors.ink2,
                )
            }
            if (profile.size > 1) MovementRidge(profile, height = 40.dp)
            for (w in sessions.take(2)) SessionRow(w.label, w.durationMin, w.startHM)
        }
    }
}

@Composable
fun SleepDebtCard(debt: SleepDebtSummary, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    Column(
        modifier.fillMaxWidth().obsCard().clickable(onClick = onOpen),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            ObsTag("sleep debt")
            Text(
                "${debt.validDays}/${debt.windowDays} days",
                fontFamily = Obs.mono,
                fontSize = 10.sp,
                color = colors.muted,
            )
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                if (debt.valid) fmtMinutes(debt.debtMin) else "—",
                fontFamily = Obs.mono,
                fontSize = 26.sp,
                fontWeight = FontWeight.Medium,
                color = colors.debt(debt.state),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                "need ${"%.1f".format(debt.needH)} h",
                fontFamily = Obs.mono,
                fontSize = 11.sp,
                color = colors.ink2,
            )
        }
        Text(
            if (debt.valid) debtStateCopy(debt.state)
            else "Not enough staged nights yet — at least five of the last 14 days are needed.",
            fontFamily = Obs.prose,
            fontSize = 13.sp,
            color = colors.ink2,
        )
    }
}

/** Symptom Radar — the on-device illness detection readout. */
@Composable
fun IllnessCard(illness: IllnessResult, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    val tone = when (illness.trafficLight) {
        "MAJOR_SIGNS" -> colors.alert
        "MINOR_SIGNS" -> colors.bad
        else -> colors.good
    }
    Column(modifier.fillMaxWidth().obsCard(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ObsTag("symptom radar")
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(8.dp).background(tone, CircleShape))
        }
        Text(illnessCopy(illness), fontFamily = Obs.prose, fontSize = 14.sp, color = colors.ink)
        if (!illness.available) return@Column
        for (b in illness.biomarkers) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(
                        biomarkerName(b.type),
                        fontFamily = Obs.mono,
                        fontSize = 11.sp,
                        color = colors.ink2,
                    )
                    Text(
                        "%.1f".format(b.value) + (b.reason?.let { " · ${it.lowercase()}" } ?: ""),
                        fontFamily = Obs.mono,
                        fontSize = 11.sp,
                        color = if (b.indicatesSymptoms) colors.bad else colors.ink2,
                    )
                }
                RangeTrack(b.value, b.lower, b.upper, b.indicatesSymptoms)
            }
        }
    }
}

@Composable
fun CardioCard(cardio: Cardio?, fitness: Fitness?, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    Column(modifier.fillMaxWidth().obsCard(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Rule("cardiovascular")
        if (cardio?.vascularAge == null) {
            EmptyNote("Cardiovascular age needs the on-device model build.")
        } else {
            val delta = cardio.chronologicalAge?.let { cardio.vascularAge!! - it }
            ObsStat("vascular age", "%.1f".format(cardio.vascularAge), accent = colors.ink)
            if (delta != null) {
                val years = "%.1f".format(abs(delta))
                ObsStat(
                    "vs your age",
                    if (delta <= 0) "$years yr younger" else "$years yr older",
                    accent = if (delta <= 0) colors.good else colors.bad,
                )
            }
            cardio.pwvMs?.let { ObsStat("pulse-wave velocity", "%.1f m/s".format(it)) }
            cardio.segments?.let { ObsStat("segments analysed", "$it") }
        }
        fitness?.vo2max?.let { ObsStat("vo₂max", "%.1f".format(it)) }
    }
}

internal fun debtStateCopy(state: String): String = when (state) {
    "high" -> "Your sleep debt is high right now. Prioritize several consistent nights with enough sleep."
    "moderate" -> "You've built up a moderate amount of sleep debt. A few longer nights can help you recover."
    "low" -> "You're mostly meeting your sleep need, with a small amount left to recover."
    else -> "You've met your sleep need consistently over the past two weeks."
}

internal fun illnessCopy(illness: IllnessResult): String = when (illness.status) {
    "MAJOR_SIGNS" -> "Several biomarkers are outside your normal range."
    "MINOR_SIGNS" -> "A biomarker or two is drifting from your normal range."
    "NO_SIGNS" -> "Nothing unusual in last night's biomarkers."
    "MISSING_LAST_NIGHT_SLEEP" -> "No sleep recorded last night, so there is nothing to compare."
    else -> "Not enough recent nights to establish your normal range yet."
}

internal fun biomarkerName(type: String): String = when (type) {
    "AverageBreath" -> "respiratory rate"
    "LowestHeartRate" -> "lowest heart rate"
    "AverageHrv" -> "hrv"
    "TemperatureDeviation" -> "skin temp deviation"
    else -> type
}
