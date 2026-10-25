#!/usr/bin/env python3
"""Stage sleep with Oura's NSSA model (sleepstaging_2_6_0) — the hypnogram the
official app shows — on our stored ring data.

Each night window from the summary is staged per ring `bedtime_period` (0x76)
inside it, exactly as the Android app stages each bedtime (see
docs/algorithms/sleep-staging.md). Inputs: sleep ACM periods (0x72), IBI (0x60,
ecore-corrected), sleep temperature (0x75) and the profile demographics.

Usage: python tools/run_sleep_model.py START_DS END_DS [DB] [TZ=1] [--json]
       (no args → the most recent bedtime_period in the DB)
       --batch reads a JSON array of [start_ds, end_ds, captured_unix] from stdin and
       emits a JSON array of results (null for windows that can't be staged).
Results are cached per input fingerprint next to the DB (nssa_cache.json), so the
dashboard only stages new nights.
"""
import datetime
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

from _common import resolve_db, resolve_models_dir
from epoch_time import build_epochs, is_dated, make_unix_s
from nssa_inputs import TAG_BEDTIME, collect_nssa_inputs
from ibi_correction import correct_ibis

REPO = Path(__file__).resolve().parent.parent
TZ = 1.0
STAGE = {1: "DEEP", 2: "LIGHT", 3: "REM", 4: "WAKE"}
CACHE_VERSION = "nssa-2.6.0-r2"
EPOCH_MS = 30000

JSON = "--json" in sys.argv
BATCH = "--batch" in sys.argv
args = [a for a in sys.argv[1:] if a not in ("--json", "--batch")]
start_ds = end_ds = None
if not BATCH and len(args) >= 2 and args[0].isdigit():
    start_ds, end_ds = int(args[0]), int(args[1])
    rest = args[2:]
else:
    rest = args
db_arg = rest[0] if rest else None
if len(rest) > 1:
    TZ = float(rest[1])
DB = resolve_db(db_arg, REPO)


def read_profile(db):
    """profile.json next to the DB (same defaults as oura-summary Demographics)."""
    profile = {"sex": "M", "age": 30.0, "height_m": 1.78, "weight_kg": 75.0}
    try:
        profile.update(json.loads((Path(db).parent / "profile.json").read_text()))
    except (OSError, ValueError):
        pass
    return profile


con = sqlite3.connect(str(DB))
rows = con.execute("SELECT ring_timestamp, tag, COALESCE(decoded_json, '{}'), captured_unix, body FROM events "
                   "WHERE decoded_json IS NOT NULL OR (tag = 65 AND LENGTH(body) >= 14) "
                   "ORDER BY captured_unix, id").fetchall()
_epochs = build_epochs([r[:4] for r in rows])
_unix_s = make_unix_s(_epochs)


def ms(ds, cu=None):
    u = _unix_s(ds, cu)
    return int(round(u * 1000)) if u is not None else int(ds * 100)


def hm(ms_):
    return datetime.datetime.utcfromtimestamp(ms_ / 1000 + TZ * 3600).strftime("%H:%M")


_decoded = None


def decoded_rows():
    global _decoded
    if _decoded is None:
        _decoded = [(ds, tag, json.loads(js), cu, bytes(body) if body is not None else None)
                    for ds, tag, js, cu, body in rows if tag in (0x60, 0x72, 0x75)]
    return _decoded


def ring_bedtimes(start_ds, end_ds, captured):
    """The ring's bedtime periods inside a summary window: the latest 0x76 per start
    (the app replaces an interim result whenever the ring extends its bedtime)."""
    latest = {}
    for ds, tag, js, cu, _body in rows:
        if tag != TAG_BEDTIME:
            continue
        v = json.loads(js)
        s, e = v.get("bedtime_start_ds"), v.get("bedtime_end_ds")
        if s is None or e is None or e <= s:
            continue
        if abs(ms(s, cu) - ms(s, captured)) > 300000:  # another boot's counter
            continue
        if s < end_ds and e > start_ds:
            latest[s] = (s, e, cu)
    return sorted(latest.values())


