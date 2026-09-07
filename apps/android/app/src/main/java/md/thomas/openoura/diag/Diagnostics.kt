package md.thomas.openoura.diag

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Copy-pasteable diagnostics for a device-only app: a live session transcript, crash
 * logs that survive the process dying, and the OS's own record of *why* we died.
 * Port of apps/ios/OuraApp/Diagnostics.swift.
 *
 * The iOS version promotes a leftover session.log to a crash log on next launch (so a
 * jetsam kill leaves evidence) and subscribes to MetricKit. Android's analogue of
 * MetricKit for that specific case is `getHistoricalProcessExitReasons`, which reports
 * LOW_MEMORY / ANR / native crash with far more precision than iOS gets.
 */
object Diagnostics {
    private const val DIR = "diagnostics"
    private const val SESSION = "session.log"
    private const val MAX_CRASHES = 16
    private const val MAX_SESSIONS = 8

    @Volatile private var sessionFile: File? = null
    private val stamp = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val fileStamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
    private val buffer = StringBuilder()
    private val lock = Any()

    fun bootstrap(context: Context) {
        val dir = File(context.filesDir, DIR).apply { mkdirs() }
        val crashes = File(dir, "crashes").apply { mkdirs() }
        val sessions = File(dir, "sessions").apply { mkdirs() }

        // A session.log still sitting here means the previous run never got to close
        // it — a crash, an ANR kill, or a low-memory kill. Keep it as evidence.
        val leftover = File(dir, SESSION)
        if (leftover.exists() && leftover.length() > 0) {
            leftover.renameTo(File(crashes, "abnormal-${fileStamp.format(Date())}.log"))
        }
        prune(crashes, MAX_CRASHES)
        prune(sessions, MAX_SESSIONS)

        sessionFile = File(dir, SESSION).apply { writeText("") }
        log("app", "open oura ${Build.MANUFACTURER} ${Build.MODEL} · api ${Build.VERSION.SDK_INT}")
        recordPreviousExit(context)

        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            val sw = StringWriter()
            error.printStackTrace(PrintWriter(sw))
            log("crash", "on ${thread.name}\n$sw")
            flush()
            File(dir, SESSION).copyTo(
                File(crashes, "crash-${fileStamp.format(Date())}.log"), overwrite = true
            )
            previous?.uncaughtException(thread, error)
        }
    }

    /**
     * Why the previous process died, straight from the OS. This is what catches the
     * low-memory kills that the iOS side had to infer from a leftover log.
     */
    private fun recordPreviousExit(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            am.getHistoricalProcessExitReasons(context.packageName, 0, 1).firstOrNull()?.let {
                log(
                    "exit",
                    "previous process: reason=${it.reason} status=${it.status} " +
                        "importance=${it.importance} rss=${it.pss}KB · ${it.description ?: "—"}"
                )
            }
        } catch (_: Exception) {
            // diagnostics must never be the reason a launch fails
        }
    }

    fun log(tag: String, message: String) {
        val line = "${stamp.format(Date())} [$tag] $message"
        android.util.Log.i("openoura", line)
        synchronized(lock) {
            buffer.append(line).append('\n')
            if (buffer.length > 8192) flushLocked()
        }
    }

    fun flush() = synchronized(lock) { flushLocked() }

    private fun flushLocked() {
        val f = sessionFile ?: return
        if (buffer.isEmpty()) return
        try {
            f.appendText(buffer.toString())
            buffer.setLength(0)
        } catch (_: Exception) {
        }
    }

    /** The live transcript shown in the sync sheet, newest content last. */
    fun transcript(): String = synchronized(lock) {
        val onDisk = sessionFile?.takeIf { it.exists() }?.readText().orEmpty()
        onDisk + buffer.toString()
    }

    fun previousCrashes(context: Context): List<File> =
        File(File(context.filesDir, DIR), "crashes")
            .listFiles()?.sortedByDescending { it.lastModified() } ?: emptyList()

    private fun prune(dir: File, keep: Int) {
        dir.listFiles()?.sortedByDescending { it.lastModified() }?.drop(keep)?.forEach { it.delete() }
    }
}
