//! `oura-core` — the UniFFI surface the iOS (and any native) client links against.
//!
//! Everything here delegates to the shared Rust crates that already power the web
//! dashboard (`oura-analysis`, `oura-store`, …). The contract returned to Swift is
//! the same JSON the web client renders, so the two clients never diverge. Bindings
//! are generated with UniFFI (`uniffi-bindgen`), packaged as an `.xcframework`.

use serde_json::json;

uniffi::setup_scaffolding!();

/// Build/version string — a trivial call to validate the FFI round-trip.
#[uniffi::export]
pub fn core_version() -> String {
    format!("oura-core {}", env!("CARGO_PKG_VERSION"))
}

/// HRV RMSSD (ms) over inter-beat intervals — the shared `oura-analysis` algorithm,
/// reachable natively. Returns -1 when the input is too short.
#[uniffi::export]
pub fn rmssd(ibi_ms: Vec<u16>) -> f64 {
    oura_analysis::ported::hrv::rmssd(&ibi_ms).unwrap_or(-1.0)
}

/// The full dashboard summary — the SAME `build_summary()` JSON the web client
/// renders, computed from the synced SQLite DB. `tz_offset` is hours from UTC.
///
/// Models (sleep hypnogram / cardiovascular age / activity sessions) use a
/// [`oura_summary::ModelRunner`]; on-device we'll pass the `.ptl` torch runner.
/// For now [`oura_summary::NoModelRunner`] yields the signal-derived panels
/// (vitals, cardio trend, activity profile, device & data-health, digest) — most
/// of the dashboard — with model fields null until the torch runner is wired.
///
/// Returns the summary JSON string, or `{ "error": "…" }`.
#[uniffi::export]
pub fn summary_json(db_path: String, tz_offset: i64) -> String {
    match oura_summary::build_summary(
        std::path::Path::new(&db_path),
        tz_offset,
        &oura_summary::NoModelRunner,
    ) {
        Ok(v) => v.to_string(),
        Err(e) => json!({ "error": e.to_string() }).to_string(),
    }
}

/// Hourly heart-rate bars for the HR detail screen — one bar per local-clock
/// hour, `{low, high, mean, count}`, plus the newest quality-gated
/// reading as `latest`.
///
/// The nightly RHR trend answers "how have I been sleeping"; this answers "what did
/// my heart do today". `tz_offset` is whole hours from UTC (same as [`summary_json`]),
/// `days` caps the window to that many days back from the newest sample (0 = all).
///
/// Returns the JSON string, or `{ "error": "…" }`.
#[uniffi::export]
pub fn hourly_hr_json(db_path: String, tz_offset: i64, days: u32) -> String {
    match oura_summary::hourly_hr::hourly_hr(std::path::Path::new(&db_path), tz_offset, days) {
        Ok(v) => v.to_string(),
        Err(e) => json!({ "error": e.to_string() }).to_string(),
    }
}

/// Write a clean single-file copy of the database to `dest_path` — the export half of
/// backup/restore.
///
/// Uses `VACUUM INTO`, not a file copy: the store runs in WAL mode, so the `.db` on its
/// own can be missing the most recent events, and `VACUUM INTO` folds the write-ahead
/// log in and produces one consistent, defragmented file. It reads the source without
/// modifying it, so it is safe while the app is otherwise idle.
///
/// The result carries ring data only. The auth key lives in the Keychain and is NOT in
/// here — restoring onto a fresh phone still needs the key entered separately.
#[uniffi::export]
pub fn backup_database(db_path: String, dest_path: String) -> Result<u64, SyncError> {
    let _ = std::fs::remove_file(&dest_path); // VACUUM INTO refuses an existing target
    let conn = rusqlite::Connection::open_with_flags(
        &db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    )
    .map_err(|e| SyncError::Failed(format!("opening {db_path}: {e}")))?;
    conn.execute("VACUUM INTO ?1", [&dest_path])
        .map_err(|e| SyncError::Failed(format!("writing the backup: {e}")))?;
    std::fs::metadata(&dest_path)
        .map(|m| m.len())
        .map_err(|e| SyncError::Failed(format!("backup written but unreadable: {e}")))
}

/// Every decoded event the ring has sent, newest first — the raw-data browser and
/// the debug charts behind it.
///
/// `name_filter` limits to one event type (`hrv_event`, `green_ibi_quality_event`, …);
/// empty means all. `limit` caps the rows returned — the table reaches six figures on
/// a real ring, so the UI pages rather than loading everything.
///
/// Each event carries `unix_s`, resolved through the same boot-epoch [`RingClock`] the
/// summary uses, so points land on the right day even across a ring reboot; the raw
/// `ring_timestamp` and the phone's `captured_unix` are passed through unchanged for
/// when that resolution is itself what you're debugging. `decoded` is the decoder's own
/// JSON object, so a chart can plot any numeric field in it without the FFI knowing
/// what the field means.
///
/// Returns `{ counts: [{name, total, decoded}], events: [...] }`, or `{ "error": … }`.
#[uniffi::export]
pub fn events_json(db_path: String, name_filter: String, limit: u32) -> String {
    match raw_events(&db_path, &name_filter, limit) {
        Ok(v) => v.to_string(),
        Err(e) => json!({ "error": e }).to_string(),
    }
}

