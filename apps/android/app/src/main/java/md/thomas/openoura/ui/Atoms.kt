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
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Text
import kotlin.math.abs

// The small shared pieces of Theme.swift / Components.swift: ObsTag, ObsStat, Rule,
// VitalCell, SessionRow. Kept together so the Quiet Ink type scale lives in one place.

/** Small all-caps mono label with wide tracking. Port of `ObsTag`. */
@Composable
fun ObsTag(text: String, modifier: Modifier = Modifier, color: Color = Obs.colors.muted) {
    Text(
        text = text.uppercase(),
        modifier = modifier,
        fontFamily = Obs.mono,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        letterSpacing = 1.6.sp,
        color = color,
    )
}

/** A hairline with a small all-caps mono label riding it. Port of `Rule`. */
@Composable
fun Rule(text: String, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = text.uppercase(),
            fontFamily = Obs.mono,
            fontSize = 10.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 2.sp,
            color = colors.ink2,
        )
        Spacer(Modifier.width(10.dp))
        Box(
            Modifier
                .weight(1f)
                .height(0.5.dp)
                .background(colors.rule.copy(alpha = 0.5f))
        )
    }
}

/** Label on the left, mono value on the right. Port of `ObsStat`. */
@Composable
fun ObsStat(label: String, value: String, accent: Color = Obs.colors.ink, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.Bottom,
    ) {
        Text(label, fontFamily = Obs.mono, fontSize = 13.sp, color = Obs.colors.ink2)
        Spacer(Modifier.width(16.dp))
        Text(value, fontFamily = Obs.mono, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = accent)
    }
}

/** A vitals readout: big mono value, unit, delta vs baseline, sparkline. */
@Composable
fun VitalCell(
    tag: String,
    value: String,
    unit: String,
    modifier: Modifier = Modifier,
    delta: Double? = null,
    series: List<Double> = emptyList(),
    baseline: Double? = null,
    deltaGoodWhenPositive: Boolean = true,
    detail: String? = null,
    onClick: (() -> Unit)? = null,
) {
    val colors = Obs.colors
    val tone = colors.tone(delta, deltaGoodWhenPositive)
    Column(
        modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        ObsTag(tag)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                value,
                fontFamily = Obs.mono,
                fontSize = 26.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink,
            )
            Spacer(Modifier.width(4.dp))
            Text(unit, fontFamily = Obs.mono, fontSize = 11.sp, color = colors.ink2)
        }
        if (delta != null) {
            val sign = if (delta >= 0) "+" else ""
            Text(
                "$sign${"%.0f".format(delta)}% vs base",
                fontFamily = Obs.mono,
                fontSize = 10.sp,
                color = tone,
            )
        }
        if (detail != null) {
            Text(detail, fontFamily = Obs.mono, fontSize = 10.sp, color = colors.ink2)
        }
        if (series.size > 1) {
            Sparkline(series = series, accent = tone, baseline = baseline, trace = colors.rule)
        }
    }
}

/** A labelled activity/workout row: name, duration, start time. */
@Composable
fun SessionRow(label: String, durationMin: Int, startHM: String, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    Row(
        modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            actLabel(label),
            fontFamily = Obs.mono,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = colors.ink,
        )
        Spacer(Modifier.weight(1f))
        Text("$durationMin min", fontFamily = Obs.mono, fontSize = 12.sp, color = colors.ink2)
        Text(startHM, fontFamily = Obs.mono, fontSize = 11.sp, color = colors.muted)
    }
}

/** Capitalise an activity label's first letter for display. Port of `actLabel`. */
fun actLabel(s: String): String = if (s.isEmpty()) s else s[0].uppercase() + s.substring(1)

/** `12.3` / `47` — the mono number formatting used across the readouts. */
fun fmt(value: Double?, decimals: Int = 0, placeholder: String = "—"): String {
    if (value == null || !value.isFinite()) return placeholder
    return if (decimals > 0) "%.${decimals}f".format(value) else "${Math.round(value)}"
}

/** `7h 54m` from decimal hours. */
fun fmtHours(hours: Double?): String {
    if (hours == null || !hours.isFinite() || hours <= 0) return "—"
    val total = Math.round(hours * 60).toInt()
    return "${total / 60}h ${"%02d".format(total % 60)}m"
}

/** `2h 06m` / `54m` from minutes, for sleep debt and clinical metrics. */
fun fmtMinutes(minutes: Double?): String {
    if (minutes == null || !minutes.isFinite()) return "—"
    val total = Math.round(abs(minutes)).toInt()
    val sign = if (minutes < 0) "-" else ""
    return if (total >= 60) "$sign${total / 60}h ${"%02d".format(total % 60)}m" else "$sign${total}m"
}
