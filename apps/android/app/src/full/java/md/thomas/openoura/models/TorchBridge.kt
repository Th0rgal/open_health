package md.thomas.openoura.models

/**
 * Kotlin face of `cpp/torch_bridge.cpp` — the Android counterpart to iOS's
 * `TorchBridge.h`. Every call is serialized by a single mutex on the native side, and
 * each model is loaded once and retained for the process lifetime.
 *
 * All arrays are row-major; a null return means the native side logged a failure and the
 * caller should surface a model error rather than silently substituting empty results.
 */
object TorchBridge {

    /**
     * Null when the native library loaded; otherwise the reason, so ModelPipeline can
     * surface one honest model error instead of crashing. The library is absent whenever
     * LibTorch has not been built locally (spike/build_libtorch_android.sh) — a normal
     * state for a checkout, since the archives are gitignored like their iOS twins.
     */
    val loadError: String? = try {
        System.loadLibrary("oura_torch")
        null
    } catch (e: Throwable) {
        "on-device models unavailable: ${e.message ?: e.toString()} — " +
            "run apps/android/spike/build_libtorch_android.sh"
    }

    val available: Boolean get() = loadError == null

    /**
     * SleepNet (moonstone) → per-30s stage codes (1=DEEP 2=LIGHT 3=REM 4=WAKE), matching
     * tools/run_sleep_model.py. `ibiVal` is row-major n×3 (ibi_ms, amplitude, valid);
     * `acmVal`/`tempVal` are n×1. Timestamps are absolute epoch-ms.
     */
    external fun sleepnet(
        modelPath: String,
        ibiTs: LongArray, ibiVal: FloatArray,
        acmTs: LongArray, acmVal: FloatArray,
        tempTs: LongArray, tempVal: FloatArray,
        bedtimeStartMs: Long, bedtimeEndMs: Long,
    ): IntArray?

    /**
     * Cardiovascular age. `ppg` is row-major nSegs×1500; `demo` is
     * [sex(-1/0/1), height_m, age, ring, weight]. Returns [vascularAge, pwv].
     */
    external fun cva(modelPath: String, ppg: FloatArray, nSegs: Int, demo: FloatArray): DoubleArray?

    /**
     * Automatic activity detection. Returns workouts row-major, 9 floats per row:
     * [startMin, endMin, isWorkout, id1, p1, id2, p2, id3, p3].
     */
    external fun activity(
        modelPath: String,
        context: FloatArray, user: FloatArray,
        met: FloatArray, nMet: Int,
        step: FloatArray, nStep: Int,
        motion: FloatArray, nMotion: Int,
        temp: FloatArray, nTemp: Int,
        hr: FloatArray, nHr: Int,
        threshold: Float, minDuration: Float,
    ): FloatArray?

    /**
     * Ring 5 real-step packet decoder. `raw` is row-major nRaw×27. Decoded timestamps are
     * written into `outTimestampsMs` (which bounds the row count); the return value is the
     * matching features, row-major ×11.
     */
    external fun stepMotion(
        modelPath: String,
        timestampsMs: LongArray, raw: FloatArray, nRaw: Int,
        outTimestampsMs: LongArray,
    ): FloatArray?

    /**
     * Illness detection ("Symptom Radar"). `series` is row-major 7×30 (index 0 = today,
     * NaN = missing); `scalars` is 12 values. Returns 18 floats:
     * [score, decision, then 4 biomarkers × (isOut, value, lower, upper)].
     */
    external fun illness(modelPath: String, series: FloatArray, scalars: FloatArray): FloatArray?
}
