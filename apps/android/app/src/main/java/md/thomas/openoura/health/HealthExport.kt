package md.thomas.openoura.health

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.HeightRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.units.Length
import androidx.health.connect.client.units.Mass
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import md.thomas.openoura.data.Profile
import md.thomas.openoura.data.Summary
import md.thomas.openoura.diag.Diagnostics.log
import md.thomas.openoura.store.Prefs
import java.time.Instant

/**
 * Health Connect export — the Android counterpart to apps/ios/OuraApp/HealthExport.swift.
 * Off by default, toggled in the profile screen.
 *
 * De-duplication uses `Metadata.clientRecordId` / `clientRecordVersion`, the exact analogue
 * of `HKMetadataKeySyncIdentifier` / `HKMetadataKeySyncVersion`: re-exporting replaces the
 * previous version of the same logical record rather than piling up duplicates.
 *
 * Two honest divergences from iOS, both recorded in docs/clients.md:
 *  - HRV goes out as **RMSSD**. HealthKit has `heartRateVariabilitySDNN`; Health Connect
 *    only offers `HeartRateVariabilityRmssdRecord`, so we write the metric it actually
 *    stores rather than relabelling one as the other.
 *  - Profile import can read only **height and weight**. Health Connect has no
 *    date-of-birth or biological-sex record, so age and sex remain manual entry.
 */
object HealthExport {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    val permissions: Set<String> = setOf(
        HealthPermission.getWritePermission(SleepSessionRecord::class),
        HealthPermission.getWritePermission(HeartRateRecord::class),
        HealthPermission.getWritePermission(HeartRateVariabilityRmssdRecord::class),
        HealthPermission.getWritePermission(RestingHeartRateRecord::class),
        HealthPermission.getWritePermission(StepsRecord::class),
        HealthPermission.getWritePermission(ActiveCaloriesBurnedRecord::class),
        HealthPermission.getWritePermission(DistanceRecord::class),
        HealthPermission.getWritePermission(ExerciseSessionRecord::class),
        HealthPermission.getReadPermission(HeightRecord::class),
        HealthPermission.getReadPermission(WeightRecord::class),
    )

    fun isAvailable(context: Context): Boolean =
        HealthConnectClient.getSdkStatus(context) == HealthConnectClient.SDK_AVAILABLE

    fun isEnabled(context: Context): Boolean =
        Prefs.of(context).getBoolean(Prefs.HEALTH_EXPORT_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        Prefs.of(context).edit().putBoolean(Prefs.HEALTH_EXPORT_ENABLED, enabled).apply()
        if (!enabled) Prefs.of(context).edit().remove(Prefs.HEALTH_EXPORT_FP).apply()
    }

    /**
     * Push the current summary, skipping when nothing has changed since the last push.
     * Called after each completed load, exactly like the iOS `push()`.
     */
    fun push(context: Context, summary: Summary) {
        if (!isEnabled(context) || !isAvailable(context)) return
        val fp = fingerprint(summary)
        if (Prefs.of(context).getString(Prefs.HEALTH_EXPORT_FP, null) == fp) return
        scope.launch {
            try {
                write(context, summary)
                Prefs.of(context).edit().putString(Prefs.HEALTH_EXPORT_FP, fp).apply()
                log("health", "exported summary fp=$fp")
            } catch (e: Throwable) {
                // A health-export failure must never break the app's own rendering.
                log("health", "export failed: ${e.message}")
            }
        }
    }

