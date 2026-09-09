package md.thomas.openoura.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelUuid
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.suspendCancellableCoroutine
import md.thomas.openoura.diag.Diagnostics.log
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// Native BluetoothGatt implementation of the ring link — the Android counterpart to
// `oura-link::ble` (btleplug) and to apps/ios/OuraApp/BLETransport.swift, conforming to
// the same shape as the Rust `Transport` trait: write a request frame, and receive the
// merged stream of inbound notification frames. The auth handshake + sync drain stay in
// Rust (oura-link `OuraClient`); this just moves bytes.
//
// Wiring: oura-core exposes `BleWriter` as a UniFFI callback interface and a
// `RingSession.sync(db_path, key_hex, progress)` entry; RingSync below is what drives it.
// (BLE needs a real ring, so this only does anything on a physical device.)

object RingUuid {
    val service: UUID = UUID.fromString("98ED0001-A541-11E4-B6A0-0002A5D5C51B")
    val chargingCaseService: UUID = UUID.fromString("8BC5888F-C577-4F5D-857F-377354093F13")
    val write: UUID = UUID.fromString("98ED0002-A541-11E4-B6A0-0002A5D5C51B")

    // notify/indicate chars: gen-4 uses …0003; Ring 5 adds …0004/0005/0006.
    val notify: Set<UUID> = setOf(
        UUID.fromString("98ED0003-A541-11E4-B6A0-0002A5D5C51B"),
        UUID.fromString("98ED0004-A541-11E4-B6A0-0002A5D5C51B"),
        UUID.fromString("98ED0005-A541-11E4-B6A0-0002A5D5C51B"),
        UUID.fromString("98ED0006-A541-11E4-B6A0-0002A5D5C51B"),
    )

    /** Client Characteristic Configuration — Android needs this written by hand. */
    val cccd: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
}

sealed class BleError(message: String) : Exception(message) {
    object PoweredOff : BleError("Bluetooth is off or not authorized")
    object NotFound : BleError("ring service/characteristics not found")
    object NoWriteCharacteristic : BleError("no write characteristic (98ED0002)")
    object Disconnected : BleError("ring disconnected")
    object Busy : BleError("another BLE operation is in flight")
    object MissingPermission : BleError("Bluetooth permission not granted")

    /**
     * Carries the stage the attempt was in, so "timed out" says *what* never happened
     * (no advertisement seen vs GATT connect stalled vs subscriptions pending).
     */
    class TimedOut(stage: String) : BleError("timed out while $stage")

    class Gatt(operation: String, status: Int) : BleError("$operation failed (GATT status $status)")
}

/**
 * Scans for an Oura ring advertising the service (filtered by case-insensitive name),
 * connects, discovers the write + notify characteristics, and bridges them to the Rust
 * transport. Mirrors `oura-link::ble::Connection` and iOS's `BLETransport`.
 *
 * Android differs from CoreBluetooth in one structural way: a `BluetoothGatt` permits
 * exactly ONE outstanding operation, and enabling notifications means writing the CCCD
 * descriptor by hand rather than a single `setNotifyValue`. So the four subscriptions
 * are queued strictly sequentially, and — as on iOS — the connect does not resolve until
 * every one is confirmed, or Rust could start syncing before inbound frames flow.
 */
