package md.thomas.openoura.ui

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import md.thomas.openoura.data.DatedVital
import md.thomas.openoura.data.Profile
import md.thomas.openoura.data.SleepDebtSummary
import md.thomas.openoura.data.Summary
import md.thomas.openoura.data.VitalKind
import java.time.LocalDate
import kotlin.math.roundToInt

// The detail destinations: previous-days browser, vital trend, sleep-debt detail, the
// sync screen and the profile editor. Ports of `AllDaysView`, `VitalTrendView`,
// `SleepDebtDetail`, `SyncView` and `ProfileSettingsView` from the iOS app.

/** A full-screen destination with the standard back affordance. */
@Composable
fun Sheet(title: String, onBack: () -> Unit, content: @Composable () -> Unit) {
    val colors = Obs.colors
    Column(Modifier.fillMaxSize().background(colors.paper)) {
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
            Text(
                title,
                fontFamily = Obs.serif,
                fontSize = 20.sp,
                fontWeight = FontWeight.Medium,
                color = colors.ink,
            )
        }
        content()
    }
}

/** Every day, newest first — mini hypnogram plus steps/kcal, opening the full report. */
@Composable
fun AllDaysScreen(s: Summary, onOpenDay: (String) -> Unit, onBack: () -> Unit) {
    val colors = Obs.colors
    Sheet("All days", onBack) {
        LazyColumn(
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            items(s.days.size) { index ->
                val day = s.days[index]
                val night = s.nightForDay(day)
                val daily = s.activityDaily[day]
                Column(
                    Modifier.fillMaxWidth().obsCard().clickable { onOpenDay(day) },
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(day, fontFamily = Obs.mono, fontSize = 13.sp, color = colors.ink)
                        Text(
                            fmtHours(night?.inBedH),
                            fontFamily = Obs.mono,
                            fontSize = 13.sp,
                            color = colors.ink2,
                        )
                    }
                    night?.stages?.takeIf { it.size > 1 }?.let { Hypnogram(it, height = 26.dp) }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text(
                            "${fmtSteps(daily?.steps)} steps",
                            fontFamily = Obs.mono,
                            fontSize = 11.sp,
                            color = colors.muted,
                        )
                        Text(
                            "${fmt(daily?.activeKcal)} kcal",
                            fontFamily = Obs.mono,
                            fontSize = 11.sp,
                            color = colors.muted,
                        )
                    }
                }
            }
        }
    }
}

enum class VitalPeriod(val label: String, val days: Int?) {
    D7("7d", 7), D14("14d", 14), D30("30d", 30), D90("90d", 90), ALL("all", null)
}

@Composable
fun VitalTrendScreen(s: Summary, kind: VitalKind, onBack: () -> Unit) {
    val colors = Obs.colors
    var period by remember { mutableStateOf(VitalPeriod.D30) }
    val all = remember(s, kind) { kind.series(s) }

    // Inclusive window ending on the latest SAMPLE, not wall-clock today — so a ring that
    // last synced weeks ago still has a 7d/30d chart to look at.
    val points = remember(all, period) {
        val end = all.lastOrNull()?.date ?: return@remember emptyList<DatedVital>()
        val days = period.days ?: return@remember all
        val start = try {
            LocalDate.parse(end).minusDays((days - 1).toLong()).toString()
        } catch (_: Exception) {
            return@remember all
        }
        all.filter { it.date in start..end }
    }

    Sheet(kind.title, onBack) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(start = 20.dp, end = 20.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Text(kind.caption, fontFamily = Obs.prose, fontSize = 14.sp, color = colors.ink2)
            Segmented(
                options = VitalPeriod.entries.map { it.label },
                selectedIndex = VitalPeriod.entries.indexOf(period),
                onSelect = { period = VitalPeriod.entries[it] },
            )
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    fmt(points.lastOrNull()?.value, kind.decimals),
                    fontFamily = Obs.mono,
                    fontSize = 30.sp,
                    fontWeight = FontWeight.Medium,
                    color = colors.ink,
                )
                Spacer(Modifier.width(6.dp))
                Text(kind.unit, fontFamily = Obs.mono, fontSize = 12.sp, color = colors.ink2)
            }
            if (points.size > 1) {
                Sparkline(
                    series = points.map { it.value },
                    accent = colors.chart,
                    baseline = kind.baseline(s),
                    trace = colors.rule,
                    modifier = Modifier.height(160.dp),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(points.first().date, fontFamily = Obs.mono, fontSize = 10.sp, color = colors.ink2)
                    Text(points.last().date, fontFamily = Obs.mono, fontSize = 10.sp, color = colors.ink2)
                }
                val values = points.map { it.value }
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    ObsStat("average", fmt(values.average(), kind.decimals))
                    ObsStat("low", fmt(values.min(), kind.decimals))
                    ObsStat("high", fmt(values.max(), kind.decimals))
                    ObsStat("nights", "${values.size}")
                }
            } else {
                EmptyNote("Not enough nights in this window yet.")
            }
        }
    }
}