fn raw_events(db_path: &str, name_filter: &str, limit: u32) -> Result<serde_json::Value, String> {
    use rusqlite::OpenFlags;
    let conn = rusqlite::Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
    .map_err(|e| e.to_string())?;

    let mut counts = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT name, COUNT(*), SUM(decoded_json IS NOT NULL) \
                 FROM events GROUP BY name ORDER BY COUNT(*) DESC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |r| {
                Ok(json!({
                    "name": r.get::<_, String>(0)?,
                    "total": r.get::<_, i64>(1)?,
                    "decoded": r.get::<_, i64>(2)?,
                }))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            counts.push(row.map_err(|e| e.to_string())?);
        }
    }

    // The type list alone needs no clock and no rows: skip the history scan below.
    if limit == 0 {
        return Ok(json!({ "counts": counts, "events": [] }));
    }

    // The clock needs the WHOLE decoded history to find boot epochs and their
    // time_sync anchors — resolving against a filtered slice would misdate events.
    // Only the anchor tags' JSON is read; loading every decoded body made each
    // screen of the raw-data browser parse the entire archive.
    let all = clock_rows(&conn)?;
    let clock = oura_summary::ring_time::RingClock::from_events(&all);

    let filtered = !name_filter.trim().is_empty();
    let sql = if filtered {
        "SELECT name, tag, ring_timestamp, captured_unix, decoded_json, LENGTH(body) \
         FROM events WHERE name = ?1 ORDER BY captured_unix DESC, id DESC LIMIT ?2"
    } else {
        "SELECT name, tag, ring_timestamp, captured_unix, decoded_json, LENGTH(body) \
         FROM events ORDER BY captured_unix DESC, id DESC LIMIT ?2"
    };
    let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
    let mut events = Vec::new();
    let rows = stmt
        .query_map(rusqlite::params![name_filter.trim(), limit as i64], |r| {
            let ds: i64 = r.get(2)?;
            let captured: i64 = r.get(3)?;
            let decoded: Option<String> = r.get(4)?;
            Ok(json!({
                "name": r.get::<_, String>(0)?,
                "tag": r.get::<_, i64>(1)?,
                "ring_timestamp": ds,
                "captured_unix": captured,
                "unix_s": clock.unix_s(ds, captured),
                "body_len": r.get::<_, i64>(5)?,
                "decoded": decoded
                    .and_then(|d| serde_json::from_str::<serde_json::Value>(&d).ok()),
            }))
        })
        .map_err(|e| e.to_string())?;
    for row in rows {
        events.push(row.map_err(|e| e.to_string())?);
    }

    Ok(json!({ "counts": counts, "events": events }))
}

/// `Store::decoded_events` order and shape, with JSON only for the time anchors
/// (`0x42` time_sync, `0x85` RTC beacon) — the only bodies `RingClock` parses —
/// plus raw `0x41` (`ring_start`, 14 bytes) rows whose `decoded_json` is NULL.
fn clock_rows(conn: &rusqlite::Connection) -> Result<Vec<(i64, u8, String, i64)>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT ring_timestamp, tag, \
                    CASE WHEN tag IN (66, 133) THEN COALESCE(decoded_json, '') ELSE '' END, captured_unix \
             FROM events \
             WHERE decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14) \
             ORDER BY captured_unix, id",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)? as u8,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| e.to_string())?;
    Ok(rows)
}

/// A lightweight, model-free summary (device + data-health only) — kept as a fast
/// path / fallback. Returns `{ serials, device, event_counts, total_events, raw_events, decoded_events }`.
#[uniffi::export]
pub fn quick_summary_json(db_path: String) -> String {
    match quick_summary(&db_path) {
        Ok(v) => v.to_string(),
        Err(e) => json!({ "error": e }).to_string(),
    }
}

fn quick_summary(db_path: &str) -> Result<serde_json::Value, String> {
    let _ = oura_store::storage::Store::migrate_if_writable(db_path);
    let store = oura_store::storage::Store::open_read_only(db_path).map_err(|e| e.to_string())?;
    let serials = store.device_serials().map_err(|e| e.to_string())?;
    let primary = serials.first().cloned().unwrap_or_default();

    let device = store.device_info().map_err(|e| e.to_string())?.map(
        |(
            serial,
            hardware_id,
            firmware,
            api_version,
            mac,
            updated_unix,
            last_sync_unix,
            cursor,
        )| {
            json!({ "serial": serial, "hardware_id": hardware_id, "firmware": firmware,
                    "api_version": api_version, "mac": mac, "updated_unix": updated_unix,
                    "last_sync_unix": last_sync_unix, "next_cursor": cursor })
        },
    );

    let event_counts: Vec<_> = store
        .event_counts(&primary)
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|(kind, n)| json!({ "kind": kind, "count": n }))
        .collect();

    let (raw_events, decoded) = store.event_totals().map_err(|e| e.to_string())?;

    Ok(json!({
        "serials": serials,
        "device": device,
        "event_counts": event_counts,
        "total_events": raw_events,
        "raw_events": raw_events,
        "decoded_events": decoded,
    }))
}

// ── on-device BLE sync over a Swift-provided transport ────────────────────────
// The iOS app does CoreBluetooth; this drives the SAME oura-link OuraClient<T>
// (auth → app stream → drain → store) over a transport that bridges to Swift, so
// the device builds its own DB from a real ring — no btleplug, no cloud.
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use oura_link::transport::Transport;
use oura_link::OuraClient;
use oura_protocol::events::RingEvent;
use oura_store::storage::Store;
use tokio::sync::{broadcast, watch};

/// Swift implements this to send one request frame over CoreBluetooth. Fire-and-
/// forget: the ring's responses come back asynchronously via `push_frame`.
#[uniffi::export(callback_interface)]
pub trait BleWriter: Send + Sync {
    fn write(&self, data: Vec<u8>);
}

/// Swift implements this to receive sync progress. `stage` is a short machine
/// tag ("auth" / "setup" / "sync"); during "sync", `bytes_left` is the ring's
/// own count of event bytes still to transfer (0 = unknown/finished) and
/// `events_synced` the events pulled so far this session.
#[uniffi::export(callback_interface)]
pub trait SyncProgressListener: Send + Sync {
    fn on_progress(&self, stage: String, bytes_left: u64, events_synced: u32);
}

#[derive(uniffi::Record)]
pub struct SyncReport {
    pub serial: String,
    pub events_synced: u32,
    pub inserted: u32,
    pub next_cursor: u32,
}

