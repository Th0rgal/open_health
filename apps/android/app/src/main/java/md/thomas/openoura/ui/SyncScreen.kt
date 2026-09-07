package md.thomas.openoura.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import md.thomas.openoura.ble.BlePermissions
import md.thomas.openoura.ble.RingSync
import md.thomas.openoura.diag.Diagnostics
import md.thomas.openoura.store.RingKeyStore
import md.thomas.openoura.store.isValidRingKey

/**
 * Pairing instructions, the 32-hex ring-key field, the sync control and a copyable
 * diagnostics transcript. Port of `SyncView` in apps/ios/OuraApp/OuraApp.swift.
 */
@Composable
fun SyncScreen(ring: RingSync, onBack: () -> Unit, onSynced: () -> Unit) {
    val colors = Obs.colors
    val context = LocalContext.current
    var key by remember { mutableStateOf(RingKeyStore.load(context) ?: "") }
    var showDiagnostics by remember { mutableStateOf(false) }
    var permissionNote by remember { mutableStateOf<String?>(null) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        permissionNote = if (granted.values.all { it }) null else BlePermissions.rationale()
        if (granted.values.all { it } && isValidRingKey(key)) {
            ring.syncInBackground(key)
        }
    }

    // A completed sync should refresh what is on screen behind this sheet.
    LaunchedEffect(ring.lastReport) {
        if (ring.lastReport != null) onSynced()
    }

    Sheet("Sync", onBack) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(start = 20.dp, end = 20.dp, bottom = 40.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Text(
                "Put the ring on its charger. A worn ring advertises only intermittently, and " +
                    "it holds a single Bluetooth link — if the official app is connected on " +
                    "another phone, nothing here will find it.",
                fontFamily = Obs.prose,
                fontSize = 14.sp,
                color = colors.ink2,
            )

            Rule("ring auth key")
            BasicTextField(
                value = key,
                onValueChange = { key = it.trim() },
                singleLine = true,
                textStyle = TextStyle(fontFamily = Obs.mono, fontSize = 14.sp, color = colors.ink),
                cursorBrush = SolidColor(colors.ink),
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colors.rule.copy(alpha = 0.35f), RoundedCornerShape(6.dp))
                    .padding(horizontal = 10.dp, vertical = 10.dp),
            )
            Text(
                if (key.isEmpty()) "32 hex characters, exported from the phone that onboarded this ring."
                else if (isValidRingKey(key)) "Looks like a valid key."
                else "A ring key is exactly 32 hex characters — this one is ${key.length}.",
                fontFamily = Obs.mono,
                fontSize = 11.sp,
                color = if (key.isEmpty() || isValidRingKey(key)) colors.muted else colors.bad,
            )

            ActionRow(if (ring.busy) "Syncing…" else "Connect & Sync") {
                if (ring.busy) return@ActionRow
                val missing = BlePermissions.missing(context)
                if (missing.isNotEmpty()) {
                    permissionLauncher.launch(missing.toTypedArray())
                } else {
                    ring.syncInBackground(key)
                }
            }
            permissionNote?.let {
                Text(it, fontFamily = Obs.prose, fontSize = 13.sp, color = colors.bad)
            }
            if (ring.status.isNotEmpty()) {
                Text(ring.status, fontFamily = Obs.mono, fontSize = 12.sp, color = colors.ink2)
            }
            ring.lastReport?.let { report ->
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    ObsStat("serial", report.serial)
                    ObsStat("events synced", "${report.eventsSynced}")
                    ObsStat("newly inserted", "${report.inserted}")
                    ObsStat("next cursor", "${report.nextCursor}")
                }
            }

            Rule("danger zone")
            ActionRow("Reset local sync database") { ring.resetLocalDatabase() }
            Text(
                "Deletes the synced database only. Your ring keeps its history, and the next " +
                    "sync drains it again from the start.",
                fontFamily = Obs.prose,
                fontSize = 12.sp,
                color = colors.muted,
            )

            Rule("diagnostics")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Segmented(
                    options = listOf("hide", "show"),
                    selectedIndex = if (showDiagnostics) 1 else 0,
                    onSelect = { showDiagnostics = it == 1 },
                )
                Spacer(Modifier.weight(1f))
                ActionRowInline("copy all") { copyDiagnostics(context) }
            }
            if (showDiagnostics) {
                val crashes = remember { Diagnostics.previousCrashes(context) }
                if (crashes.isNotEmpty()) {
                    Text(
                        "${crashes.size} previous crash log(s) retained; 'copy all' includes them.",
                        fontFamily = Obs.mono,
                        fontSize = 11.sp,
                        color = colors.bad,
                    )
                }
                Text(
                    Diagnostics.transcript().takeLast(20_000),
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 400.dp)
                        .background(colors.rule.copy(alpha = 0.25f), RoundedCornerShape(6.dp))
                        .padding(10.dp)
                        .verticalScroll(rememberScrollState()),
                    fontFamily = Obs.mono,
                    fontSize = 10.sp,
                    color = colors.ink2,
                )
            }
        }
    }
}

@Composable
private fun ActionRowInline(label: String, onClick: () -> Unit) {
    val colors = Obs.colors
    Text(
        label,
        modifier = Modifier
            .clickable(onClick = onClick)
            .background(colors.rule.copy(alpha = 0.3f), RoundedCornerShape(6.dp))
            .padding(horizontal = 12.dp, vertical = 6.dp),
        fontFamily = Obs.mono,
        fontSize = 12.sp,
        color = colors.ink,
    )
}

private fun copyDiagnostics(context: Context) {
    Diagnostics.flush()
    val crashes = Diagnostics.previousCrashes(context).joinToString("\n\n") {
        "── ${it.name} ──\n${it.readText()}"
    }
    val text = buildString {
        append(Diagnostics.transcript())
        if (crashes.isNotEmpty()) {
            append("\n\n══ previous crashes ══\n")
            append(crashes)
        }
    }
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("open oura diagnostics", text))
}
