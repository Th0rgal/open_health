package md.thomas.openoura.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// thomas.md Quiet Ink: warm paper, serif titles, sans UI, mono numbers.
// Color is semantic, not decorative: gray when nothing is going on, green when
// something is genuinely good, orange/red when there is a problem.
//
// Port of apps/ios/OuraApp/Theme.swift — the hex values are shared verbatim, so a
// palette change belongs in both files.

@Immutable
data class ObsColors(
    // Paper / ink — same values as thomas.md.
    val paper: Color,
    val ink: Color,
    val ink2: Color,
    val muted: Color,
    val link: Color,
    val rule: Color,
    // Diagrams sit in the same ink family. Status uses the investing-post green/orange.
    val chart: Color,
    val good: Color,
    val bad: Color,
    val alert: Color,
    // Sleep stages keep distinct hues (deep / light / REM / wake). Other charts
    // stay gray unless a value is actually good or a problem.
    val deep: Color,
    val light: Color,
    val rem: Color,
    val wake: Color,
) {
    fun stage(s: Int): Color = when (s) {
        1 -> deep
        2 -> light
        3 -> rem
        else -> wake
    }

    /** Color a delta only when it is large enough to be worth noticing. */
    fun tone(delta: Double?, goodWhenPositive: Boolean = true, threshold: Double = 8.0): Color {
        if (delta == null) return chart
        if (kotlin.math.abs(delta) < threshold) return chart
        val isGood = if (delta >= 0) goodWhenPositive else !goodWhenPositive
        return if (isGood) good else bad
    }

    fun debt(state: String): Color = when (state) {
        "none" -> good
        "low" -> chart
        "moderate" -> bad
        "high" -> alert
        else -> chart
    }
}

private val LightColors = ObsColors(
    paper = Color(0xFFFBFAF6),
    ink = Color(0xFF26231E),
    ink2 = Color(0xFF57534B),
    muted = Color(0xFF6E695F),
    link = Color(0xFF2E2B26),
    rule = Color(0xFFE7E3DA),
    chart = Color(0xFF6E695F),
    good = Color(0xFF1BAF7A),
    bad = Color(0xFFEB6834),
    alert = Color(0xFFC4472C),
    deep = Color(0xFF104281),
    light = Color(0xFF6DA7EC),
    rem = Color(0xFF1BAF7A),
    wake = Color(0xFFEDA100),
)

private val DarkColors = ObsColors(
    paper = Color(0xFF131110),
    ink = Color(0xFFEFEBE2),
    ink2 = Color(0xFFCFC9BF),
    muted = Color(0xFFA8A195),
    link = Color(0xFFE3DDD2),
    rule = Color(0xFF2C2925),
    chart = Color(0xFFA8A195),
    good = Color(0xFF2EC48C),
    bad = Color(0xFFE07A4A),
    alert = Color(0xFFE06A4F),
    deep = Color(0xFF5598E7),
    light = Color(0xFF9EC5F4),
    rem = Color(0xFF2EC48C),
    wake = Color(0xFFEDA100),
)

val LocalObsColors = staticCompositionLocalOf { LightColors }

object Obs {
    val colors: ObsColors
        @Composable @ReadOnlyComposable get() = LocalObsColors.current

    // iOS uses New York (system serif) and SF Mono. Android has neither, so we take
    // the platform's closest equivalents rather than shipping lookalike webfonts.
    val serif = FontFamily.Serif
    val mono = FontFamily.Monospace
    val prose = FontFamily.SansSerif

    val cardRadius = 10.dp
    val cardPadding = 18.dp
}

@Composable
fun OpenOuraTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalObsColors provides if (dark) DarkColors else LightColors, content = content)
}

/** `.obsCard()` from Theme.swift: paper fill, 1px hairline, 10dp radius. */
@Composable
fun Modifier.obsCard(padding: Dp = Obs.cardPadding, radius: Dp = Obs.cardRadius): Modifier {
    val c = Obs.colors
    val shape = RoundedCornerShape(radius)
    return this
        .background(c.paper, shape)
        .border(BorderStroke(1.dp, c.rule), shape)
        .padding(padding)
}
