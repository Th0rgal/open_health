package md.thomas.openoura.ble

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * iOS has one Bluetooth permission; Android split it at API 31 and, before that,
 * required a location grant because a BLE scan could be used to infer position. We
 * declare `neverForLocation` so modern devices skip the location prompt entirely.
 */
object BlePermissions {

    /** The permissions this OS version actually requires, in the order to request them. */
    fun required(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    fun missing(context: Context): List<String> = required().filter {
        ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
    }

    fun granted(context: Context): Boolean = missing(context).isEmpty()

    /** Plain-language explanation for the sync screen when a grant is outstanding. */
    fun rationale(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            "Open Oura needs Nearby devices permission to find and talk to your ring. " +
                "It never uses it for location."
        } else {
            "On this Android version a Bluetooth scan requires the Location permission. " +
                "Open Oura never reads your location — it only looks for the ring."
        }
}
