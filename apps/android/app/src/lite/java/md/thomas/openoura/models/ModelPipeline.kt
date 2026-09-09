package md.thomas.openoura.models

import android.content.Context
import md.thomas.openoura.data.Summary

/**
 * Model-free build — the counterpart of the iOS app compiled WITHOUT `-D TORCH`
 * (apps/ios/OuraApp/build_run.sh). No LibTorch, no `.ptl` assets, so sleep stages,
 * cardiovascular age, activity sessions and Symptom Radar stay absent and the UI shows
 * its model-free states.
 *
 * Everything `oura-summary` computes without a model — vitals, baselines, SpO₂
 * calibration, nightly skin temperature, Schofield BMR, VO₂max, steps/distance,
 * movement profile, device health — is still fully present, because it comes from the
 * shared Rust core rather than from here.
 */
object ModelPipeline {
    const val AVAILABLE = false

    fun run(
        context: Context,
        base: Summary,
        previous: Summary?,
        progress: (String) -> Unit,
    ): Summary? = null
}