_stager = None
_cache = None
_cache_path = Path(DB).parent / "nssa_cache.json"


def stager():
    global _stager
    if _stager is None:
        from nssa_stager import MODEL_NAME, NssaStager
        _stager = NssaStager(resolve_models_dir(REPO, MODEL_NAME) / MODEL_NAME)
    return _stager


def cache():
    global _cache
    if _cache is None:
        try:
            _cache = json.loads(_cache_path.read_text())
            if _cache.get("version") != CACHE_VERSION:
                _cache = {"version": CACHE_VERSION, "nights": {}}
        except (OSError, ValueError):
            _cache = {"version": CACHE_VERSION, "nights": {}}
    return _cache


def save_cache():
    try:
        _cache_path.write_text(json.dumps(cache()))
    except OSError:
        pass


def stage_bedtime(b_start, b_end, cu, demo):
    """NSSA epochs for one ring bedtime: (epoch start ms list, codes) or None."""
    inputs = collect_nssa_inputs(decoded_rows(), b_start, b_end, cu, ms, correct_ibis)
    key = hashlib.sha256(json.dumps([CACHE_VERSION, demo, inputs], sort_keys=True).encode()).hexdigest()
    hit = cache()["nights"].get(key)
    if hit:  # truthy check: failures are cached as {}, which must not short-circuit
        return (hit["t"], hit["s"])
    try:
        ts, codes = stager().stage(inputs, demo)
    except (ValueError, RuntimeError):
        ts, codes = None, None
    cache()["nights"][key] = {"t": ts, "s": codes} if ts else {}
    save_cache()
    return (ts, codes) if ts else None


