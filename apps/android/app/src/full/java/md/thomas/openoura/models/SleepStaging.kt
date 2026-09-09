package md.thomas.openoura.models

import android.content.Context
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import md.thomas.openoura.data.EventStore
import md.thomas.openoura.data.NightRow
import md.thomas.openoura.diag.Diagnostics.log

/**
 * On-device sleep staging: read the synced DB, assemble the raw SleepNet inputs (a
 * faithful port of tools/run_sleep_model.py — the model bakes in its own preprocessing),
 * and run sleepnet_moonstone through the LibTorch lite bridge. Returns
 * bedtime-start_ds → per-30s stage codes, matching `nights[].stages` on the other clients.
 *
 * Port of apps/ios/OuraApp/SleepStaging.swift.
 */
object SleepStaging {

    private const val MODEL = "sleepnet_moonstone_1_2_0"

    /** Everything SleepNet receives for one night — also the material the cache fingerprints. */
    class NightInputs(
        val startDs: Long,
        val endDs: Long,
        val startMs: Long,
        val endMs: Long,
        /** (timestampMs, ibiMs, amplitude, valid) */
        val beats: List<Beat>,
        val acm: List<Sample>,
        val temp: List<Sample>,
    )

    class Beat(val t: Long, val ibi: Float, val amplitude: Float, val valid: Float)
    class Sample(val t: Long, val v: Float)

    class Result(val staged: Map<String, List<Int>>, val error: String?)

    /**
     * Returns start_ds → stage codes, plus a non-null [Result.error] only for genuine
     * failures (missing model asset). An empty map with a null error just means there is
     * no sleep data to stage.
     */
    fun run(
        context: Context,
        nights: List<NightRow>,
        events: List<EventStore.Ev>,
        clock: EventStore.RingClock,
        progress: (String) -> Unit = {},
    ): Result {
        val modelPath = ModelAssets.path(context, MODEL)
            ?: return Result(emptyMap(), "sleep model file missing from the app assets")
        if (events.isEmpty()) return Result(emptyMap(), null)

        // The shared Rust summary canonicalizes brief wake splits and premature bedtime
        // ends. Consume those exact windows so the model cannot reintroduce the raw ring
        // boundary the UI already corrected. `nights` arrive newest-first from the
        // summary; keep that order so the night the user is looking at stages first.
        val beds = nights.mapNotNull { night ->
            val start = night.startDs ?: return@mapNotNull null
            val end = night.endDs ?: return@mapNotNull null
            val captured = events.firstOrNull { e ->
                e.tag == 0x76 && e.long("bedtime_start_ds") == start
            }?.cu ?: events.lastOrNull()?.cu ?: 0L
            Triple(start, end, captured)
        }

        val globalKey = ModelCacheStore.globalKey(context, null)
        val cache = ModelCacheStore.load(
            context, ModelCacheStore.STAGING_FILE, globalKey, StagedNightEntry.serializer()
        )

        val result = HashMap<String, List<Int>>()
        val dirty = ArrayList<Triple<String, NightInputs, String>>()
        val currentKeys = HashSet<String>()

        for ((start, end, cu) in beds) {
            val inputs = nightInputs(start, end, cu, events, clock) ?: continue
            // Key by the exact bedtime start_ds (matching the summary's night.start_ds)
            // so two sleeps on one calendar day stay distinct.
            val key = start.toString()
            val fp = fingerprint(inputs)
            currentKeys.add(key)
            val entry = cache[key]
            if (entry != null && entry.fp == fp) {
                if (entry.stages.isNotEmpty()) result[key] = entry.stages
            } else {
                dirty.add(Triple(key, inputs, fp))
            }
        }

        log("models", "staging: ${dirty.size}/${currentKeys.size} nights to recompute")
        dirty.forEachIndexed { index, (key, inputs, fp) ->
            progress("staging sleep · night ${index + 1}/${dirty.size}")
            // Empty stages are cached too: a night the model can't stage shouldn't be
            // retried on every reload until its inputs change.
            val stages = stageNight(inputs, modelPath) ?: emptyList()
            if (stages.isNotEmpty()) result[key] = stages
            cache[key] = StagedNightEntry(fp, stages)
            ModelCacheStore.save(
                context, ModelCacheStore.STAGING_FILE, globalKey, cache,
                StagedNightEntry.serializer(),
            )
        }

        val pruned = cache.filterKeys { it in currentKeys }
        if (pruned.size != cache.size) {
            ModelCacheStore.save(
                context, ModelCacheStore.STAGING_FILE, globalKey, pruned,
                StagedNightEntry.serializer(),
            )
        }
        return Result(result, null)
    }

