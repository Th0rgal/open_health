package md.thomas.openoura.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import md.thomas.openoura.data.NightRow
import md.thomas.openoura.data.Sleep
import md.thomas.openoura.data.Summary
import md.thomas.openoura.data.WakingActivityTimeline
import md.thomas.openoura.data.clockLabel
import md.thomas.openoura.data.wakingActivityTimeline
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Full-page, research-grade sleep & activity reports — the Android counterpart to
// apps/ios/OuraApp/Reports.swift and the web dashboard's `sleepReport`/`activityReport`.
// The raw per-night signal series arrive from build_summary (NightRow.series); the
// hypnogram is the on-device SleepNet output (NightRow.stages, `full` flavor).

/** A big mono datum with a tiny uppercase caption — the readout atom. */
@Composable
fun Readout(value: String, caption: String, accent: Color = Obs.colors.ink, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(value, fontFamily = Obs.mono, fontSize = 20.sp, fontWeight = FontWeight.Medium, color = accent)
        Text(
            caption.uppercase(),
            fontFamily = Obs.mono,
            fontSize = 9.sp,
            letterSpacing = 1.2.sp,
            color = Obs.colors.ink2,
        )
    }
}

@Composable
private fun ReadoutRow(items: List<Pair<String, String>>) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        for ((value, caption) in items) {
            Readout(value, caption, modifier = Modifier.weight(1f))
        }
    }
}

/** Sleep ⇄ Activity, the two halves of one day. Port of `DayReportView`. */
@Composable
fun DayReportScreen(
    s: Summary,
    day: String,
    startOnSleep: Boolean,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Obs.colors
    var sleep by remember(day) { mutableStateOf(startOnSleep) }

    Column(modifier.fillMaxSize().background(colors.paper)) {
        Row(
            Modifier.fillMaxWidth().padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "‹ back",
                modifier = Modifier.clickable(onClick = onBack),
                fontFamily = Obs.mono,
                fontSize = 13.sp,
                color = colors.ink2,
            )
            Text(day, fontFamily = Obs.mono, fontSize = 13.sp, color = colors.muted)
            Spacer(Modifier.weight(1f))
            Segmented(
                options = listOf("Sleep", "Activity"),
                selectedIndex = if (sleep) 0 else 1,
                onSelect = { sleep = it == 0 },
            )
        }
        LazyColumn(
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            if (sleep) {
                val night = s.nightForDay(day)
                if (night == null) {
                    item { EmptyNote("No sleep recorded for this morning.") }
                } else {
                    item { SleepReport(s, night) }
                }
            } else {
                item { ActivityReport(s, day) }
            }
        }
    }
}

