package md.thomas.openoura.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import md.thomas.openoura.data.NightRow
import md.thomas.openoura.data.Sleep
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// The polysomnograph: hypnogram + aligned signal lanes + a scrubber. Port of the
// `Polysomnograph` / `HypnoCanvas` / `SignalCanvas` views in apps/ios/OuraApp/Reports.swift.
//
// One deliberate divergence, already noted in docs/clients.md: the web has a hover
// crosshair, while touch clients use a drag scrubber. Same idea, adapted to the input.

private val GUTTER_W = 76.dp
private val HYP_H = 84.dp
private val LANE_H = 44.dp
private val AXIS_H = 18.dp

private class SignalLane(val v: List<Double>, val color: Color, val dp: Int, val span: List<Double>)
private class Lane(val label: String, val unit: String, val signal: SignalLane?, val stages: List<Int>?)

@Composable
fun Polysomnograph(night: NightRow, modifier: Modifier = Modifier) {
    val colors = Obs.colors
    val lanes = remember(night) { buildLanes(night, colors.chart) }
    if (lanes.isEmpty()) return

    val win = remember(night) { nightWindow(night) }
    var cursorF by remember { mutableStateOf<Float?>(null) }

    val totalH = lanes.fold(0.dp) { acc, l -> acc + if (l.stages != null) HYP_H else LANE_H } + AXIS_H
    val density = LocalDensity.current
    var plotWidthPx by remember { mutableFloatStateOf(1f) }
    val bubbleHalfWidthPx = with(density) { 18.dp.toPx() }

    Box(
        modifier
            .fillMaxWidth()
            .height(totalH)
            .onSizeChanged { plotWidthPx = max(1f, it.width - with(density) { GUTTER_W.toPx() }) }
            .pointerInput(lanes.size) {
                val gutterPx = with(density) { GUTTER_W.toPx() }
                val plotPx = max(1f, size.width - gutterPx)
                detectDragGestures(
                    onDragStart = { pos ->
                        cursorF = ((pos.x - gutterPx) / plotPx).coerceIn(0f, 1f)
                    },
                    onDrag = { change, _ ->
                        cursorF = ((change.position.x - gutterPx) / plotPx).coerceIn(0f, 1f)
                    },
                    onDragEnd = { cursorF = null },
                    onDragCancel = { cursorF = null },
                )
            }
    ) {
        Column(Modifier.fillMaxSize()) {
            lanes.forEachIndexed { i, lane ->
                LaneRow(lane, cursorF)
                if (i < lanes.size - 1) {
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .height(0.5.dp)
                            .background(colors.rule.copy(alpha = 0.25f))
                    )
                }
            }
            AxisRow(win)
        }

        cursorF?.let { f ->
            // The scrubber overlay sits above the lanes, inset past the label gutter so
            // its x maps 1:1 onto the plot area the lanes draw into.
            Box(Modifier.padding(start = GUTTER_W).fillMaxSize()) {
                Canvas(Modifier.fillMaxSize()) {
                    val x = size.width * f
                    val h = size.height - with(density) { AXIS_H.toPx() }
                    drawLine(colors.ink.copy(alpha = 0.85f), Offset(x, 0f), Offset(x, h), strokeWidth = 1f)
                }
                Text(
                    text = clockAt(win, f.toDouble()),
                    modifier = Modifier
                        .offset {
                            // centre the bubble on the cursor, clamped inside the plot
                            val half = bubbleHalfWidthPx
                            IntOffset(
                                ((plotWidthPx * f) - half).toInt().coerceIn(0, (plotWidthPx - half * 2).toInt().coerceAtLeast(0)),
                                0,
                            )
                        }
                        .background(colors.ink, RoundedCornerShape(4.dp))
                        .padding(horizontal = 5.dp, vertical = 1.dp),
                    fontFamily = Obs.mono,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.paper,
                )
            }
        }
    }
}