    private suspend fun write(context: Context, summary: Summary) {
        val client = HealthConnectClient.getOrCreate(context)
        val granted = client.permissionController.getGrantedPermissions()
        if (!granted.containsAll(permissions.filter { it.contains("WRITE") })) {
            log("health", "write permissions not granted — skipping export")
            return
        }

        val records = ArrayList<androidx.health.connect.client.records.Record>()

        for (night in summary.nights) {
            val start = night.startUnix() ?: continue
            val end = night.endUnix() ?: continue
            if (end <= start) continue
            val id = "openoura.sleep.${night.startDs ?: start}"

            // One in-bed session per night, with the hypnogram as its stages when the
            // on-device model produced one.
            val stages = night.stages?.takeIf { it.size > 1 }?.let { codes ->
                runLengthStages(codes, start, end)
            } ?: emptyList()

            records.add(
                SleepSessionRecord(
                    startTime = Instant.ofEpochSecond(start),
                    startZoneOffset = null,
                    endTime = Instant.ofEpochSecond(end),
                    endZoneOffset = null,
                    stages = stages,
                    metadata = Metadata.manualEntry(clientRecordId = id, clientRecordVersion = 1),
                )
            )

            night.hrvMs?.let { hrv ->
                records.add(
                    HeartRateVariabilityRmssdRecord(
                        time = Instant.ofEpochSecond(end),
                        zoneOffset = null,
                        heartRateVariabilityMillis = hrv,
                        metadata = Metadata.manualEntry(
                            clientRecordId = "openoura.hrv.$id",
                            clientRecordVersion = 1,
                        ),
                    )
                )
            }
            night.rhr?.let { rhr ->
                records.add(
                    RestingHeartRateRecord(
                        time = Instant.ofEpochSecond(end),
                        zoneOffset = null,
                        beatsPerMinute = rhr.toLong(),
                        metadata = Metadata.manualEntry(
                            clientRecordId = "openoura.rhr.$id",
                            clientRecordVersion = 1,
                        ),
                    )
                )
            }
        }

        for ((day, stat) in summary.activityDaily) {
            val start = dayStartUnix(day) ?: continue
            val startInstant = Instant.ofEpochSecond(start)
            val endInstant = startInstant.plusSeconds(86_400)
            stat.steps?.takeIf { it > 0 }?.let {
                records.add(
                    StepsRecord(
                        startTime = startInstant, startZoneOffset = null,
                        endTime = endInstant, endZoneOffset = null,
                        count = it.toLong(),
                        metadata = Metadata.manualEntry(
                            clientRecordId = "openoura.steps.$day", clientRecordVersion = 1,
                        ),
                    )
                )
            }
            stat.activeKcal?.takeIf { it > 0 }?.let {
                records.add(
                    ActiveCaloriesBurnedRecord(
                        startTime = startInstant, startZoneOffset = null,
                        endTime = endInstant, endZoneOffset = null,
                        energy = androidx.health.connect.client.units.Energy.kilocalories(it),
                        metadata = Metadata.manualEntry(
                            clientRecordId = "openoura.kcal.$day", clientRecordVersion = 1,
                        ),
                    )
                )
            }
            stat.distanceM?.takeIf { it > 0 }?.let {
                records.add(
                    DistanceRecord(
                        startTime = startInstant, startZoneOffset = null,
                        endTime = endInstant, endZoneOffset = null,
                        distance = Length.meters(it),
                        metadata = Metadata.manualEntry(
                            clientRecordId = "openoura.distance.$day", clientRecordVersion = 1,
                        ),
                    )
                )
            }
        }

        if (records.isEmpty()) return
        // insertRecords upserts on clientRecordId, so a re-export replaces rather than
        // duplicates — the same contract as HealthKit's sync identifier.
        client.insertRecords(records)
    }

    /** Delete everything this app wrote. */
    fun removeAll(context: Context, onDone: (String) -> Unit) {
        if (!isAvailable(context)) {
            onDone("Health Connect is not available on this device.")
            return
        }
        scope.launch {
            val note = try {
                val client = HealthConnectClient.getOrCreate(context)
                val everything = TimeRangeFilter.before(Instant.now().plusSeconds(86_400))
                client.deleteRecords(SleepSessionRecord::class, everything)
                client.deleteRecords(HeartRateVariabilityRmssdRecord::class, everything)
                client.deleteRecords(RestingHeartRateRecord::class, everything)
                client.deleteRecords(StepsRecord::class, everything)
                client.deleteRecords(ActiveCaloriesBurnedRecord::class, everything)
                client.deleteRecords(DistanceRecord::class, everything)
                client.deleteRecords(ExerciseSessionRecord::class, everything)
                Prefs.of(context).edit().remove(Prefs.HEALTH_EXPORT_FP).apply()
                "Removed Open Oura records from Health Connect."
            } catch (e: Throwable) {
                "Couldn't remove records: ${e.message}"
            }
            withContext(Dispatchers.Main) { onDone(note) }
        }
    }