@Composable
fun SleepReport(s: Summary, night: NightRow, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    val smoothed = remember(night) { night.stages?.takeIf { it.size > 1 }?.let { Sleep.smooth(it, 5) } }
    val metrics = remember(night, smoothed) {
        smoothed?.let { Sleep.metrics(it, (night.inBedH ?: 0.0) * 3600) }
    }
    val autonomic = remember(night, smoothed) {
        smoothed?.let {
            Sleep.autonomic(
                hr = night.series?.hr ?: emptyList(),
                hrv = night.series?.hrv ?: emptyList(),
                stages = it,
            )
        }
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        ReadoutRow(
            listOf(
                fmtHours(night.inBedH) to "in bed",
                fmtMinutes(metrics?.asleepMin) to "asleep",
                (night.efficiency?.let { "${it.roundToInt()}%" } ?: "—") to "efficiency",
                (night.start ?: "—") to "bedtime",
            )
        )

        if (smoothed != null) {
            Rule("polysomnograph")
            Polysomnograph(night)
            StageLegend()
            StageBar(night.deepPct, night.lightPct, night.remPct, night.wakePct)
            ReadoutRow(
                listOf(
                    pct(night.deepPct) to "deep",
                    pct(night.lightPct) to "light",
                    pct(night.remPct) to "rem",
                    pct(night.wakePct) to "awake",
                )
            )
        } else {
            // The model-free (`lite`) build has no hypnogram — say so rather than
            // rendering an empty chart frame.
            EmptyNote(
                "Sleep staging needs the on-device model build. The raw signals below still " +
                    "come from the shared core."
            )
            night.series?.let { if (it.hr.size > 1) Polysomnograph(night) }
        }

        metrics?.let { m ->
            Rule("clinical")
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ObsStat("sleep onset", fmtMinutes(m.solMin))
                ObsStat("rem latency", fmtMinutes(m.remLatencyMin))
                ObsStat("waso", fmtMinutes(m.wasoMin))
                ObsStat("awakenings", "${m.awakenings}")
                ObsStat("cycles", "${m.cycles}")
                ObsStat("fragmentation", "%.1f /h".format(m.fragIndex))
            }
        }

        if (autonomic?.any == true) {
            Rule("autonomic recovery")
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ObsStat("hrv · deep", fmt(autonomic.hrvDeep) + " ms")
                ObsStat("hrv · light", fmt(autonomic.hrvLight) + " ms")
                ObsStat("hrv · rem", fmt(autonomic.hrvRem) + " ms")
                ObsStat("hr · deep", fmt(autonomic.hrDeep) + " bpm")
                ObsStat("hr · light", fmt(autonomic.hrLight) + " bpm")
                ObsStat("hr · rem", fmt(autonomic.hrRem) + " bpm")
            }
            Text(
                "Deep-sleep HRV is the recovery-relevant number. A single overnight HRV " +
                    "trend is deliberately not shown: nocturnal HRV is stage-driven, so a " +
                    "slope tracks stage order rather than recovery.",
                fontFamily = Obs.prose,
                fontSize = 12.sp,
                color = colors.muted,
            )
        }

        metrics?.let { m ->
            Rule("interpretation")
            for (line in sleepInterpretation(night, m)) {
                Text(line, fontFamily = Obs.prose, fontSize = 14.sp, color = colors.ink2)
            }
        }

        s.sleepDebt?.takeIf { it.valid }?.let { debt ->
            Text(
                "Sleep debt over the last ${debt.windowDays} days: ${fmtMinutes(debt.debtMin)} " +
                    "against a nightly need of ${"%.1f".format(debt.needH)} h.",
                fontFamily = Obs.prose,
                fontSize = 13.sp,
                color = colors.muted,
            )
        }
    }
}

@Composable
private fun StageLegend() {
    val colors = Obs.colors
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        for ((code, name) in listOf(1 to "deep", 2 to "light", 3 to "rem", 4 to "awake")) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Box(Modifier.width(10.dp).height(3.dp).background(colors.stage(code)))
                Text(name, fontFamily = Obs.mono, fontSize = 10.sp, color = colors.ink2)
            }
        }
    }
}

@Composable
fun ActivityReport(s: Summary, day: String, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    val daily = s.activityDaily[day]
    val timeline = remember(s, day) { s.wakingActivityTimeline(day) }
    val sessions = s.workoutsOn(day)

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        ReadoutRow(
            listOf(
                fmtSteps(daily?.steps) to "steps",
                fmt(daily?.activeKcal) to "active kcal",
                fmt(daily?.totalKcal) to "total kcal",
                fmtKm(daily?.distanceM) to "distance",
            )
        )

        Rule("waking day")
        MetProfile(timeline)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(timeline.startCaption, fontFamily = Obs.mono, fontSize = 10.sp, color = colors.ink2)
            Text(timeline.endCaption, fontFamily = Obs.mono, fontSize = 10.sp, color = colors.ink2)
        }

        val points = timeline.points.map { it.met }
        if (points.isNotEmpty()) {
            // 3 MET above rest is the conventional moderate-intensity threshold; 1.5 is
            // the light/sedentary boundary. Bucket width comes from the profile's own
            // resolution (96 × 15 min in the shared summary).
            val bucketMin = if (points.size > 1) 24.0 * 60 / (s.activityProfile[day]?.size ?: 96) else 15.0
            ReadoutRow(
                listOf(
                    "${(points.count { it >= 3.0 } * bucketMin).roundToInt()}m" to "active",
                    "${(points.count { it in 1.5..3.0 } * bucketMin).roundToInt()}m" to "lightly active",
                    "%.1f".format(points.max()) to "peak met",
                )
            )
        }

        Rule("detected sessions")
        if (sessions.isEmpty()) {
            EmptyNote(
                "No sessions detected for this day. Automatic activity detection needs the " +
                    "on-device model build."
            )
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for (w in sessions) SessionRow(w.label, w.durationMin, w.startHM)
            }
        }
    }
}