@Composable
private fun LaneRow(lane: Lane, cursorF: Float?) {
    val colors = Obs.colors
    val h = if (lane.stages != null) HYP_H else LANE_H
    Row(Modifier.fillMaxWidth().height(h)) {
        Column(Modifier.width(GUTTER_W)) {
            Text(lane.label, fontFamily = Obs.mono, fontSize = 10.sp, color = colors.ink2)
            Text(
                gutterValue(lane, cursorF),
                fontFamily = Obs.mono,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink,
            )
        }
        Box(Modifier.weight(1f).height(h)) {
            when {
                lane.stages != null -> HypnoCanvas(lane.stages, colors)
                lane.signal != null -> SignalCanvas(lane.signal, colors.rule)
            }
        }
    }
}

@Composable
private fun AxisRow(win: NightWindow) {
    val colors = Obs.colors
    Row(Modifier.fillMaxWidth().height(AXIS_H)) {
        Box(Modifier.width(GUTTER_W))
        Box(Modifier.weight(1f).fillMaxWidth()) {
            val ticks = hourTicks(win)
            Canvas(Modifier.fillMaxSize()) {
                for (t in ticks) {
                    val x = size.width * ((t - win.a).toFloat() / win.span)
                    drawLine(
                        colors.rule.copy(alpha = 0.5f),
                        Offset(x, 0f),
                        Offset(x, size.height * 0.4f),
                        strokeWidth = 0.5f,
                    )
                }
            }
        }
    }
}

/** Stepped clinical hypnogram: y = stage level (Awake top → Deep bottom), coloured runs. */
@Composable
private fun HypnoCanvas(stages: List<Int>, colors: ObsColors) {
    Canvas(Modifier.fillMaxSize()) {
        val n = stages.size
        if (n <= 1) return@Canvas
        val padT = 8f
        val plotH = size.height - 16f
        fun lvl(c: Int) = when (c) { 1 -> 3f; 2 -> 2f; 3 -> 1f; else -> 0f }
        fun yOf(l: Float) = padT + l / 3f * plotH
        fun xOf(i: Int) = size.width * i / (n - 1).toFloat()

        for (l in 0..3) {
            val y = yOf(l.toFloat())
            drawLine(colors.rule.copy(alpha = 0.25f), Offset(0f, y), Offset(size.width, y), strokeWidth = 0.5f)
        }

        var i = 0
        var prev: Float? = null
        while (i < n) {
            val code = stages[i]
            var j = i
            while (j < n && stages[j] == code) j++
            val x1 = xOf(i)
            val x2 = xOf(min(j, n - 1))
            val y = yOf(lvl(code))
            prev?.let { p ->
                drawLine(colors.rule.copy(alpha = 0.6f), Offset(x1, p), Offset(x1, y), strokeWidth = 0.8f)
            }
            drawLine(colors.stage(code), Offset(x1, y), Offset(x2, y), strokeWidth = 2.2f)
            prev = y
            i = j
        }
    }
}

/** Auto-scaled polyline + faint fill + dashed mean for one signal lane. */
@Composable
private fun SignalCanvas(s: SignalLane, ruleColor: Color) {
    Canvas(Modifier.fillMaxSize()) {
        val v = s.v
        if (v.size <= 1) return@Canvas
        val lo = v.min()
        val hi = v.max()
        val rng = max(hi - lo, 1e-6)
        val pad = 5f
        fun pt(i: Int) = Offset(
            (size.width * (s.span[0] + (s.span[1] - s.span[0]) * i / (v.size - 1).toDouble())).toFloat(),
            pad + (1f - ((v[i] - lo) / rng).toFloat()) * (size.height - 2 * pad),
        )

        val line = Path().apply {
            moveTo(pt(0).x, pt(0).y)
            for (i in 1 until v.size) lineTo(pt(i).x, pt(i).y)
        }
        val x0 = (size.width * s.span[0]).toFloat()
        val x1 = (size.width * s.span[1]).toFloat()
        val area = Path().apply {
            addPath(line)
            lineTo(x1, size.height)
            lineTo(x0, size.height)
            close()
        }
        drawPath(area, s.color.copy(alpha = 0.10f))

        val mean = v.sum() / v.size
        val my = pad + (1f - ((mean - lo) / rng).toFloat()) * (size.height - 2 * pad)
        drawLine(
            s.color.copy(alpha = 0.4f),
            Offset(x0, my),
            Offset(x1, my),
            strokeWidth = 0.6f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(3f, 3f)),
        )
        drawPath(line, s.color, style = Stroke(1.3f))
    }
}

