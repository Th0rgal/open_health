package md.thomas.openoura.models

import android.content.Context
import md.thomas.openoura.diag.Diagnostics.log
import java.io.File

/**
 * The `.ptl` models ship as APK assets, but the LibTorch lite loader wants a filesystem
 * path — an asset inside the APK has none. So each model is copied out once into the app's
 * cache on first use and reused from there.
 *
 * On iOS `Bundle.main.path(forResource:ofType:"ptl")` gives a real path for free, which is
 * the only reason this file has no Swift counterpart.
 *
 * The models themselves are decrypted proprietary artifacts and are gitignored, exactly as
 * on iOS — a checkout has none, and their absence is reported as a model error rather than
 * a crash.
 */
object ModelAssets {

    private val extracted = HashMap<String, String?>()

    /** Absolute path to `<name>.ptl`, or null when the model was not shipped. */
    @Synchronized
    fun path(context: Context, name: String): String? = extracted.getOrPut(name) {
        val dst = File(context.cacheDir, "models/$name.ptl")
        if (dst.exists() && dst.length() > 0) return@getOrPut dst.absolutePath
        try {
            dst.parentFile?.mkdirs()
            context.assets.open("$name.ptl").use { input ->
                dst.outputStream().use { input.copyTo(it) }
            }
            log("models", "extracted $name.ptl (${dst.length() / 1024} KB)")
            dst.absolutePath
        } catch (_: Exception) {
            // Not an error worth a stack trace: a build without the proprietary models is
            // a supported configuration (it is what the `lite` flavor always is).
            null
        }
    }
}