    /** Gather one night's raw model inputs; null when there is no usable beat data. */
    fun nightInputs(
        startDs: Long,
        endDs: Long,
        bedCu: Long,
        events: List<EventStore.Ev>,
        clock: EventStore.RingClock,
    ): NightInputs? {
        // ms(ds) → absolute epoch ms, epoch-aware (ds resets on ring reboot; see EventStore)
        fun ms(ds: Long, cu: Long): Long = (clock.unixSeconds(ds, cu) * 1000).toLong()

        val lo = startDs - 6000
        val hi = endDs + 6000
        val beats = ArrayList<Beat>()
        val acm = ArrayList<Sample>()
        val temp = ArrayList<Sample>()

        for (e in events) {
            if (e.ds < lo || e.ds > hi) continue
            when (e.tag) {
                0x60, 0x80 -> {
                    val ibi = (e.json?.get("ibi_ms") as? JsonArray) ?: continue
                    val amp = e.json["amplitude"] as? JsonArray
                    val t = ms(e.ds, e.cu)
                    var acc = 0L
                    ibi.forEachIndexed { i, element ->
                        val x = element.jsonPrimitive.doubleOrNull?.toLong() ?: 0L
                        if (x > 0) {
                            acc += x
                            val valid = if (x in 300..2000) 1f else 0f
                            val amplitude = amp?.getOrNull(i)
                                ?.jsonPrimitive?.doubleOrNull?.toFloat() ?: 0f
                            beats.add(Beat(t + acc, x.toFloat(), amplitude, valid))
                        }
                    }
                }
                0x47 -> e.num("motion_seconds")?.let { acm.add(Sample(ms(e.ds, e.cu), it.toFloat())) }
                0x46 -> {
                    val temps = e.json?.get("temps_c") as? JsonArray
                    temps?.firstOrNull()?.jsonPrimitive?.doubleOrNull?.let {
                        temp.add(Sample(ms(e.ds, e.cu), it.toFloat()))
                    }
                }
            }
        }

        beats.sortBy { it.t }
        acm.sortBy { it.t }
        temp.sortBy { it.t }
        if (beats.isEmpty() || beats.none { it.valid == 1f }) return null

        return NightInputs(
            startDs = startDs,
            endDs = endDs,
            startMs = ms(startDs, bedCu),
            endMs = ms(endDs, bedCu),
            beats = beats,
            acm = acm,
            temp = temp,
        )
    }

    /**
     * A night's fingerprint covers its exact model inputs; a hit is by construction the
     * hypnogram the model would have produced.
     */
    private fun fingerprint(inputs: NightInputs): String {
        val h = FNV64()
        h.combine(inputs.startDs)
        h.combine(inputs.endDs)
        h.combine(inputs.startMs)  // RingClock re-dating backstop
        h.combine(inputs.endMs)
        h.combine(inputs.beats.size)
        for (b in inputs.beats) {
            h.combine(b.t); h.combine(b.ibi); h.combine(b.amplitude); h.combine(b.valid)
        }
        h.combine(inputs.acm.size)
        for (a in inputs.acm) { h.combine(a.t); h.combine(a.v) }
        h.combine(inputs.temp.size)
        for (t in inputs.temp) { h.combine(t.t); h.combine(t.v) }
        return h.hex
    }

    /** One SleepNet inference over one night's inputs. */
    private fun stageNight(inputs: NightInputs, modelPath: String): List<Int>? {
        val ibiTs = LongArray(inputs.beats.size) { inputs.beats[it].t }
        val ibiVal = FloatArray(inputs.beats.size * 3)
        inputs.beats.forEachIndexed { i, b ->
            ibiVal[i * 3] = b.ibi
            ibiVal[i * 3 + 1] = b.amplitude
            ibiVal[i * 3 + 2] = b.valid
        }
        val acmTs = LongArray(inputs.acm.size) { inputs.acm[it].t }
        val acmVal = FloatArray(inputs.acm.size) { inputs.acm[it].v }
        val tempTs = LongArray(inputs.temp.size) { inputs.temp[it].t }
        val tempVal = FloatArray(inputs.temp.size) { inputs.temp[it].v }

        val out = TorchBridge.sleepnet(
            modelPath,
            ibiTs, ibiVal,
            acmTs, acmVal,
            tempTs, tempVal,
            inputs.startMs, inputs.endMs,
        ) ?: return null
        return if (out.isEmpty()) null else out.toList()
    }
}