/// What a successful [`RingSession::pair`] installed.
///
/// `key_hex` is the ONLY copy of the ring's auth key: the ring stores it but never
/// reads it back, and losing it can only be undone by another factory reset. Persist
/// it (Keychain) before doing anything else with this value.
#[derive(uniffi::Record)]
pub struct PairReport {
    pub serial: String,
    pub key_hex: String,
    /// True when the key was freshly minted here, false when `existing_key_hex`
    /// re-installed a key the caller already held.
    pub minted: bool,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SyncError {
    #[error("{0}")]
    Failed(String),
    #[error("storage operation {operation}: {message} (sqlite={code}, extended={extended_code}, checkpoint={checkpoint})")]
    Storage {
        operation: String,
        code: i32,
        extended_code: i32,
        message: String,
        retryable: bool,
        checkpoint: u32,
    },
    #[error("sync interrupted: {reason}")]
    Interrupted { reason: String },
}

fn storage_failure(operation: &str, error: oura_store::error::Error, checkpoint: u32) -> SyncError {
    let (code, extended_code) = match &error {
        oura_store::error::Error::Sqlite {
            code,
            extended_code,
            ..
        } => (*code, *extended_code),
        _ => (0, 0),
    };
    SyncError::Storage {
        operation: operation.into(),
        code,
        extended_code,
        message: error.to_string(),
        retryable: code == 5 || code == 6,
        checkpoint,
    }
}

#[uniffi::export]
pub fn database_integrity(db_path: String) -> Result<String, SyncError> {
    Store::open_read_only(db_path)
        .and_then(|s| s.integrity_check())
        .map_err(|e| storage_failure("quick_check", e, 0))
}

/// Copy the synced database to `out_path` as one self-contained SQLite file
/// (SQLite page backup), so the exact on-phone ring records can be replayed on the
/// desktop with `oura --db <file> …`. The auth key lives in the Keychain and is
/// never part of the database.
#[uniffi::export]
pub fn export_database(db_path: String, out_path: String) -> Result<(), SyncError> {
    Store::open_read_only(db_path)
        .and_then(|s| s.export_to(out_path))
        .map_err(|e| storage_failure("export", e, 0))
}

/// A live sync session bound to a connected ring: Swift creates it with a writer,
/// feeds inbound BLE frames via `push_frame`, then awaits `sync`.
#[derive(uniffi::Object)]
pub struct RingSession {
    stop: watch::Sender<Option<String>>,
    tx: broadcast::Sender<Vec<u8>>,
    writer: Arc<dyn BleWriter>,
}

/// Bridges oura-link's `Transport` onto the Swift writer + the inbound frame channel.
struct FfiTransport {
    tx: broadcast::Sender<Vec<u8>>,
    writer: Arc<dyn BleWriter>,
}

#[async_trait::async_trait]
impl Transport for FfiTransport {
    async fn write(&self, data: &[u8]) -> oura_link::Result<()> {
        self.writer.write(data.to_vec());
        Ok(())
    }
    fn subscribe(&self) -> broadcast::Receiver<Vec<u8>> {
        self.tx.subscribe()
    }
}

/// Drain one incremental range, inserting each event before checkpointing its batch.
/// Returning `false` from either callback makes oura-link withhold the ring ACK, so a
/// database failure can never advance the cursor past data that was not persisted.
async fn drain_into_store(
    client: &OuraClient<FfiTransport>,
    cursor: u32,
    serial: &str,
    store: &Mutex<Store>,
    inserted: &AtomicU32,
    db_err: &Mutex<Option<SyncError>>,
    progress: &dyn SyncProgressListener,
) -> Result<oura_link::client::SyncOutcome, SyncError> {
    let batch = Mutex::new(Vec::new());
    let checkpoint = AtomicU32::new(cursor);
    let outcome = client
        .drain_events(
            cursor,
            |ev| {
                batch.lock().unwrap().push(ev.clone());
                true
            },
            |p| {
                let mut events = batch.lock().unwrap();
                match store
                    .lock()
                    .unwrap()
                    .commit_batch(serial, &events, p.next_cursor)
                {
                    Ok(count) => {
                        inserted.fetch_add(count, Ordering::Relaxed);
                        checkpoint.store(p.next_cursor, Ordering::Relaxed);
                        events.clear();
                        progress.on_progress("sync".into(), p.bytes_left as u64, p.events_synced);
                        true
                    }
                    Err(error) => {
                        *db_err.lock().unwrap() = Some(storage_failure(
                            "commit_batch",
                            error,
                            checkpoint.load(Ordering::Relaxed),
                        ));
                        false
                    }
                }
            },
        )
        .await;
    // A callback failure is a protocol wrapper; the database cause takes precedence.
    if let Some(error) = db_err.lock().unwrap().take() {
        return Err(error);
    }
    outcome.map_err(|e| SyncError::Failed(e.to_string()))
}

/// An empty incremental fetch is normally legitimate. Verify it cheaply by asking
/// for the event immediately before the saved cursor: a healthy cursor points one
/// past that retained event. If the marker is absent, the ring clock rebooted below
/// the cursor (or an older parser persisted an impossible cursor), so a from-zero
/// drain is required. The probe deliberately does not write to SQLite.
async fn cursor_marker_present(
    client: &OuraClient<FfiTransport>,
    cursor: u32,
) -> Result<bool, String> {
    if cursor == 0 {
        return Ok(true);
    }
    let outcome = client
        .drain_events(cursor - 1, |_| true, |_| true)
        .await
        .map_err(|e| e.to_string())?;
    Ok(outcome.events_synced > 0 && outcome.next_cursor >= cursor)
}

fn should_rebase_cursor(cursor: u32, events_synced: u32, marker_present: bool) -> bool {
    cursor > 0 && events_synced == 0 && !marker_present
}

fn is_rejected_history_cursor(error: &str) -> bool {
    error.contains("extended history request failed with result code 0xff")
}

#[uniffi::export(async_runtime = "tokio")]
impl RingSession {
    #[uniffi::constructor]
    pub fn new(writer: Box<dyn BleWriter>) -> Arc<Self> {
        let (tx, _) = broadcast::channel(8192);
        let (stop, _) = watch::channel(None);
        Arc::new(Self {
            stop,
            tx,
            writer: Arc::from(writer),
        })
    }

