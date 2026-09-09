package md.thomas.openoura.models

import android.content.Context
import md.thomas.openoura.data.Cardio
import md.thomas.openoura.data.EventStore
import md.thomas.openoura.data.Summary
import md.thomas.openoura.data.stagedSleepDebt
import md.thomas.openoura.diag.Diagnostics.log
import md.thomas.openoura.store.DB
import kotlin.math.roundToLong

/**
 * The slow part: run the on-device torch models and fold their results into the summary.
 * Port of `Core.withModels` in apps/ios/OuraApp/Core.swift.
 *
 * Models share one LibTorch runtime, so they run one after another (the JNI bridge also
 * serializes `forward()`). Concurrent inference raced the interpreter and peaked RAM on
 * hiking-heavy histories. Each reports a per-model error for genuine failures; those
 * surface in `modelErrors`.
 */
object ModelPipeline {
    const val AVAILABLE = true

    fun run(
        context: Context,
        base: Summary,
        previous: Summary?,
        progress: (String) -> Unit,
    ): Summary? {
        TorchBridge.loadError?.let {
            log("models", it)
            return base.copy(modelErrors = listOf(it))
        }

        var s = base
        val profile = base.profile

        var staged: Map<String, List<Int>> = emptyMap()
        var cva: CvaModel.Result? = null
        var workouts = emptyList<md.thomas.openoura.data.WorkoutSession>()
        var illness: md.thomas.openoura.data.IllnessResult? = null
        var sleepErr: String? = null
        var cvaErr: String? = null
        var actErr: String? = null
        var illErr: String? = null

        // One shared read: one failure point, one lock-contention window, and the
        // RingClock epoch recovery is paid once instead of once per model.
        progress("reading ring data…")
        var events: List<EventStore.Ev> = emptyList()
        var readErr: String? = null
        try {
            events = EventStore.decodedEvents(DB.readPath(context))
        } catch (e: Exception) {
            readErr = e.message ?: e.toString()
        }
        log("models", "read ${events.size} events")

        if (readErr == null && events.isNotEmpty()) {
            val clock = EventStore.RingClock(events)
            val rSleep = SleepStaging.run(context, base.nights, events, clock, progress)
            staged = rSleep.staged
            sleepErr = rSleep.error

            val rAct = ActivityModel.run(context, profile, events, clock, progress)
            workouts = rAct.sessions
            actErr = rAct.error

            val rIll = IllnessModel.run(context, profile, events, clock)
            illness = rIll.result
            illErr = rIll.error
        } else if (readErr != null) {
            // The shared read failed: every event-fed model is unavailable this pass.
            // Surface one error; the publish below falls back to `previous`.
            sleepErr = readErr
            actErr = readErr
            illErr = readErr
        }

        val rCva = CvaModel.run(
            context,
            sex = profile?.sex ?: "M",
            age = profile?.age ?: 30.0,
            heightM = profile?.heightM ?: 1.78,
            weightKg = profile?.weightKg ?: 75.0,
            ringSize = profile?.ringSize ?: 10.0,
        )
        cva = rCva.result
        cvaErr = rCva.error

        // If staging failed outright, refill from the last published summary so a
        // transient read failure can't strip hypnograms that were already on screen.
        if (sleepErr != null && staged.isEmpty() && previous != null) {
            staged = previous.nights.mapNotNull { night ->
                val sds = night.startDs ?: return@mapNotNull null
                val stages = night.stages?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                sds.toString() to stages
            }.toMap()
        }

        // Fold SleepNet's hypnogram + stage breakdown into each night, keyed by the exact
        // bedtime start_ds so two sleeps on one calendar day don't collide.
        s = s.copy(
            nights = s.nights.map { night ->
                val stages = night.startDs?.let { staged[it.toString()] }
                if (stages.isNullOrEmpty()) return@map night
                val total = stages.size.toDouble()
                fun pct(code: Int) = (stages.count { it == code } / total * 100).roundToLong().toDouble()
                val asleep = total - stages.count { it == 4 }
                night.copy(
                    stages = stages,
                    deepPct = pct(1),
                    lightPct = pct(2),
                    remPct = pct(3),
                    wakePct = pct(4),
                    efficiency = (asleep / total * 100).roundToLong().toDouble(),
                )
            }
        )

        // Staging can be partial while model inputs are still arriving. Never replace a
        // more complete model-free debt window with a transient "0 of 5" result; prefer
        // staged sleep only when it covers at least as many distinct days.
        s.stagedSleepDebt()?.let { stagedDebt ->
            if (stagedDebt.validDays >= (s.sleepDebt?.validDays ?: 0)) {
                s = s.copy(sleepDebt = stagedDebt)
            }
        }

        s = when {
            cva != null -> s.copy(
                cardio = Cardio(
                    vascularAge = cva.vascularAge,
                    chronologicalAge = profile?.age ?: 30.0,
                    pwvMs = cva.pwv,
                    segments = cva.segments,
                )
            )
            cvaErr != null -> s.copy(cardio = previous?.cardio)
            else -> s
        }

        // Never let a failed run replace real results with emptiness (the same principle
        // as the staged-sleep-debt coverage guard above).
        s = s.copy(
            workouts = if (actErr == null || workouts.isNotEmpty()) workouts
            else previous?.workouts ?: emptyList(),
            illness = if (illErr == null || illness != null) illness else previous?.illness,
            // Deduplicated: a failed shared read sets the same message on three models.
            modelErrors = listOfNotNull(sleepErr, cvaErr, actErr, illErr).distinct(),
        )
        return s
    }
}