    /**
     * Prefill height and weight. Age and sex are NOT available — Health Connect has no
     * record type for either.
     */
    fun importProfile(context: Context, onDone: (Profile?, String) -> Unit) {
        if (!isAvailable(context)) {
            onDone(null, "Health Connect is not installed on this device.")
            return
        }
        scope.launch {
            var profile: Profile? = null
            val note = try {
                val client = HealthConnectClient.getOrCreate(context)
                val range = TimeRangeFilter.before(Instant.now())
                val height = client.readRecords(
                    ReadRecordsRequest(HeightRecord::class, range, ascendingOrder = false, pageSize = 1)
                ).records.firstOrNull()?.height?.inMeters
                val weight = client.readRecords(
                    ReadRecordsRequest(WeightRecord::class, range, ascendingOrder = false, pageSize = 1)
                ).records.firstOrNull()?.weight?.inKilograms
                if (height == null && weight == null) {
                    "No height or weight found in Health Connect."
                } else {
                    profile = Profile(heightM = height, weightKg = weight)
                    "Imported ${listOfNotNull(height?.let { "height" }, weight?.let { "weight" }).joinToString(" and ")}."
                }
            } catch (e: Throwable) {
                "Health Connect read failed: ${e.message}"
            }
            withContext(Dispatchers.Main) { onDone(profile, note) }
        }
    }

    /** Skip redundant pushes — same idea as the iOS `fingerprint(summary)`. */
    internal fun fingerprint(s: Summary): String = buildString {
        append(s.nights.size).append('|')
        append(s.nights.lastOrNull()?.startDs ?: 0).append('|')
        append(s.nights.count { (it.stages?.size ?: 0) > 1 }).append('|')
        append(s.activityDaily.size).append('|')
        append(s.workouts.size).append('|')
        append(s.activityDaily.keys.maxOrNull() ?: "")
    }
}

/**
 * Nights carry a local wall-clock `start`/`end` (HH:MM) against an onset date, and cross
 * midnight when `end < start`. Health Connect wants absolute instants, so resolve them in
 * the phone's own zone — the same zone whose offset was handed to `build_summary`.
 */
private fun md.thomas.openoura.data.NightRow.startUnix(): Long? = localUnix(ymd, start)

private fun md.thomas.openoura.data.NightRow.endUnix(): Long? {
    val s = start ?: return null
    val e = end ?: return null
    val base = localUnix(ymd, e) ?: return null
    // an end earlier in the clock than the start means the night crossed midnight
    return if (e < s) base + 86_400 else base
}

private fun localUnix(ymd: String?, hm: String?): Long? {
    val date = ymd ?: return null
    val time = hm ?: return null
    return try {
        val d = java.time.LocalDate.parse(date)
        val parts = time.split(":").mapNotNull { it.toIntOrNull() }
        if (parts.size < 2) return null
        d.atTime(parts[0], parts[1])
            .atZone(java.time.ZoneId.systemDefault())
            .toEpochSecond()
    } catch (_: Exception) {
        null
    }
}

private fun dayStartUnix(day: String): Long? = try {
    java.time.LocalDate.parse(day).atStartOfDay(java.time.ZoneId.systemDefault()).toEpochSecond()
} catch (_: Exception) {
    null
}

private fun runLengthStages(
    codes: List<Int>,
    startUnix: Long,
    endUnix: Long,
): List<SleepSessionRecord.Stage> {
    val out = ArrayList<SleepSessionRecord.Stage>()
    val epoch = (endUnix - startUnix).toDouble() / codes.size
    var i = 0
    while (i < codes.size) {
        val code = codes[i]
        var j = i
        while (j < codes.size && codes[j] == code) j++
        out.add(
            SleepSessionRecord.Stage(
                startTime = Instant.ofEpochSecond(startUnix + (i * epoch).toLong()),
                endTime = Instant.ofEpochSecond(startUnix + (j * epoch).toLong()),
                stage = when (code) {
                    1 -> SleepSessionRecord.STAGE_TYPE_DEEP
                    2 -> SleepSessionRecord.STAGE_TYPE_LIGHT
                    3 -> SleepSessionRecord.STAGE_TYPE_REM
                    else -> SleepSessionRecord.STAGE_TYPE_AWAKE
                },
            )
        )
        i = j
    }
    return out
}