@Composable
fun SleepDebtScreen(debt: SleepDebtSummary, onBack: () -> Unit) {
    val colors = Obs.colors
    var cumulative by remember { mutableStateOf(true) }
    Sheet("Sleep debt", onBack) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(start = 20.dp, end = 20.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Text(
                if (debt.valid) fmtMinutes(debt.debtMin) else "—",
                fontFamily = Obs.mono,
                fontSize = 34.sp,
                fontWeight = FontWeight.Medium,
                color = colors.debt(debt.state),
            )
            Segmented(
                options = listOf("Cumulative debt", "Total sleep"),
                selectedIndex = if (cumulative) 0 else 1,
                onSelect = { cumulative = it == 0 },
            )
            val series = debt.days.map {
                if (cumulative) it.cumulativeDebtMin ?: 0.0 else it.totalSleepMin ?: 0.0
            }
            if (series.size > 1) {
                Sparkline(
                    series = series,
                    accent = if (cumulative) colors.debt(debt.state) else colors.chart,
                    baseline = if (cumulative) null else debt.days.lastOrNull()?.sleepNeedMin,
                    trace = colors.rule,
                    modifier = Modifier.height(140.dp),
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(
                        debt.days.first().date,
                        fontFamily = Obs.mono,
                        fontSize = 10.sp,
                        color = colors.ink2,
                    )
                    Text(
                        debt.days.last().date,
                        fontFamily = Obs.mono,
                        fontSize = 10.sp,
                        color = colors.ink2,
                    )
                }
            }
            Rule("how it works")
            Text(
                "Every sleep session is grouped by the morning you woke on — naps included — " +
                    "and compared against a nightly need personalised from your own last 90 " +
                    "days (outlier-filtered, clamped to 7–9 h, rounded to 15 minutes). A night " +
                    "never sets its own need. The window is the last ${debt.windowDays} days " +
                    "and needs at least five with data; right now ${debt.validDays} qualify.",
                fontFamily = Obs.prose,
                fontSize = 14.sp,
                color = colors.ink2,
            )
        }
    }
}