/**
 * The waking-day MET curve. Unlike the calendar-day ridge on the home card, this one
 * runs wake → bed and crosses midnight when it needs to.
 */
@Composable
fun MetProfile(timeline: WakingActivityTimeline, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    Canvas(modifier.fillMaxWidth().height(120.dp)) {
        val pts = timeline.points
        if (pts.size < 2) return@Canvas
        val span = max(timeline.endHour - timeline.startHour, 1e-6)
        val peak = max(pts.maxOf { it.met }, 1.0)

        drawHGrid(colors.rule)

        fun pt(i: Int) = Offset(
            (size.width * ((pts[i].hour - timeline.startHour) / span)).toFloat().coerceIn(0f, size.width),
            (size.height * (1 - min(1.0, pts[i].met / peak))).toFloat(),
        )

        val line = Path().apply {
            moveTo(pt(0).x, pt(0).y)
            for (i in 1 until pts.size) lineTo(pt(i).x, pt(i).y)
        }
        val area = Path().apply {
            addPath(line)
            lineTo(pt(pts.size - 1).x, size.height)
            lineTo(pt(0).x, size.height)
            close()
        }
        drawPath(area, colors.chart.copy(alpha = 0.14f))
        drawPath(line, colors.chart.copy(alpha = 0.9f), style = Stroke(1.3f, join = StrokeJoin.Round))
    }
}

/** A small segmented control in the Quiet Ink idiom (Material's is far too loud). */
@Composable
fun Segmented(options: List<String>, selectedIndex: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    Row(
        modifier.background(colors.paper, RoundedCornerShape(6.dp)),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        options.forEachIndexed { i, label ->
            val selected = i == selectedIndex
            Text(
                label,
                modifier = Modifier
                    .clickable { onSelect(i) }
                    .background(
                        if (selected) colors.ink.copy(alpha = 0.08f) else Color.Transparent,
                        RoundedCornerShape(6.dp),
                    )
                    .padding(horizontal = 10.dp, vertical = 5.dp),
                fontFamily = Obs.mono,
                fontSize = 12.sp,
                fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
                color = if (selected) colors.ink else colors.muted,
            )
        }
    }
}

@Composable
fun EmptyNote(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier = modifier.fillMaxWidth(),
        fontFamily = Obs.prose,
        fontSize = 13.sp,
        color = Obs.colors.muted,
    )
}

private fun pct(v: Double?): String = v?.let { "${it.roundToInt()}%" } ?: "—"

internal fun fmtSteps(steps: Double?): String {
    if (steps == null || !steps.isFinite()) return "—"
    return if (steps >= 10_000) "%.1fk".format(steps / 1000) else "${steps.roundToInt()}"
}

internal fun fmtKm(metres: Double?): String {
    if (metres == null || !metres.isFinite()) return "—"
    return "%.1f km".format(metres / 1000)
}

/**
 * Plain-language reading of one night. Deliberately conservative: it describes what the
 * hypnogram shows rather than scoring it, matching the tone of the web report.
 */
internal fun sleepInterpretation(night: NightRow, m: md.thomas.openoura.data.SleepMetrics): List<String> {
    val out = ArrayList<String>()
    out.add(
        "You were in bed for ${fmtHours(night.inBedH)} and asleep for ${fmtMinutes(m.asleepMin)}, " +
            "falling asleep in ${fmtMinutes(m.solMin)}."
    )
    m.remLatencyMin?.let {
        out.add("First REM arrived ${fmtMinutes(it)} after sleep onset, across ${m.cycles} cycle(s).")
    }
    out.add(
        "You were awake for ${fmtMinutes(m.wasoMin)} after first falling asleep, " +
            "in ${m.awakenings} awakening(s)."
    )
    m.deepFirstHalfPct?.let {
        val where = if (it >= 60) "front-loaded, as it usually is" else "spread through the night"
        out.add("Deep sleep was $where (${it.roundToInt()}% of it in the first half).")
    }
    m.remFirstHalfPct?.let {
        if (it <= 40) out.add("REM was concentrated in the second half, the normal pattern.")
    }
    return out
}