def grid_stages(periods, failed, start_ms, end_ms):
    """Paint NSSA epochs onto the summary's 30 s grid from start_ms. A cell takes the
    epoch covering its midpoint (NSSA epochs sit on floor30(bedtime start), so they
    may be offset from start_ms by up to 29 s). Cells outside every ring bedtime
    (the summary's evidence-based extensions, or the gap of a rejoined split night)
    are WAKE, as Oura's own grid fills unstaged epochs (`nan_to_num(…, 4)`); cells of
    a ring bedtime that NSSA could not stage stay 0 (unknown)."""
    n = max(1, -(-(end_ms - start_ms) // EPOCH_MS))
    out = [4] * n
    for b_start_ms, b_end_ms in failed:
        for idx in range(n):
            mid = start_ms + idx * EPOCH_MS + EPOCH_MS // 2
            if b_start_ms <= mid < b_end_ms:
                out[idx] = 0
    for ts, codes in periods:
        for t, code in zip(ts, codes):
            # the cell whose midpoint falls inside [t, t + 30 s)
            idx = -(-(t - start_ms - EPOCH_MS // 2) // EPOCH_MS)
            if 0 <= idx < n and code in (1, 2, 3, 4):
                out[idx] = code
    return out


def score_window(start_ds, end_ds, captured_unix=None):
    """Stage one summary window. Returns (out_dict, None, None) or (err_str, ...)."""
    bed_cu = captured_unix if captured_unix is not None else next(
        (cu for ds, tag, js, cu, _b in reversed(rows) if tag == TAG_BEDTIME
         and json.loads(js).get("bedtime_start_ds") == start_ds), rows[-1][3] if rows else 0)
    if not is_dated(_epochs, start_ds, bed_cu) or not is_dated(_epochs, end_ds, bed_cu):
        return "sleep window clock is undated or ambiguous", None, None
    profile = read_profile(DB)
    from nssa_stager import demographics
    demo = demographics(profile["age"], profile["height_m"], profile["weight_kg"], profile["sex"])
    beds = ring_bedtimes(start_ds, end_ds, bed_cu)
    bedtime_source = "ring"
    if not beds:  # no ring bedtime (signal-derived night): stage the summary window
        beds, bedtime_source = [(start_ds, end_ds, bed_cu)], "summary"
    periods, failed = [], []
    for b_start, b_end, cu in beds:
        staged = stage_bedtime(b_start, b_end, bed_cu, demo)
        if staged:
            periods.append(staged)
        else:
            failed.append((ms(b_start, bed_cu), ms(b_end, bed_cu)))
    if not periods:
        return "NSSA could not stage this window (missing ACM, IBI or sleep temperature)", None, None
    start_ms, end_ms = ms(start_ds, bed_cu), ms(end_ds, bed_cu)
    stages = grid_stages(periods, failed, start_ms, end_ms)
    n = len(stages)
    known = [c for c in stages if c]
    mins = {k: stages.count(c) * 0.5 for c, k in STAGE.items()}
    asleep = sum(mins[k] for k in ("DEEP", "LIGHT", "REM"))
    main = max(periods, key=lambda p: len(p[1]))
    out = {
        "start_ds": start_ds, "end_ds": end_ds, "captured_unix": bed_cu,
        "start_local": hm(start_ms), "end_local": hm(end_ms),
        "epochs": n, "in_bed_min": n * 0.5,
        "asleep_min": asleep,
        "efficiency_pct": round(100 * asleep / (n * 0.5)) if len(known) == n else None,
        "source": "nssa",
        "bedtime_source": bedtime_source,
        "stages": stages,  # per-30s ints on the summary grid: 1=DEEP 2=LIGHT 3=REM 4=WAKE 0=unknown
        "stages_t0_unix": main[0][0] / 1000.0,
        # Oura's own epochs per ring bedtime: start ms of epoch 0 and the codes.
        "nssa_periods": [{"t0_ms": ts[0], "stages": codes} for ts, codes in periods],
        "demographics": demo,
    }
    for c, k in STAGE.items():
        out[k.lower() + "_min"] = mins[k]
        out[k.lower() + "_pct"] = round(100 * mins[k] / (n * 0.5))
    return out, None, None


if BATCH:
    pairs = json.load(sys.stdin)
    results = []
    for p in pairs:
        out, _, _ = score_window(int(p[0]), int(p[1]), int(p[2]) if len(p) > 2 else None)
        results.append(out if isinstance(out, dict) else None)
    print(json.dumps(results))
    sys.exit(0)

if start_ds is None:  # default: most recent bedtime_period in the DB
    bt = con.execute("SELECT decoded_json FROM events WHERE tag=118 ORDER BY captured_unix DESC, id DESC").fetchone()
    if bt is None:
        raise SystemExit("no bedtime_period (tag 0x76) in DB — pass start/end deciseconds or sync overnight data first")
    v = json.loads(bt[0])
    start_ds, end_ds = v["bedtime_start_ds"], v["bedtime_end_ds"]

out, _, _ = score_window(start_ds, end_ds)
if not isinstance(out, dict):
    sys.exit(out)
if JSON:
    print(json.dumps(out))
    sys.exit(0)

n = out["epochs"]
print(f"window ds [{start_ds}..{end_ds}] ({(end_ds - start_ds) / 10 / 3600:.1f}h), NSSA bedtime from {out['bedtime_source']}")
print(f"\nHypnogram: {n} epochs = {n * 0.5:.0f} min in bed")
for k in ["DEEP", "LIGHT", "REM", "WAKE"]:
    print(f"  {k:<6} {out[k.lower() + '_min']:>6.0f} min  ({out[k.lower() + '_pct']:4.0f}%)")
g = {1: "D", 2: "L", 3: "R", 4: "W", 0: "."}
stages = out["stages"]
print(f"\n  {out['start_local']} " + "".join(g[max(set(stages[i:i + 20]), key=stages[i:i + 20].count)]
                                            for i in range(0, n, 20)) + f" {out['end_local']}")