    /// Interrupts even an idle Rust receive; a finished Swift AsyncStream cannot do this.
    pub fn cancel(&self, reason: String) {
        self.stop.send_replace(Some(reason));
    }

    /// Swift pushes each inbound BLE notification frame here.
    pub fn push_frame(&self, data: Vec<u8>) {
        let _ = self.tx.send(data);
    }

    /// Authenticate, set up the app stream, and drain history events into the DB at
    /// `db_path`. `key_hex` is the 32-char ring auth key. `progress` receives stage
    /// changes and per-batch drain progress. Returns the sync counts.
    ///
    /// The drain checkpoints its cursor after every batch, so a failed call can be
    /// retried (reconnect + call again) and resumes where it left off.
    pub async fn sync(
        &self,
        db_path: String,
        key_hex: String,
        progress: Box<dyn SyncProgressListener>,
    ) -> Result<SyncReport, SyncError> {
        let mut stop = self.stop.subscribe();
        if let Some(reason) = stop.borrow().clone() {
            return Err(SyncError::Interrupted { reason });
        }
        tokio::select! {
            biased;
            _ = stop.changed() => Err(SyncError::Interrupted {
                reason: stop.borrow().clone().unwrap_or_else(|| "cancelled".into()) }),
            result = self.sync_inner(db_path, key_hex, progress) => result,
        }
    }

    /// Pair with a **factory-reset** ring: install a 16-byte app-auth key over the
    /// already-connected link and verify it authenticates. This is the on-device
    /// equivalent of the desktop `oura pair`, so a ring can be adopted from the phone
    /// alone — no computer, and the key never leaves the device.
    ///
    /// `existing_key_hex` re-installs a key the caller already holds (keeping a
    /// re-paired ring's history attributable to the same key); `None` mints a fresh
    /// one from the system CSPRNG.
    ///
    /// Only valid on a reset ring: one that still holds a key answers `set_auth_key`
    /// with a non-zero status and the call fails without changing anything.
    pub async fn pair(&self, existing_key_hex: Option<String>) -> Result<PairReport, SyncError> {
        let mut stop = self.stop.subscribe();
        if let Some(reason) = stop.borrow().clone() {
            return Err(SyncError::Interrupted { reason });
        }
        tokio::select! {
            biased;
            _ = stop.changed() => Err(SyncError::Interrupted {
                reason: stop.borrow().clone().unwrap_or_else(|| "cancelled".into()) }),
            result = self.pair_inner(existing_key_hex) => result,
        }
    }

    /// **DESTRUCTIVE.** Wipe the ring back to factory state: the installed auth key,
    /// every BLE bond, the on-ring event buffer and the anthropometric profile are
    /// erased. Sync first — anything still only on the ring is lost.
    ///
    /// `confirm_serial` must equal the serial of the ring that actually answers, so a
    /// tap can never wipe a different ring that happened to win the scan (a partner's
    /// ring on the same charger, say). A mismatch aborts before anything is sent.
    ///
    /// The ring normally drops the link before replying, so an empty response is the
    /// expected success path. Afterwards the ring is pairable again — `pair` mints a
    /// new key — and its event counter keeps running, so start a fresh database
    /// rather than resuming the old cursor.
    pub async fn factory_reset(
        &self,
        key_hex: String,
        confirm_serial: String,
    ) -> Result<String, SyncError> {
        let mut stop = self.stop.subscribe();
        if let Some(reason) = stop.borrow().clone() {
            return Err(SyncError::Interrupted { reason });
        }
        tokio::select! {
            biased;
            _ = stop.changed() => Err(SyncError::Interrupted {
                reason: stop.borrow().clone().unwrap_or_else(|| "cancelled".into()) }),
            result = self.factory_reset_inner(key_hex, confirm_serial) => result,
        }
    }
}

impl RingSession {
    /// The wipe opcode is assembled here, at the call site, rather than in
    /// `oura-protocol` — upstream deliberately keeps it out of the shared protocol
    /// crate so nothing that merely links the decoder can emit it.
    const FACTORY_RESET_REQUEST: [u8; 2] = [0x1a, 0x00];

    async fn factory_reset_inner(
        &self,
        key_hex: String,
        confirm_serial: String,
    ) -> Result<String, SyncError> {
        let fail = SyncError::Failed;
        let key = parse_key(&key_hex)
            .ok_or_else(|| fail("auth key must be 32 hex chars".into()))?;
        let transport = FfiTransport {
            tx: self.tx.clone(),
            writer: self.writer.clone(),
        };
        let client = OuraClient::new(transport);

        let serial = client
            .serial()
            .await
            .map_err(|e| fail(format!("reading the ring serial: {e}")))?;
        let expected = confirm_serial.trim();
        if !expected.eq_ignore_ascii_case(&serial) {
            return Err(fail(format!(
                "refusing to wipe: the ring that answered is {serial}, not {expected}"
            )));
        }
        client
            .authenticate(&key)
            .await
            .map_err(|e| fail(format!("authenticating before wipe: {e}")))?;

        // An empty reply is the expected outcome: the ring resets and drops the link
        // faster than it answers. A transport error here is therefore not a failure.
        let _ = oura_link::transport::transact(
            client.transport(),
            &Self::FACTORY_RESET_REQUEST,
            std::time::Duration::from_secs(3),
        )
        .await;
        Ok(serial)
    }

