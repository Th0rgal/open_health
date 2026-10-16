//! Daily step totals from the ring's real-step records (open_oura `ported::real_steps`,
//! `ported::step_counter`).
//!
//! This is an alternative to the ring's own step counter (the step byte of `activity_information`).
//! It runs only when the user picks it in the profile settings (`"steps_source": "model"`) and the
//! step counter's weights are installed; the weights are not part of the
//! repository, so a build without them (such as the desktop CLI) leaves the setting
//! unavailable and the ring counter in use.

use crate::ring_time::RingClock;
use oura_analysis::ported::real_steps::{count_steps, Config};
use oura_analysis::ported::step_counter::{stepmotion_from_decoder, StepCounter};
use oura_analysis::ported::steps_motion_decoder::decode;
use oura_protocol::events::pair_real_steps;
use std::collections::{BTreeMap, HashMap};
use std::path::Path;
use std::sync::{Arc, RwLock};

static COUNTER: RwLock<Option<Arc<StepCounter>>> = RwLock::new(None);

/// Tags read: the two real-step records and the 30 s motion event.
const TAGS: [u8; 3] = [0x7e, 0x7f, 0x47];

/// Loads the step counter's weights from `path`. Returns false (and keeps the model unavailable)
/// when the file is missing or not a valid blob.
pub fn load_step_counter(path: &str) -> bool {
    let Ok(bytes) = std::fs::read(path) else { return false };
    match StepCounter::from_bytes(&bytes) {
        Some(c) => {
            *COUNTER.write().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(c));
            true
        }
        None => false,
    }
}

pub fn available() -> bool {
    COUNTER.read().unwrap_or_else(|e| e.into_inner()).is_some()
}

/// The stored real-step and motion records with the Unix time (ms) of each ring timestamp.
fn read_records(db: &Path, clock: &RingClock) -> Option<(Vec<(u8, u32, Vec<u8>)>, HashMap<u32, i64>)> {
    let conn = rusqlite::Connection::open_with_flags(
        db,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    let mut stmt = conn
        .prepare("SELECT tag, ring_timestamp, captured_unix, body FROM events WHERE tag IN (126, 127, 71) AND body IS NOT NULL ORDER BY captured_unix, id")
        .ok()?;
    let mut events: Vec<(u8, u32, Vec<u8>)> = Vec::new();
    let mut unix_ms: HashMap<u32, i64> = HashMap::new();
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, Vec<u8>>(3)?)))
        .ok()?;
    for row in rows.flatten() {
        let (tag, ds, cu, body) = row;
        if !TAGS.contains(&(tag as u8)) || !(0..=u32::MAX as i64).contains(&ds) {
            continue;
        }
        // an undated record has no day; a ring timestamp reused by another boot keeps its first date
        let Some(t) = clock.dated_unix_s(ds, cu) else { continue };
        unix_ms.entry(ds as u32).or_insert((t * 1000.0).round() as i64);
        events.push((tag as u8, ds as u32, body));
    }
    Some((events, unix_ms))
}

/// The activity model's step-motion input: one row per 10 s of walking-gait features, from
/// open_oura's `steps_motion_decoder`, as `(unix ms, 11 features in the model's column order)`.
/// Needs no weights.
pub fn stepmotion_rows(db: &Path, clock: &RingClock) -> Vec<(i64, [f32; 11])> {
    let Some((events, unix_ms)) = read_records(db, clock) else { return vec![] };
    let mut gait: Vec<(i64, [u16; 27])> =
        pair_real_steps(events.iter().map(|(t, d, b)| (*t, *d, b.as_slice())))
            .into_iter()
            .map(|r| (unix_ms.get(&r.timestamp).copied().unwrap_or(0), r.columns))
            .collect();
    gait.sort_by_key(|g| g.0);
    let (ts, records): (Vec<i64>, Vec<[u16; 27]>) = gait.into_iter().unzip();
    decode(&ts, &records).into_iter().map(|r| (r.timestamp, stepmotion_from_decoder(&r.features))).collect()
}

/// Steps per activity day (the date a 04:00 local day starts on) from the stored real-step and
/// motion records. `None` when the weights are not installed or the records cannot be read.
pub fn daily_steps(db: &Path, clock: &RingClock, tz: f64) -> Option<BTreeMap<String, u32>> {
    let counter = COUNTER.read().unwrap_or_else(|e| e.into_inner()).clone()?;
    let (events, unix_ms) = read_records(db, clock)?;
    let counts = count_steps(
        &counter,
        events.iter().map(|(t, d, b)| (*t, *d, b.as_slice())),
        |ds| unix_ms.get(&ds).copied().unwrap_or(0),
        None,
        &Config::default(),
    );
    let mut days: BTreeMap<String, f64> = BTreeMap::new();
    for c in counts {
        let local = c.timestamp_ms as f64 / 1000.0 + tz * 3600.0 - 4.0 * 3600.0;
        let (y, m, d) = crate::civil((local / 86_400.0).floor() as i64);
        *days.entry(format!("{y:04}-{m:02}-{d:02}")).or_default() += c.steps;
    }
    Some(days.into_iter().map(|(k, v)| (k, v.round().max(0.0) as u32)).collect())
}