private fun buildLanes(night: NightRow, chart: Color): List<Lane> {
    val out = ArrayList<Lane>()
    night.stages?.takeIf { it.size > 1 }?.let {
        out.add(Lane("Hypnogram", "", null, Sleep.smooth(it, 5)))
    }
    fun sig(label: String, unit: String, v: List<Double>?, dp: Int = 0, span: List<Double>? = null) {
        if (v == null || v.size <= 1) return
        // `temp_span` records the actual coverage inside an extended sleep window, so we
        // leave a visible gap after the last trustworthy sample rather than stretching the
        // series across the whole night. See docs/clients.md.
        val coverage = span?.takeIf { it.size == 2 } ?: listOf(0.0, 1.0)
        out.add(Lane(label, unit, SignalLane(v, chart, dp, coverage), null))
    }
    val s = night.series
    sig("Heart rate", "bpm", s?.hr)
    sig("HRV", "ms", s?.hrv)
    sig("Blood O₂", "%", s?.spo2)
    sig("Skin temp", "°C", s?.temp, dp = 1, span = s?.tempSpan)
    sig("Motion", "s", s?.motion)
    return out
}

private fun gutterValue(lane: Lane, cursorF: Float?): String {
    lane.stages?.let { st ->
        val f = cursorF ?: return ""
        val code = st[(f * (st.size - 1)).toInt().coerceIn(0, st.size - 1)]
        return stageName(code)
    }
    val s = lane.signal ?: return ""
    fun format(x: Double) = if (s.dp > 0) "%.${s.dp}f".format(x) else "${x.roundToInt()}"
    if (cursorF != null) {
        val f = cursorF.toDouble()
        if (f < s.span[0] || f > s.span[1]) return "—"
        val local = (f - s.span[0]) / max(1e-9, s.span[1] - s.span[0])
        val v = s.v[(local * (s.v.size - 1)).toInt().coerceIn(0, s.v.size - 1)]
        return "${format(v)} ${lane.unit}"
    }
    return "${format(s.v.sum() / s.v.size)} ${lane.unit}"
}

// ── time helpers (ports of the private helpers in Reports.swift) ─────────────

internal class NightWindow(val a: Int, val b: Int, val span: Int)

internal fun hm2min(s: String?): Int {
    val p = (s ?: "0:0").split(":").map { it.toIntOrNull() ?: 0 }
    return (p.firstOrNull() ?: 0) * 60 + (if (p.size > 1) p[1] else 0)
}

internal fun nightWindow(n: NightRow): NightWindow {
    val a = hm2min(n.start)
    var b = hm2min(n.end)
    if (b <= a) b += 1440
    return NightWindow(a, b, max(1, b - a))
}

internal fun clockAt(win: NightWindow, f: Double): String {
    val t = (win.a + (win.span * f).roundToInt()) % 1440
    return "%02d:%02d".format(t / 60, t % 60)
}

internal fun hourTicks(win: NightWindow): List<Int> {
    var t = ((win.a + 59) / 60) * 60
    val out = ArrayList<Int>()
    while (t <= win.b) {
        out.add(t)
        t += 60
    }
    return out
}

internal fun stageName(c: Int): String = when (c) {
    1 -> "Deep"
    2 -> "Light"
    3 -> "REM"
    else -> "Awake"
}