@SuppressLint("MissingPermission") // callers gate on BlePermissions.missing()
class BleTransport(
    private val context: Context,
    private val nameContains: String = "Oura",
) {
    private val manager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
    private val adapter: BluetoothAdapter? = manager?.adapter

    private val thread = HandlerThread("md.thomas.openoura.ble").apply { start() }
    private val handler = Handler(thread.looper)

    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null

    // Every notify/indicate characteristic merged into one stream of raw frames.
    // A Channel rather than a SharedFlow because this stream has to CLOSE: iOS finishes
    // its AsyncStream on disconnect so a Rust drain blocked on `recv` returns at once
    // instead of waiting out the quiet window, and a SharedFlow cannot express that.
    // Recreated per connect(), so a reconnect gets a fresh, live stream — a single lazy
    // one would stay closed and silently drop every frame after the first link loss.
    @Volatile
    private var frames: Channel<ByteArray> = Channel(Channel.UNLIMITED)

    /** The inbound frame stream for the CURRENT connection. */
    fun notifications(): ReceiveChannel<ByteArray> = frames

    // Ring 5 history arrives as thousands of tiny GATT notifications. Passing every one
    // through the flow + UniFFI separately (and hex-logging it) costs more than parsing
    // it. Coalesce only history payload packets; command replies and the terminal batch
    // summary remain immediate. Rust's Packet::parse_many already accepts concatenated
    // packets, so this does not change protocol semantics. Mirrors BLETransport.swift.
    private val historyBuffer = ByteArrayOutputStream()
    private var historyFrames = 0
    private var historyBytes = 0

    private val lock = Any()
    private var connectCont: CancellableContinuation<Unit>? = null
    private var writeCont: CancellableContinuation<Unit>? = null
    private var timeoutRunnable: Runnable? = null
    private var pendingNotifyQueue = ArrayDeque<BluetoothGattCharacteristic>()

    /** Where the in-flight connect currently is, for the timeout error message. */
    private var stage = "waiting for Bluetooth to power on"

    // Advertisement reports already logged (id|name) — an ALL_MATCHES scan re-reports the
    // same ring many times a second; log each device once, and again when its name first
    // arrives via scan response.
    private val loggedAds = HashSet<String>()

    // Distinct non-ring devices seen this scan: proves the radio works when the ring
    // itself never shows up.
    private val otherDevices = HashSet<String>()

    private val scanning = AtomicBoolean(false)

    // Whether this attempt went straight at a bonded ring, and whether the scan fallback
    // has already been spent. Both are per-connect() and reset in connect().
    private var triedBonded = false
    private var scanFallbackUsed = false
    private var subscribeRetries = 0

    companion object {
        private const val HISTORY_FLUSH_BYTES = 32 * 1024

        /** The legacy writeDescriptor returns only a boolean; this stands in for `false`. */
        private const val STATUS_LEGACY_FALSE = -1
        private const val MAX_SUBSCRIBE_RETRIES = 5
        private const val SUBSCRIBE_RETRY_MS = 250L

        /**
         * The desktop client allows 25 s of scanning plus 30 s for connect + discovery: a
         * worn ring advertises in low-power mode only intermittently, so 20 s of scan
         * alone was routinely not enough. Same budget as iOS.
         */
        const val DEFAULT_TIMEOUT_MS = 50_000L

        /**
         * Extended history data is `0x2f … 0x43`; legacy history packets use event tags
         * >= 0x41. Walk every length-prefixed packet because one notification can contain
         * several. If even one is a summary/control packet, deliver the notification
         * immediately so a trailing terminator can never sit buffered.
         *
         * Kept byte-for-byte identical to `BLETransport.isHistoryPayload` in Swift.
         */
        fun isHistoryPayload(data: ByteArray): Boolean {
            var offset = 0
            while (offset < data.size) {
                if (offset + 2 > data.size) return false
                val tag = data[offset].toInt() and 0xff
                val length = data[offset + 1].toInt() and 0xff
                val end = offset + 2 + length
                if (end > data.size) return false
                val isHistory = tag >= 0x41 ||
                    (tag == 0x2f && length >= 1 && (data[offset + 2].toInt() and 0xff) == 0x43)
                if (!isHistory) return false
                offset = end
            }
            return offset > 0
        }
    }

    /**
     * Scan → connect → discover. Resolves once the write characteristic is ready and
     * every notification subscription has been confirmed.
     */
    suspend fun connect(timeoutMs: Long = DEFAULT_TIMEOUT_MS) {
        if (BlePermissions.missing(context).isNotEmpty()) throw BleError.MissingPermission
        val ad = adapter ?: throw BleError.PoweredOff
        if (!ad.isEnabled) throw BleError.PoweredOff

        suspendCancellableCoroutine { cont ->
            synchronized(lock) {
                // Reject (rather than strand) a second connect while one is in flight OR
                // already connected — a re-entrant connect would swap the notification
                // stream and strand whoever is still draining the current one.
                if (connectCont != null || writeChar != null) {
                    cont.resumeWithException(BleError.Busy)
                    return@suspendCancellableCoroutine
                }
                connectCont = cont
                stage = "scanning — no ring advertisement seen yet"
                // fresh frame stream for this connection (a reconnect must not hand back
                // the previous, already-closed one).
                frames = Channel(Channel.UNLIMITED)
                historyBuffer.reset()
                historyFrames = 0
                historyBytes = 0
                loggedAds.clear()
                otherDevices.clear()
                triedBonded = false
                scanFallbackUsed = false
                subscribeRetries = 0

                // Fail rather than hang forever if the ring never advertises (off the
                // charger / not worn). Stored so finishConnect() can cancel it: a stale
                // timer from a finished attempt must not abort a newer connection.
                val work = Runnable {
                    stopScan()
                    val others: Int
                    var at: String
                    synchronized(lock) {
                        at = stage
                        others = otherDevices.size
                    }
                    // Distinguish "the ring isn't advertising" from "Bluetooth is dead":
                    // the unfiltered scan tells us whether ANY advertisements arrived.
                    if (at.startsWith("subscribing")) {
                        at = "subscribing to the ring's notifications — it answered but " +
                            "would not accept the subscription. The ring serves ONE client " +
                            "at a time: close the official Oura app (force-stop it) and retry"
                    } else if (at.startsWith("GATT-connecting to the bonded ring")) {
                        at = "connecting to the bonded ring: it is paired with this phone " +
                            "but never answered — put it on its charger, and close the " +
                            "official Oura app if it is holding the link"
                    } else if (at.startsWith("scanning")) {
                        at = if (others > 0) {
                            "scanning — saw $others other BLE device(s) but no Oura ring: " +
                                "the ring is connected to another device (phone with the " +
                                "official app? Mac?), off its charger and asleep, or out of battery"
                        } else {
                            "scanning — saw NO BLE advertisements at all: Bluetooth may be " +
                                "off, restricted, or the permission was revoked"
                        }
                    }
                    log("ble", "TIMEOUT while $at")
                    finishConnect(Result.failure(BleError.TimedOut(at)))
                }
                timeoutRunnable = work
                handler.postDelayed(work, timeoutMs)
            }

            cont.invokeOnCancellation { disconnect() }
            log("ble", "connect(timeout: ${timeoutMs / 1000}s) — adapter enabled")

            // A ring that has been onboarded is BONDED to this phone, and a bonded ring
            // that something already holds does not advertise at all — so scanning for it
            // is hopeless in exactly the common case. Android lets us address it directly
            // instead, which is what the official app does. iOS reaches for
            // retrievePeripherals(withIdentifiers:) for the same reason.
            val bonded = bondedRing()
            if (bonded != null) {
                log("ble", "bonded ring '${bonded.safeName()}' ${bonded.address} — connecting directly")
                synchronized(lock) {
                    triedBonded = true
                    stage = "GATT-connecting to the bonded ring"
                }
                connectGatt(bonded)
            } else {
                startScan()
            }
        }
    }

    /**
     * The ring among this phone's bonded devices, if it has been onboarded here. The
     * charging case is excluded for the same reason it is during a scan: it advertises an
     * Oura-looking name and would win.
     */
    private fun bondedRing(): BluetoothDevice? =
        adapter?.bondedDevices?.firstOrNull { device ->
            val name = device.safeName().lowercase()
            name.contains(nameContains.lowercase()) && !name.contains("charging case")
        }

    private fun BluetoothDevice.safeName(): String =
        try { name ?: "" } catch (_: SecurityException) { "" }

    /**
     * The bonded ring did not answer — it may be out of range, or asleep off its charger.
     * Spend the rest of the budget scanning instead of failing outright. Returns true when
     * a scan was started, meaning the caller must NOT resolve the connect.
     */
    private fun scanAfterBondedFailure(): Boolean {
        synchronized(lock) {
            if (connectCont == null || scanFallbackUsed || !triedBonded) return false
            scanFallbackUsed = true
        }
        log("ble", "bonded ring did not answer — falling back to a scan")
        val stale = synchronized(lock) {
            val existing = gatt
            gatt = null
            writeChar = null
            pendingNotifyQueue.clear()
            existing
        }
        try {
            stale?.disconnect()
            stale?.close()
        } catch (_: Exception) {
        }
        startScan()
        return true
    }

    private fun startScan() {
        val scanner = adapter?.bluetoothLeScanner ?: run {
            finishConnect(Result.failure(BleError.PoweredOff))
            return
        }
        synchronized(lock) { stage = "scanning — no ring advertisement seen yet" }
        log("ble", "scanning (unfiltered, all matches) — matching service ${RingUuid.service}")
        // UNFILTERED scan, matching done in onScanResult: an OS-side service filter
        // reports nothing when the ring isn't advertising, which is indistinguishable
        // from broken Bluetooth. Seeing (and counting) other devices' advertisements
        // proves the radio works and pins the failure on the ring itself.
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .build()
        if (scanning.compareAndSet(false, true)) {
            scanner.startScan(null, settings, scanCallback)
        }
    }

    private fun stopScan() {
        if (scanning.compareAndSet(true, false)) {
            try {
                adapter?.bluetoothLeScanner?.stopScan(scanCallback)
            } catch (_: Exception) {
                // the adapter can be torn down under us; nothing to do
            }
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanFailed(errorCode: Int) {
            log("ble", "scan FAILED errorCode=$errorCode")
            finishConnect(Result.failure(BleError.Gatt("scan", errorCode)))
        }

        override fun onScanResult(callbackType: Int, result: ScanResult) {
            // Ignore a discovery that arrives after the attempt already resolved — don't
            // start a stray connection.
            val active = synchronized(lock) { connectCont != null }
            if (!active) {
                stopScan()
                return
            }

            val device = result.device
            val record = result.scanRecord
            val advName = record?.deviceName ?: runCatching { device.name }.getOrNull() ?: ""
            val advServices = record?.serviceUuids?.map { it.uuid } ?: emptyList()
            val lowerName = advName.lowercase()

            // Ring 5 also has a charging case advertising an Oura-looking name and its own
            // charger service. Do not connect to it: it can win the scan race, expose a
            // confusing GATT surface, and then reject the ring auth key.
            val isChargingCase = lowerName.contains("charging case") ||
                advServices.contains(RingUuid.chargingCaseService)
            if (isChargingCase) {
                val key = "${device.address}|case|$advName"
                if (synchronized(lock) { loggedAds.add(key) }) {
                    log(
                        "scan",
                        "saw charging case '${advName.ifEmpty { "<no name>" }}' " +
                            "id=${device.address} rssi=${result.rssi} — waiting for the ring"
                    )
                }
                return
            }

            // A ring advertises the proprietary Oura service UUID; accept on that even
            // when the name is missing (the name lives in the scan response, which a worn
            // ring may not have answered yet). Name match covers factory-reset shapes.
            val isRing = advServices.contains(RingUuid.service) ||
                (advName.isNotEmpty() && lowerName.contains(nameContains.lowercase()))
            if (!isRing) {
                // Count distinct non-ring devices as radio liveness proof; log the first
                // few so the transcript shows what the scan IS seeing.
                val (inserted, count) = synchronized(lock) {
                    val added = otherDevices.add(device.address)
                    added to otherDevices.size
                }
                if (inserted && count <= 5) {
                    log(
                        "scan",
                        "other device '${advName.ifEmpty { "<no name>" }}' rssi=${result.rssi} " +
                            "— not a ring ($count distinct so far)"
                    )
                }
                return
            }

            val adKey = "${device.address}|$advName"
            if (synchronized(lock) { loggedAds.add(adKey) }) {
                val svc = advServices.joinToString(",")
                log(
                    "scan",
                    "saw '${advName.ifEmpty { "<no name>" }}' id=${device.address} " +
                        "rssi=${result.rssi} services=[$svc] connectable=${result.isConnectable}"
                )
            }

            stopScan()
            log("ble", "matched '${advName.ifEmpty { "<no name yet>" }}' rssi=${result.rssi} — GATT connect…")
            synchronized(lock) { stage = "GATT-connecting to the discovered ring" }
            connectGatt(device)
        }
    }

    private fun connectGatt(device: BluetoothDevice) {
        // autoConnect=false: we want the fast direct connect, having just seen the
        // advertisement. TRANSPORT_LE avoids a BR/EDR attempt on dual-mode stacks.
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                log("ble", "GATT connected — requesting a large MTU")
                synchronized(lock) { stage = "negotiating MTU" }
                // CoreBluetooth negotiates the MTU itself; on Android we must ask, and a
                // 23-byte default would multiply the notification count on Ring 5 history.
                if (!g.requestMtu(517)) {
                    // request refused outright — carry on at the default MTU
                    startDiscovery(g)
                }
                return
            }
            if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                log("ble", "peripheral disconnected (status $status)")
                // A direct connect to a bonded ring that is out of range fails here, before
                // any frame has flowed. That is recoverable: scan for the rest of the budget.
                if (scanAfterBondedFailure()) return
                frames.close()
                // don't strand a caller awaiting a connect or write when the link drops
                finishWrite(Result.failure(BleError.Disconnected))
                finishConnect(Result.failure(if (status == 0) BleError.Disconnected else BleError.Gatt("connect", status)))
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            log("ble", "MTU = $mtu (status $status) — discovering the Oura service")
            startDiscovery(g)
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("ble", "service discovery FAILED (status $status)")
                finishConnect(Result.failure(BleError.Gatt("service discovery", status)))
                return
            }
            val found = g.services.joinToString(",") { it.uuid.toString() }
            log("ble", "services: [$found]")
            val svc = g.getService(RingUuid.service) ?: run {
                log("ble", "Oura service 98ED0001 NOT among them — wrong device?")
                finishConnect(Result.failure(BleError.NotFound))
                return
            }

            val notifyChars = ArrayList<BluetoothGattCharacteristic>()
            for (c in svc.characteristics) {
                log("ble", "char …${c.uuid.toString().takeLast(4)} [${props(c)}]")
                if (c.uuid == RingUuid.write) writeChar = c
                if (c.uuid in RingUuid.notify) notifyChars.add(c)
            }
            log("ble", "characteristics discovered — write=${writeChar != null}, notify=${notifyChars.size}")
            if (writeChar == null) {
                log("ble", "no write characteristic (98ED0002) — wrong device?")
                finishConnect(Result.failure(BleError.NoWriteCharacteristic))
                return
            }
            if (notifyChars.isEmpty()) {
                log("ble", "no notify characteristics (98ED0003..0006)")
                finishConnect(Result.failure(BleError.NotFound))
                return
            }

            // Don't report "connected" until every notify subscription is confirmed —
            // otherwise Rust can start syncing before inbound frames flow and miss the
            // ring's early responses. Unlike iOS these must go one at a time: a GATT
            // connection carries exactly one outstanding operation.
            synchronized(lock) {
                stage = "subscribing to notify characteristics"
                pendingNotifyQueue = ArrayDeque(notifyChars)
            }
            subscribeNext(g)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != RingUuid.cccd) return
            val name = descriptor.characteristic.uuid.toString().takeLast(4)
            if (status != BluetoothGatt.GATT_SUCCESS) {
                // A pairing/encryption demand surfaces here (GATT_INSUFFICIENT_AUTHENTICATION
                // / _ENCRYPTION) — the single most diagnostic error on a keyed ring.
                log("ble", "subscribe FAILED on …$name (status $status)")
                finishConnect(Result.failure(BleError.Gatt("subscribe on …$name", status)))
                return
            }
            log("ble", "subscribed …$name")
            subscribeNext(g)
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (c.uuid != RingUuid.write) return
            if (status != BluetoothGatt.GATT_SUCCESS) log("ble", "write NAK (status $status)")
            finishWrite(
                if (status == BluetoothGatt.GATT_SUCCESS) Result.success(Unit)
                else Result.failure(BleError.Gatt("write", status))
            )
        }

        // API 33+ delivers the value as a parameter; below that it lives on the
        // characteristic and must be read before the next callback overwrites it.
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            c: BluetoothGattCharacteristic,
            value: ByteArray,
        ) = onFrame(c, value)

        @Deprecated("Pre-API-33 delivery", ReplaceWith(""))
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                onFrame(c, c.value ?: return)
            }
        }
    }

    private fun startDiscovery(g: BluetoothGatt) {
        synchronized(lock) { stage = "discovering services/characteristics" }
        if (!g.discoverServices()) {
            finishConnect(Result.failure(BleError.Gatt("discoverServices", -1)))
        }
    }

    /** One CCCD write at a time; the connect resolves when the queue drains. */
    private fun subscribeNext(g: BluetoothGatt) {
        val next = synchronized(lock) { pendingNotifyQueue.removeFirstOrNull() }
        if (next == null) {
            log("ble", "all notify subscriptions confirmed — BLE link ready, handing to Rust auth")
            finishConnect(Result.success(Unit))
            return
        }
        g.setCharacteristicNotification(next, true)
        val cccd = next.getDescriptor(RingUuid.cccd)
        if (cccd == null) {
            // No CCCD: setCharacteristicNotification alone is all this characteristic
            // supports. Treat it as subscribed and move on rather than stalling.
            log("ble", "…${next.uuid.toString().takeLast(4)} has no CCCD — local notify only")
            subscribeNext(g)
            return
        }
        val value =
            if (next.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) {
                BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
            } else {
                BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            }
        // Report what the platform actually said. The API-33 overload returns a
        // BluetoothStatusCodes value; the legacy one only a boolean, so it gets
        // STATUS_LEGACY_FALSE to keep the two distinguishable in a bug report.
        val status = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, value)
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = value
                if (g.writeDescriptor(cccd)) BluetoothStatusCodes.SUCCESS else STATUS_LEGACY_FALSE
            }
        }
        if (status == BluetoothStatusCodes.SUCCESS) {
            subscribeRetries = 0
            return
        }

        // A busy stack is transient — most often another app is mid-operation on the same
        // bonded ring. Back off briefly rather than failing the whole connect. Anything
        // else is reported as-is; retrying a rejection would only burn the budget.
        val retriable = status == BluetoothStatusCodes.ERROR_GATT_WRITE_REQUEST_BUSY ||
            status == STATUS_LEGACY_FALSE
        if (retriable && subscribeRetries < MAX_SUBSCRIBE_RETRIES) {
            subscribeRetries++
            log("ble", "CCCD write busy (status $status) — retry $subscribeRetries/$MAX_SUBSCRIBE_RETRIES")
            synchronized(lock) { pendingNotifyQueue.addFirst(next) }
            handler.postDelayed({ subscribeNext(g) }, SUBSCRIBE_RETRY_MS)
            return
        }
        finishConnect(Result.failure(BleError.Gatt("writeDescriptor on …${next.uuid.toString().takeLast(4)}", status)))
    }

    private fun onFrame(c: BluetoothGattCharacteristic, value: ByteArray) {
        if (value.isEmpty()) return
        if (isHistoryPayload(value)) {
            synchronized(lock) {
                historyBuffer.write(value)
                historyFrames++
                historyBytes += value.size
                if (historyBuffer.size() >= HISTORY_FLUSH_BYTES) flushHistoryLocked()
            }
            return
        }

        // A command response / 0x42 batch summary terminates the preceding history burst.
        // Deliver buffered packets first to preserve byte order, then retain one compact
        // diagnostic line instead of tens of thousands of raw payload lines.
        synchronized(lock) {
            flushHistoryLocked()
            if (historyFrames > 0) {
                log("recv", "history payload omitted — $historyFrames BLE frames, ${historyBytes}B")
                historyFrames = 0
                historyBytes = 0
            }
        }
        log("recv", "${value.size}B [${c.uuid.toString().takeLast(4)}] ${value.toHex()}")
        frames.trySend(value)
    }

    private fun flushHistoryLocked() {
        if (historyBuffer.size() == 0) return
        val payload = historyBuffer.toByteArray()
        historyBuffer.reset()
        frames.trySend(payload)
    }

    /**
     * Write a request frame and await the ring's GATT acknowledgement, so the caller
     * (Rust `OuraClient`, which drives requests sequentially) knows the frame landed
     * before sending the next. Resolved in `onCharacteristicWrite`.
     */
    suspend fun write(data: ByteArray) {
        val g = gatt ?: throw BleError.NoWriteCharacteristic
        val wc = writeChar ?: throw BleError.NoWriteCharacteristic
        suspendCancellableCoroutine { cont ->
            synchronized(lock) {
                // Reject (don't strand) an overlapping write — the caller drives writes
                // sequentially, so a second in-flight write is a misuse, not a queue.
                if (writeCont != null) {
                    cont.resumeWithException(BleError.Busy)
                    return@suspendCancellableCoroutine
                }
                writeCont = cont
            }
            log("send", "${data.size}B ${data.toHex()}")
            val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(wc, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    wc.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    wc.value = data
                    g.writeCharacteristic(wc)
                }
            }
            if (!ok) finishWrite(Result.failure(BleError.Gatt("writeCharacteristic", -1)))
        }
    }

    /**
     * Release the ring: cancel the GATT connection (and any scan). The ring has a SINGLE
     * BLE link and only advertises when nothing holds it — an app that keeps the
     * connection after a sync blocks the official app, the Mac, and its own next scan.
     */
    /**
     * Finish the inbound frame stream so a Rust drain blocked on `recv` returns at once
     * (instead of waiting out the quiet window) — used when a write fails so the sync
     * surfaces the error promptly rather than proceeding as if the frame was sent.
     */
    fun abort() {
        frames.close()
    }

    fun disconnect() {
        frames.close()
        val g = synchronized(lock) {
            val existing = gatt
            gatt = null
            writeChar = null
            pendingNotifyQueue.clear()
            existing
        }
        stopScan()
        if (g != null) {
            try {
                g.disconnect()
                g.close()
            } catch (_: Exception) {
            }
            log("ble", "disconnected — ring link released")
        }
    }

    /** Tear down the handler thread. The transport is single-use after this. */
    fun shutdown() {
        disconnect()
        thread.quitSafely()
    }

    private fun finishConnect(result: Result<Unit>) {
        val cont: CancellableContinuation<Unit>?
        synchronized(lock) {
            cont = connectCont
            connectCont = null
            timeoutRunnable?.let { handler.removeCallbacks(it) }
            timeoutRunnable = null
            if (result.isFailure) {
                // Tear down an abandoned/failed attempt so the stack stops delivering its
                // callbacks, and reset the per-attempt state so a stray late descriptor
                // write can't bleed into a later connect.
                pendingNotifyQueue.clear()
                writeChar = null
            }
        }
        if (result.isFailure) {
            val g = synchronized(lock) { val e = gatt; gatt = null; e }
            try {
                g?.disconnect(); g?.close()
            } catch (_: Exception) {
            }
        }
        cont ?: return
        if (cont.isActive) {
            result.fold({ cont.resume(Unit) }, { cont.resumeWithException(it) })
        }
    }

    private fun finishWrite(result: Result<Unit>) {
        val cont = synchronized(lock) {
            val c = writeCont
            writeCont = null
            c
        } ?: return
        if (cont.isActive) {
            result.fold({ cont.resume(Unit) }, { cont.resumeWithException(it) })
        }
    }

    private fun props(c: BluetoothGattCharacteristic): String {
        val p = ArrayList<String>()
        val f = c.properties
        if (f and BluetoothGattCharacteristic.PROPERTY_READ != 0) p.add("read")
        if (f and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) p.add("write")
        if (f and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) p.add("writeNR")
        if (f and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) p.add("notify")
        if (f and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) p.add("indicate")
        return p.joinToString("+")
    }
}

internal fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
