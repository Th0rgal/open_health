package md.thomas.openoura.ble

import android.content.Context
import android.os.PowerManager
import md.thomas.openoura.diag.Diagnostics.log

/**
 * Reference-counted PARTIAL_WAKE_LOCK, matching the ownership semantics of the official
 * Android client's SweetBlue lock.
 *
 * docs/clients.md notes that iOS has no equivalent unrestricted CPU wake lock, so
 * `IdleTimerLock` there only keeps the *foreground* app awake and has to reassert itself
 * across lifecycle transitions. On Android we can hold the real thing, so a long history
 * drain or a model pass survives the screen going off. Owner keys match iOS:
 * "ring-sync", "pair-screen", "models".
 */
object WakeLockOwner {
    private const val TAG = "openoura:ring"

    /** A drain of a year of history is long, but never hours; fail safe if we leak. */
    private const val MAX_HOLD_MS = 30L * 60 * 1000

    private val owners = HashSet<String>()
    private var lock: PowerManager.WakeLock? = null
    private val monitor = Any()

    fun acquire(context: Context, owner: String) = synchronized(monitor) {
        if (!owners.add(owner)) return@synchronized
        if (lock == null) {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, TAG).apply {
                setReferenceCounted(false)
                acquire(MAX_HOLD_MS)
            }
            log("wake", "acquired ($owner)")
        }
    }

    fun release(owner: String) = synchronized(monitor) {
        if (!owners.remove(owner)) return@synchronized
        if (owners.isEmpty()) {
            try {
                lock?.takeIf { it.isHeld }?.release()
            } catch (_: Exception) {
            }
            lock = null
            log("wake", "released (last owner $owner)")
        }
    }

    /** Run [block] holding the lock for [owner], releasing it even on failure. */
    inline fun <T> withLock(context: Context, owner: String, block: () -> T): T {
        acquire(context, owner)
        try {
            return block()
        } finally {
            release(owner)
        }
    }
}