/** The profile editor. `profile.json` sits beside the DB, where the Rust summary reads it. */
@Composable
fun ProfileScreen(
    initial: Profile?,
    onSave: (Profile) -> Unit,
    onImportHealth: () -> Unit,
    healthExportEnabled: Boolean,
    onHealthExportChange: (Boolean) -> Unit,
    onRemoveHealthSamples: () -> Unit,
    healthNote: String?,
    onBack: () -> Unit,
) {
    val colors = Obs.colors
    var sex by remember { mutableStateOf(initial?.sex ?: "M") }
    var age by remember { mutableStateOf((initial?.age ?: 30.0).roundToInt().toString()) }
    var heightCm by remember {
        mutableStateOf(((initial?.heightM ?: 1.78) * 100).roundToInt().toString())
    }
    var weightKg by remember { mutableStateOf((initial?.weightKg ?: 75.0).roundToInt().toString()) }
    var ringSize by remember { mutableStateOf((initial?.ringSize ?: 10.0).roundToInt().toString()) }

    fun commit() {
        onSave(
            Profile(
                sex = sex,
                age = age.toDoubleOrNull() ?: 30.0,
                heightM = (heightCm.toDoubleOrNull() ?: 178.0) / 100,
                weightKg = weightKg.toDoubleOrNull() ?: 75.0,
                ringSize = ringSize.toDoubleOrNull() ?: 10.0,
            )
        )
    }

    Sheet("Profile", onBack) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(start = 20.dp, end = 20.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Text(
                "These feed the cardiovascular-age and energy-expenditure models, and the " +
                    "Schofield BMR behind total calories.",
                fontFamily = Obs.prose,
                fontSize = 13.sp,
                color = colors.muted,
            )
            Rule("you")
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("sex", fontFamily = Obs.mono, fontSize = 13.sp, color = colors.ink2)
                Spacer(Modifier.weight(1f))
                Segmented(
                    options = listOf("M", "F", "O"),
                    selectedIndex = listOf("M", "F", "O").indexOf(sex).coerceAtLeast(0),
                    onSelect = { sex = listOf("M", "F", "O")[it]; commit() },
                )
            }
            NumberField("age", age, "years") { age = it; commit() }
            NumberField("height", heightCm, "cm") { heightCm = it; commit() }
            NumberField("weight", weightKg, "kg") { weightKg = it; commit() }
            NumberField("ring size", ringSize, "us") { ringSize = it; commit() }

            Rule("health connect")
            ActionRow("Import height & weight from Health Connect", onImportHealth)
            Text(
                // An honest divergence: Health Connect has no date-of-birth or biological-sex
                // record, so unlike iOS we cannot prefill those. Documented in docs/clients.md.
                "Health Connect stores no date of birth or biological sex, so age and sex stay " +
                    "manual entry here.",
                fontFamily = Obs.prose,
                fontSize = 12.sp,
                color = colors.muted,
            )
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "write ring data to Health Connect",
                    fontFamily = Obs.mono,
                    fontSize = 13.sp,
                    color = colors.ink2,
                    modifier = Modifier.weight(1f),
                )
                Segmented(
                    options = listOf("off", "on"),
                    selectedIndex = if (healthExportEnabled) 1 else 0,
                    onSelect = { onHealthExportChange(it == 1) },
                )
            }
            ActionRow("Remove Open Oura records from Health Connect", onRemoveHealthSamples)
            healthNote?.let {
                Text(it, fontFamily = Obs.mono, fontSize = 11.sp, color = colors.ink2)
            }
        }
    }
}

@Composable
private fun NumberField(label: String, value: String, unit: String, onChange: (String) -> Unit) {
    val colors = Obs.colors
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontFamily = Obs.mono, fontSize = 13.sp, color = colors.ink2)
        Spacer(Modifier.weight(1f))
        BasicTextField(
            value = value,
            onValueChange = { new -> onChange(new.filter { it.isDigit() || it == '.' }) },
            singleLine = true,
            textStyle = TextStyle(
                fontFamily = Obs.mono,
                fontSize = 15.sp,
                color = colors.ink,
            ),
            cursorBrush = SolidColor(colors.ink),
            modifier = Modifier
                .width(70.dp)
                .background(colors.rule.copy(alpha = 0.35f), RoundedCornerShape(4.dp))
                .padding(horizontal = 8.dp, vertical = 6.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(unit, fontFamily = Obs.mono, fontSize = 11.sp, color = colors.muted)
    }
}

@Composable
internal fun ActionRow(label: String, onClick: () -> Unit) {
    val colors = Obs.colors
    Text(
        label,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .background(colors.rule.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        fontFamily = Obs.mono,
        fontSize = 13.sp,
        color = colors.ink,
    )
}