    async fn pair_inner(
        &self,
        existing_key_hex: Option<String>,
    ) -> Result<PairReport, SyncError> {
        let fail = SyncError::Failed;
        let (key, minted) = match existing_key_hex
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            Some(hex) => (
                parse_key(hex).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?,
                false,
            ),
            None => (random_key().map_err(fail)?, true),
        };
        let transport = FfiTransport {
            tx: self.tx.clone(),
            writer: self.writer.clone(),
        };
        let client = OuraClient::new(transport);

        // Read the serial first: it needs no auth, so a dead link or a charging case
        // that won the scan fails here rather than after a key is already installed.
        let serial = client
            .serial()
            .await
            .map_err(|e| fail(format!("reading the ring serial: {e}")))?;
        client
            .set_auth_key(&key)
            .await
            .map_err(|e| fail(format!("{e} — is the ring factory-reset?")))?;
        client
            .authenticate(&key)
            .await
            .map_err(|e| fail(format!("key installed on {serial} but verification failed: {e}")))?;
        Ok(PairReport {
            serial,
            key_hex: to_hex(&key),
            minted,
        })
    }

    async fn sync_inner(
        &self,
        db_path: String,
        key_hex: String,
        progress: Box<dyn SyncProgressListener>,
    ) -> Result<SyncReport, SyncError> {
        let fail = |e: String| SyncError::Failed(e);
        let key =
            parse_key(&key_hex).ok_or_else(|| fail("auth key must be 32 hex chars".into()))?;
        let transport = FfiTransport {
            tx: self.tx.clone(),
            writer: self.writer.clone(),
        };
        let client = OuraClient::new(transport);

        progress.on_progress("auth".into(), 0, 0);
        client
            .authenticate(&key)
            .await
            .map_err(|e| fail(e.to_string()))?;
        progress.on_progress("setup".into(), 0, 0);
        client
            .setup_app_stream()
            .await
            .map_err(|e| fail(e.to_string()))?;
        // Push the phone's clock to the ring so this boot logs a `time_sync` anchor.
        // Without one, a rebooted ring's nights have no bridge to wall-clock time:
        // `time_sync` is the only wall-clock anchor in the event stream, and it is
        // retroactive — one of them dates every event in the same boot epoch.
        progress.on_progress("time".into(), 0, 0);
        if let Err(error) = client.sync_time_app().await {
            progress.on_progress(format!("time_sync skipped: {error}"), 0, 0);
            // The app-layer command is refused by some firmware; the plain one is not.
            let _ = client.sync_time().await;
        }
        // Ask the ring to run its sleep analysis before draining. Bedtime periods are
        // the ONLY thing build_summary turns into nights, and the ring writes one when
        // it postprocesses a sleep — not while it is recording one. Triggering it here
        // gives the ring the whole drain to finish, so a fast postprocess lands in this
        // sync rather than the next. Fire-and-forget: a refusal is not a sync failure.
        let _ = client.check_sleep_analysis(false).await;
        let serial = client.serial().await.unwrap_or_else(|_| "unknown".into());
        let info = client.firmware().await.ok();

        // Mutex<Store> keeps the future Send across the drain's awaits (rusqlite's
        // Connection is !Sync), while still writing incrementally (no buffering).
        let store = Mutex::new(Store::open(&db_path).map_err(|e| storage_failure("open", e, 0))?);
        store
            .lock()
            .unwrap()
            .upsert_device(&serial, None, info.as_ref())
            .map_err(|e| storage_failure("upsert_device", e, 0))?;
        let cursor = store
            .lock()
            .unwrap()
            .cursor(&serial)
            .map_err(|e| storage_failure("read_cursor", e, 0))?;

        let inserted = AtomicU32::new(0);
        let db_err: Mutex<Option<SyncError>> = Mutex::new(None);
        progress.on_progress("sync".into(), 0, 0);
        let first_drain = drain_into_store(
            &client,
            cursor,
            &serial,
            &store,
            &inserted,
            &db_err,
            progress.as_ref(),
        )
        .await;
        let mut rejected_cursor_rebased = false;
        let mut outcome = match first_drain {
            Ok(outcome) => outcome,
            Err(error) if cursor > 0 && is_rejected_history_cursor(&error.to_string()) => {
                // Ring 5 rejects a stale/end cursor with ExtGetEvent result 0xff. Older
                // builds incorrectly treated that as a successful empty terminal batch,
                // leaving retained history unseen. Rebase transactionally; inserts are
                // deduplicated, and checkpoint zero makes a reconnect resume recovery.
                store
                    .lock()
                    .unwrap()
                    .set_cursor(&serial, 0)
                    .map_err(|e| storage_failure("rebase_cursor", e, cursor))?;
                progress.on_progress("rebase".into(), 0, 0);
                rejected_cursor_rebased = true;
                drain_into_store(
                    &client,
                    0,
                    &serial,
                    &store,
                    &inserted,
                    &db_err,
                    progress.as_ref(),
                )
                .await?
            }
            Err(error) => return Err(error),
        };

        if outcome.events_synced == 0 && cursor > 0 && !rejected_cursor_rebased {
            let marker_present = cursor_marker_present(&client, cursor)
                .await
                .map_err(&fail)?;
            if should_rebase_cursor(cursor, outcome.events_synced, marker_present) {
                // Checkpoint zero before the recovery drain: if BLE drops midway, the
                // existing reconnect loop resumes the new epoch instead of retrying the
                // stale/poisoned cursor and reporting another false success.
                store
                    .lock()
                    .unwrap()
                    .set_cursor(&serial, 0)
                    .map_err(|e| storage_failure("rebase_cursor", e, cursor))?;
                progress.on_progress("rebase".into(), 0, 0);
                outcome = drain_into_store(
                    &client,
                    0,
                    &serial,
                    &store,
                    &inserted,
                    &db_err,
                    progress.as_ref(),
                )
                .await?;
            }
        }
        // Second, ring-independent anchor: the newest drained ring timestamp is at
        // most minutes old, so pairing it with the phone clock dates this boot even
        // when the firmware never emits time_sync/rtc_beacon events.
        if let Some(anchor) = phone_anchor_event(outcome.events_synced, outcome.next_cursor, now_unix()) {
            if let Err(error) = store.lock().unwrap().insert_event(&serial, &anchor) {
                progress.on_progress(format!("phone anchor not saved: {error}"), 0, 0);
            }
        }
        Ok(SyncReport {
            serial,
            events_synced: outcome.events_synced,
            inserted: inserted.into_inner(),
            next_cursor: outcome.next_cursor,
        })
    }
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// A synthetic `time_sync` (0x42) row pairing the newest drained ring timestamp
/// with the phone clock. Only meaningful when this sync actually observed new ring
/// time; the body keeps the standard 4-byte unix prefix (so `redecode` still yields
/// `unix_time`) followed by a "phone" marker, and `decoded.source` says so.
fn phone_anchor_event(events_synced: u32, next_cursor: u32, now: u64) -> Option<RingEvent> {
    if events_synced == 0 || next_cursor == 0 || now == 0 {
        return None;
    }
    let unix = u32::try_from(now).ok()?;
    let mut body = unix.to_le_bytes().to_vec();
    body.extend_from_slice(b"phone");
    Some(RingEvent {
        tag: 0x42,
        name: oura_protocol::events::event_name(0x42),
        timestamp: next_cursor - 1,
        body,
        decoded: Some(json!({ "unix_time": unix, "source": "phone" })),
    })
}

/// A fresh 16-byte auth key from the system CSPRNG (`SecRandomCopyBytes` on Apple).
fn random_key() -> Result<[u8; 16], String> {
    let mut key = [0u8; 16];
    getrandom::getrandom(&mut key).map_err(|e| format!("system CSPRNG unavailable: {e}"))?;
    Ok(key)
}

fn to_hex(key: &[u8; 16]) -> String {
    key.iter().map(|b| format!("{b:02x}")).collect()
}

fn parse_key(hex: &str) -> Option<[u8; 16]> {
    let hex = hex.trim();
    if hex.len() != 32 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut key = [0u8; 16];
    for i in 0..16 {
        key[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn minted_keys_round_trip_through_hex() {
        let key = random_key().expect("system CSPRNG");
        let hex = to_hex(&key);
        assert_eq!(hex.len(), 32);
        assert!(hex.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
        assert_eq!(parse_key(&hex), Some(key));
    }

    #[test]
    fn minted_keys_are_not_constant() {
        assert_ne!(random_key().unwrap(), random_key().unwrap());
    }

    struct SilentWriter;
    impl BleWriter for SilentWriter {
        fn write(&self, _: Vec<u8>) {}
    }
    struct IgnoreProgress;
    impl SyncProgressListener for IgnoreProgress {
        fn on_progress(&self, _: String, _: u64, _: u32) {}
    }

    #[tokio::test]
    async fn cancellation_interrupts_rust_waiting_for_auth_reply() {
        let session = RingSession::new(Box::new(SilentWriter));
        let running = session.clone();
        let task = tokio::spawn(async move {
            running
                .sync(
                    "unused.db".into(),
                    "0123456789abcdef0123456789abcdef".into(),
                    Box::new(IgnoreProgress),
                )
                .await
        });
        tokio::task::yield_now().await;
        session.cancel("background".into());
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(result, Err(SyncError::Interrupted { reason }) if reason == "background"));
    }

    #[test]
    fn phone_anchor_requires_new_ring_time() {
        assert!(phone_anchor_event(0, 500, 1_789_056_420).is_none());
        assert!(phone_anchor_event(3, 0, 1_789_056_420).is_none());
        let anchor = phone_anchor_event(3, 705_001, 1_789_056_420).unwrap();
        assert_eq!(anchor.tag, 0x42);
        assert_eq!(anchor.timestamp, 705_000);
        assert_eq!(anchor.decoded.as_ref().unwrap()["source"], "phone");
        assert_eq!(
            oura_protocol::events::decode_event_body(0x42, &anchor.body).unwrap()["unix_time"],
            1_789_056_420u32
        );
    }

    #[test]
    fn phone_anchor_round_trips_through_the_store() {
        let store = Store::open_in_memory().unwrap();
        let anchor = phone_anchor_event(1, 705_001, 1_789_056_420).unwrap();
        assert!(store.insert_event("ring", &anchor).unwrap());
        assert!(!store.insert_event("ring", &anchor).unwrap());
        let events = store.decoded_events().unwrap();
        assert_eq!(events.len(), 1);
        let (ds, tag, json, _) = &events[0];
        assert_eq!((*ds, *tag), (705_000, 0x42));
        assert!(json.contains("\"source\":\"phone\""));
    }

    #[test]
    fn export_database_writes_a_self_contained_copy() {
        let dir = std::env::temp_dir().join(format!("oura-export-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("oura.db");
        let out = dir.join("export.db");
        let store = Store::open(&src).unwrap();
        let anchor = phone_anchor_event(1, 705_001, 1_789_056_420).unwrap();
        store.insert_event("ring", &anchor).unwrap();
        // Keep the writer open so the committed event is still in the WAL.
        assert!(src.with_extension("db-wal").exists());
        std::fs::write(&out, b"stale").unwrap();
        export_database(src.to_string_lossy().into(), out.to_string_lossy().into()).unwrap();
        let copy = Store::open_read_only(&out).unwrap();
        assert_eq!(copy.decoded_events().unwrap().len(), 1);
        assert!(!out.with_extension("db-wal").exists());
        drop(copy);
        drop(store);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn sqlite_details_survive_ffi_classification() {
        let error = storage_failure(
            "commit_batch",
            oura_store::error::Error::Sqlite {
                code: 10,
                extended_code: 778,
                message: "disk I/O".into(),
            },
            42,
        );
        assert!(matches!(
            error,
            SyncError::Storage {
                code: 10,
                extended_code: 778,
                checkpoint: 42,
                retryable: false,
                ..
            }
        ));
    }

    #[test]
    fn rebases_empty_sync_when_saved_cursor_marker_is_missing() {
        assert!(should_rebase_cursor(184_190_174, 0, false));
    }

    #[test]
    fn keeps_healthy_or_progressing_cursor() {
        assert!(!should_rebase_cursor(5_586_831, 0, true));
        assert!(!should_rebase_cursor(5_586_831, 12, false));
        assert!(!should_rebase_cursor(0, 0, false));
    }

    #[test]
    fn recognizes_ring5_rejected_cursor_result() {
        assert!(is_rejected_history_cursor(
            "protocol error: extended history request failed with result code 0xff"
        ));
        assert!(!is_rejected_history_cursor("BLE link lost mid-batch"));
    }
}

#[cfg(test)]
mod raw_event_tests {
    use super::*;

    #[test]
    fn backup_round_trips_through_vacuum_into() {
        let dir = std::env::temp_dir().join(format!("oura-core-backup-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("oura.db");
        let dst = dir.join("backup.db");
        let _ = std::fs::remove_file(&src);
        let _ = std::fs::remove_file(&dst);
        drop(oura_store::storage::Store::open(src.to_str().unwrap()).unwrap());

        let bytes = backup_database(src.to_str().unwrap().into(), dst.to_str().unwrap().into())
            .expect("backup");
        assert!(bytes > 0);
        // the copy must be a usable store, not just bytes on disk
        assert!(database_integrity(dst.to_str().unwrap().into())
            .expect("integrity")
            .contains("ok"));
        // and re-running must overwrite rather than fail on an existing file
        backup_database(src.to_str().unwrap().into(), dst.to_str().unwrap().into())
            .expect("second backup");
        let _ = std::fs::remove_file(&src);
        let _ = std::fs::remove_file(&dst);
    }

    #[test]
    fn missing_database_reports_an_error_object() {
        let out = events_json("/nonexistent/oura.db".into(), String::new(), 10);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert!(v.get("error").is_some(), "{out}");
    }

    #[test]
    fn raw_events_clock_matches_the_full_history_clock() {
        let dir = std::env::temp_dir().join(format!("oura-core-clock-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("oura.db");
        let _ = std::fs::remove_file(&db);
        drop(oura_store::storage::Store::open(db.to_str().unwrap()).unwrap());
        let conn = rusqlite::Connection::open(&db).unwrap();
        // Two boots: a time_sync anchor in the first, an RTC beacon in the second,
        // and plain rows (with JSON the light query must not need) around them.
        let rows: [(i64, i64, &str, &str, i64); 6] = [
            (0x42, 20_000, "time_sync_ind", r#"{"unix_time":1782939604}"#, 1_783_000_000),
            (0x60, 25_000, "ibi_event", r#"{"ibi_ms":[800,810]}"#, 1_783_000_000),
            (0x46, 30_000, "temp_event", r#"{"temps_c":[34.5]}"#, 1_783_000_100),
            (0x60, 1_000, "ibi_event", r#"{"ibi_ms":[790]}"#, 1_783_100_000),
            (0x85, 2_000, "rtc_beacon", r#"{"unix_time":1783099000}"#, 1_783_100_000),
            (0x46, 9_000, "temp_event", r#"{"temps_c":[35.0]}"#, 1_783_100_050),
        ];
        for (tag, ds, name, json, cu) in rows {
            conn.execute(
                "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix) \
                 VALUES ('S1', ?1, ?2, ?3, X'00', ?4, ?5)",
                rusqlite::params![tag, name, ds, json, cu],
            )
            .unwrap();
        }
        // Also insert a historical raw `ring_start` (0x41 = 65) with NULL decoded_json and 14-byte body.
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix) \
             VALUES ('S1', 65, 'ring_start', 5000, X'0400000038020114010001020100', NULL, 1783100020)",
            [],
        )
        .unwrap();
        let full = oura_store::storage::Store::open_read_only(db.to_str().unwrap())
            .unwrap()
            .decoded_events()
            .unwrap();
        let light = clock_rows(&conn).unwrap();
        assert_eq!(full.len(), light.len());
        let a = oura_summary::ring_time::RingClock::from_events(&full);
        let b = oura_summary::ring_time::RingClock::from_events(&light);
        for (ds, _, _, cu) in &full {
            assert_eq!(a.unix_s(*ds, *cu), b.unix_s(*ds, *cu), "ds={ds} cu={cu}");
        }

        // The type list alone (limit 0) returns counts without any rows.
        let out = events_json(db.to_str().unwrap().into(), String::new(), 0);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["counts"].as_array().unwrap().len(), 5, "{out}");
        assert_eq!(v["events"].as_array().unwrap().len(), 0, "{out}");
        let out = events_json(db.to_str().unwrap().into(), "temp_event".into(), 10);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["events"].as_array().unwrap().len(), 2, "{out}");
        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn empty_database_yields_empty_lists() {
        let dir = std::env::temp_dir().join(format!("oura-core-raw-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("oura.db");
        let _ = std::fs::remove_file(&db);
        // Store::open creates the schema.
        drop(oura_store::storage::Store::open(db.to_str().unwrap()).unwrap());
        let out = events_json(db.to_str().unwrap().into(), String::new(), 10);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["counts"].as_array().unwrap().len(), 0, "{out}");
        assert_eq!(v["events"].as_array().unwrap().len(), 0, "{out}");
        let _ = std::fs::remove_file(&db);
    }

    fn event_frame(tag: u8, ts: u32, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![tag, (4 + payload.len()) as u8];
        out.extend_from_slice(&ts.to_le_bytes());
        out.extend_from_slice(payload);
        out
    }

    fn summary_frame(events_received: u8, bytes_left: u32) -> Vec<u8> {
        let mut out = vec![0x11, 0x06, events_received, 0x00];
        out.extend_from_slice(&bytes_left.to_le_bytes());
        out
    }

    #[tokio::test]
    async fn drain_into_store_terminates_on_replayed_legacy_tail_and_withholds_cursor_on_batch_error() {
        struct NoProgress;
        impl SyncProgressListener for NoProgress {
            fn on_progress(&self, _: String, _: u64, _: u32) {}
        }
        struct ScriptedWriter {
            tx: broadcast::Sender<Vec<u8>>,
            step: AtomicU32,
        }
        impl BleWriter for ScriptedWriter {
            fn write(&self, data: Vec<u8>) {
                let tx = self.tx.clone();
                match data.first().copied() {
                    Some(0x28) => {
                        let _ = tx.send(vec![0x29, 0x01, 0x00]);
                    }
                    Some(0x2f) => {
                        // Unsupported ExtGetEvent -> fall back to legacy GetEvent (0x10)
                        let _ = tx.send(vec![0x2f, 0x02, 0x00, 0x41]);
                    }
                    Some(0x10) => {
                        let s = self.step.fetch_add(1, Ordering::SeqCst);
                        match s {
                            0 => {
                                // Batch 1: two events at ts=100, 101, bytes_left=16
                                let _ = tx.send(event_frame(0x43, 100, &[90, 10]));
                                let _ = tx.send(event_frame(0x43, 101, &[89, 10]));
                                let _ = tx.send(summary_frame(2, 16));
                            }
                            1 => {
                                // Batch 2: replayed identical tail (ts=100, 101) with bytes_left=0
                                // — must terminate cleanly without looping forever!
                                let _ = tx.send(event_frame(0x43, 100, &[90, 10]));
                                let _ = tx.send(event_frame(0x43, 101, &[89, 10]));
                                let _ = tx.send(summary_frame(2, 0));
                            }
                            _ => {
                                let _ = tx.send(summary_frame(0, 0));
                            }
                        }
                    }
                    _ => {}
                }
            }
        }

        let (tx, _) = broadcast::channel(64);
        let writer = Arc::new(ScriptedWriter {
            tx: tx.clone(),
            step: AtomicU32::new(0),
        });
        let client = OuraClient::new(FfiTransport {
            tx: tx.clone(),
            writer: writer.clone(),
        })
        .with_quiet(std::time::Duration::from_millis(20));
        let store = Mutex::new(Store::open_in_memory().unwrap());
        store.lock().unwrap().upsert_device("S1", None, None).unwrap();
        let inserted = AtomicU32::new(0);
        let db_err = Mutex::new(None);
        let progress = NoProgress;

        let outcome = drain_into_store(&client, 0, "S1", &store, &inserted, &db_err, &progress)
            .await
            .unwrap();
        assert_eq!(outcome.events_synced, 2);
        assert_eq!(outcome.next_cursor, 102);
        assert_eq!(inserted.load(Ordering::Relaxed), 2);
        assert_eq!(store.lock().unwrap().cursor("S1").unwrap(), 102);

        // Now test that a database commit failure on batch 2 preserves batch 1's checkpoint (202)
        // and never advances the cursor to batch 2's cursor (204).
        struct FailingSecondBatchWriter {
            tx: broadcast::Sender<Vec<u8>>,
            step: AtomicU32,
        }
        impl BleWriter for FailingSecondBatchWriter {
            fn write(&self, data: Vec<u8>) {
                let tx = self.tx.clone();
                match data.first().copied() {
                    Some(0x28) => {
                        let _ = tx.send(vec![0x29, 0x01, 0x00]);
                    }
                    Some(0x2f) => {
                        let _ = tx.send(vec![0x2f, 0x02, 0x00, 0x41]);
                    }
                    Some(0x10) => {
                        let s = self.step.fetch_add(1, Ordering::SeqCst);
                        match s {
                            0 => {
                                let _ = tx.send(event_frame(0x43, 200, &[88, 10]));
                                let _ = tx.send(event_frame(0x43, 201, &[87, 10]));
                                let _ = tx.send(summary_frame(2, 16));
                            }
                            1 => {
                                let _ = tx.send(event_frame(0x43, 202, &[86, 10]));
                                let _ = tx.send(event_frame(0x43, 203, &[85, 10]));
                                let _ = tx.send(summary_frame(2, 0));
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                }
            }
        }

        let dir = std::env::temp_dir().join(format!("oura-core-batch-err-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db_path = dir.join("batch.db");
        let _ = std::fs::remove_file(&db_path);
        let store2 = Mutex::new(Store::open(&db_path).unwrap());
        store2.lock().unwrap().upsert_device("S1", None, None).unwrap();
        // Install a SQLite trigger that aborts when ring_timestamp >= 202 so batch 1 (200..201)
        // commits cleanly at cursor 202 while batch 2 (202..203) rolls back.
        {
            let conn = rusqlite::Connection::open(&db_path).unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_batch_2 BEFORE INSERT ON events \
                 WHEN NEW.ring_timestamp >= 202 BEGIN \
                     SELECT RAISE(ABORT, 'simulated disk error on batch 2'); \
                 END;",
            )
            .unwrap();
        }
        let (tx2, _) = broadcast::channel(64);
        let writer2 = Arc::new(FailingSecondBatchWriter {
            tx: tx2.clone(),
            step: AtomicU32::new(0),
        });
        let client2 = OuraClient::new(FfiTransport {
            tx: tx2,
            writer: writer2,
        })
        .with_quiet(std::time::Duration::from_millis(20));
        let inserted2 = AtomicU32::new(0);
        let db_err2 = Mutex::new(None);
        let err = drain_into_store(&client2, 200, "S1", &store2, &inserted2, &db_err2, &progress)
            .await
            .expect_err("second batch must fail");
        assert!(matches!(err, SyncError::Storage { checkpoint: 202, .. }), "{err:?}");
        // Cursor in SQLite must still be 202 (batch 1), NOT 204 (batch 2)!
        assert_eq!(store2.lock().unwrap().cursor("S1").unwrap(), 202);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
