#!/usr/bin/env python3
"""Run Oura's decrypted illness-detection ("Symptom Radar") model on our ring data.

Feeds the on-device PyTorch model the 23 raw inputs it expects (30-day biometric
series + long-term baselines + demographics) and emits its calibrated illness score,
decision, and per-biomarker ELEVATED/DECREASED contributions. Full I/O contract:
`docs/algorithms/illness-detection.md`. The model bakes in all normalization,
calibration and thresholds — we pass raw physiological values.

Usage: python tools/run_illness_model.py [DB] [TZ] [--json]
       --profile PATH   user demographics json (age, sex, height_m, weight_kg)
"""
import json
import sqlite3
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from epoch_time import build_epochs, make_unix_s
from respiratory_rate import respiratory_rate

REPO = Path(__file__).resolve().parent.parent
MODEL = str((REPO / "notes/models/illness_detection_0_5_1.pt"))
if not Path(MODEL).exists():
    MODEL = str(REPO.parent / "open_oura/notes/models/illness_detection_0_5_1.pt")

N_DAYS = 30
IBI_TAGS = {0x44, 0x60, 0x71}
TEMP_TAGS = {0x46, 0x69, 0x75}
DAY = 86400.0

# decision -> (risk level, traffic light) — see illness-detection.md §4
DECISION = {0: ("BelowThreshold", "NO_SIGNS"), 1: ("Low", "MINOR_SIGNS"),
            2: ("Moderate", "MAJOR_SIGNS")}
# output tuple: 0=score 1=decision then 7 biomarkers (2..8):
#   2 avg_breath, 3 avg_hr, 4 lowest_hr, 5 avg_hrv, 6 temp_dev, 7 sedentary, 8 resting
# the 4 surfaced as symptom cards (output index -> label):
SHOWN_BIOMARKERS = {2: "AverageBreath", 4: "LowestHeartRate",
                    5: "AverageHrv", 6: "TemperatureDeviation"}


def civil(days):
    z = days + 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    return (y + (1 if m <= 2 else 0), m, d)


def load(db):
    con = sqlite3.connect(str(db))
    rows = con.execute(
        "SELECT ring_timestamp, tag, decoded_json, captured_unix FROM events "
        "WHERE decoded_json IS NOT NULL ORDER BY captured_unix, id"
    ).fetchall()
    con.close()
    return rows


def bed_windows(rows, unix_s):
    """(wake_day_index, start_unix, end_unix) per sleep period from bedtime events."""
    out = []
    for ds, tag, dj, cu in rows:
        if tag != 0x76:
            continue
        d = json.loads(dj)
        s = d.get("bedtime_start_ds")
        e = d.get("bedtime_end_ds")
        if s is None or e is None or e <= s:
            continue
        out.append((unix_s(s, cu), unix_s(e, cu)))
    return out


def nightly_biometrics(rows, unix_s, tz, windows):
    """Per wake-day: avg_breath, avg_hr, lowest_hr, avg_hrv (RMSSD), skin_temp,
    keyed by local calendar day index. Longest sleep per day wins.

    HR/HRV come from the ring's own `hrv_event` (5-min rmssd_ms + hr_bpm) — the same
    source the shared summary uses — which is far cleaner than IBI-derived RMSSD.
    Breathing rate needs the raw IBI (respiratory sinus arrhythmia)."""
    ibi_t, ibi_v = [], []
    hrv_t, hrv_rmssd, hrv_hr = [], [], []
    temp_t, temp_v = [], []
    for ds, tag, dj, cu in rows:
        if tag in IBI_TAGS:
            d = json.loads(dj)
            base = unix_s(ds, cu)
            acc = 0.0
            for v in (d.get("ibi_ms") or []):
                if v:
                    acc += v / 1000.0
                    ibi_t.append(base + acc)
                    ibi_v.append(v)
        elif tag == 0x5D:  # hrv_event: 5-min avg RMSSD + HR
            d = json.loads(dj)
            base = unix_s(ds, cu)
            step = float(d.get("interval_min", 5)) * 60.0
            rm = d.get("rmssd_ms") or []
            hb = d.get("hr_bpm") or []
            for i, r in enumerate(rm):
                if r and r > 0:
                    hrv_t.append(base + i * step)
                    hrv_rmssd.append(float(r))
                    hrv_hr.append(float(hb[i]) if i < len(hb) else float("nan"))
        elif tag in TEMP_TAGS:
            d = json.loads(dj)
            base = unix_s(ds, cu)
            for tv in (d.get("temps_c") or []):
                if tv and tv > 20:  # skin temp; drop obvious off-finger lows
                    temp_t.append(base)
                    temp_v.append(tv)
    ibi_t, ibi_v = np.array(ibi_t), np.array(ibi_v, float)
    hrv_t = np.array(hrv_t); hrv_rmssd = np.array(hrv_rmssd); hrv_hr = np.array(hrv_hr)
    temp_t, temp_v = np.array(temp_t), np.array(temp_v, float)

    per_day = {}
    for start, end in windows:
        dur = end - start
        if dur < 3600:  # ignore naps <1h for the nightly biometrics
            continue
        wake_day = int((end + tz * 3600) // DAY)
        hm = (hrv_t >= start) & (hrv_t <= end)
        if hm.sum() < 3:
            continue
        rmssd = float(np.median(hrv_rmssd[hm]))
        hr_win = hrv_hr[hm]
        hr_win = hr_win[np.isfinite(hr_win)]
        if len(hr_win) < 3:
            continue
        avg_hr = float(np.median(hr_win))
        lowest = float(np.min(hr_win))  # lowest 5-min-averaged HR
        im = (ibi_t >= start) & (ibi_t <= end)
        breath, _var, _n = respiratory_rate(ibi_t[im], ibi_v[im]) if im.sum() > 200 \
            else (float("nan"), float("nan"), 0)
        tm = (temp_t >= start) & (temp_t <= end)
        skin = float(np.median(temp_v[tm])) if tm.any() else float("nan")
        row = dict(avg_breath=breath, avg_hr=avg_hr, lowest_hr=lowest,
                   avg_hrv=rmssd, skin_temp=skin, dur=dur)
        if wake_day not in per_day or dur > per_day[wake_day]["dur"]:
            per_day[wake_day] = row
    return per_day


def activity_by_day(rows, unix_s, tz):
    """Per local calendar day: (sedentary_seconds, resting_seconds) from MET minutes.
    resting: MET < 1.05 (lying); sedentary: 1.05 <= MET < 2.0 (sitting/inactive)."""
    sed, rest = {}, {}
    for ds, tag, dj, cu in rows:
        d = json.loads(dj) if '"met"' in dj else None
        if not d or "met" not in d:
            continue
        base = unix_s(ds, cu)
        for i, mv in enumerate(d["met"] or []):
            mv = float(mv)
            day = int((base + i * 60.0 + tz * 3600) // DAY)
            if mv < 1.05:
                rest[day] = rest.get(day, 0) + 60
            elif mv < 2.0:
                sed[day] = sed.get(day, 0) + 60
    return sed, rest


def series(per_day, sed, rest, anchor):
    """Build 30-day [30,1] columns, index 0 = anchor (today), 29 = oldest. NaN missing."""
    def col(fn):
        return np.array([[fn(anchor - i)] for i in range(N_DAYS)], dtype=np.float32)
    nan = float("nan")
    g = lambda day, k: per_day.get(day, {}).get(k, nan)
    breath = col(lambda d: g(d, "avg_breath"))
    avg_hr = col(lambda d: g(d, "avg_hr"))
    low_hr = col(lambda d: g(d, "lowest_hr"))
    hrv = col(lambda d: g(d, "avg_hrv"))
    skin = np.array([g(anchor - i, "skin_temp") for i in range(N_DAYS)], float)
    # nightly temp deviation vs personal baseline (median of available skin temps)
    base_temp = np.nanmedian(skin) if np.isfinite(skin).any() else nan
    temp_dev = (skin - base_temp).reshape(N_DAYS, 1).astype(np.float32)
    sed_c = col(lambda d: float(sed.get(d, nan)))
    rest_c = col(lambda d: float(rest.get(d, nan)))
    return breath, avg_hr, low_hr, hrv, temp_dev, sed_c, rest_c, skin, base_temp


def nz(a):
    """finite values of a flattened array."""
    a = np.asarray(a, float).ravel()
    return a[np.isfinite(a)]


def run(db, tz, profile):
    rows = load(db)
    if not rows:
        return {"available": False, "status": "NO_DATA"}
    epochs = build_epochs(rows)
    unix_s = make_unix_s(epochs)

    windows = bed_windows(rows, unix_s)
    per_day = nightly_biometrics(rows, unix_s, tz, windows)
    if not per_day:
        return {"available": False, "status": "MISSING_SLEEP_DATA"}
    sed, rest = activity_by_day(rows, unix_s, tz)
    anchor = max(per_day)  # latest wake day = "today" (index 0)

    (breath, avg_hr, low_hr, hrv, temp_dev, sed_c, rest_c,
     skin, base_temp) = series(per_day, sed, rest, anchor)

    # 302 guard: at most 7 of last 14 nights' temp deviation may be missing
    if not np.isfinite(temp_dev[0, 0]):
        return {"available": False, "status": "MISSING_LAST_NIGHT_SLEEP"}
    if int(np.isnan(temp_dev[:14, 0]).sum()) > 7:
        return {"available": False, "status": "MISSING_SLEEP_DATA"}

    # long-term scalar baselines (avg + std over available history)
    def scal(v):
        return torch.tensor([[float(v)]], dtype=torch.float32)
    rhr, hrvb, tvals, sedvals = nz(low_hr), nz(hrv), nz(skin), nz(sed_c)
    b_rhr_avg = np.mean(rhr) if len(rhr) else 55.0
    b_rhr_dev = np.std(rhr) if len(rhr) > 1 else 3.0
    b_hrv_avg = np.mean(hrvb) if len(hrvb) else 45.0
    b_hrv_dev = np.std(hrvb) if len(hrvb) > 1 else 6.0
    b_tmp_avg = base_temp if np.isfinite(base_temp) else 36.0
    b_tmp_dev = np.std(tvals) if len(tvals) > 1 else 0.2
    b_sed_avg = np.mean(sedvals) if len(sedvals) else 30000.0
    b_sed_dev = np.std(sedvals) if len(sedvals) > 1 else 4000.0

    prof = json.loads(Path(profile).read_text()) if profile and Path(profile).exists() else {}
    age = float(prof.get("age", 30))
    h = float(prof.get("height_m", 1.78))
    w = float(prof.get("weight_kg", 75))
    bmi = w / (h * h)
    sex = {"F": -1.0, "M": 1.0}.get(str(prof.get("sex", "M")).upper(), 0.0)
    y, mo, dd = civil(anchor)
    from datetime import date
    dow = float(date(y, mo, dd).weekday())  # Mon=0

    nanc = torch.full((N_DAYS, 1), float("nan"))
    t = lambda a: torch.from_numpy(a)
    out = torch.jit.load(MODEL, map_location="cpu").eval()(
        t(breath), t(avg_hr), t(low_hr), t(hrv), t(temp_dev), t(sed_c), t(rest_c),
        nanc, nanc, scal(float("nan")), scal(float("nan")),
        scal(age), scal(bmi), scal(sex), scal(dow),
        scal(b_rhr_avg), scal(b_rhr_dev), scal(b_hrv_avg), scal(b_hrv_dev),
        scal(b_tmp_avg), scal(b_tmp_dev), scal(b_sed_avg), scal(b_sed_dev),
    )
    score = float(out[0]); decision = int(round(float(out[1])))
    risk, light = DECISION.get(decision, ("BelowThreshold", "NO_SIGNS"))

    biomarkers = []
    for idx, label in SHOWN_BIOMARKERS.items():
        v = out[idx].flatten().tolist()
        if any(not np.isfinite(x) for x in v):
            continue
        is_out, value, lo, hi = round(v[0]) == 1, v[1], v[2], v[3]
        biomarkers.append({
            "type": label, "value": round(value, 2),
            "lower": round(lo, 2), "upper": round(hi, 2),
            "indicatesSymptoms": is_out,
            "reason": ("ELEVATED" if value > hi else "DECREASED") if is_out else None,
        })

    y0, m0, d0 = civil(anchor)
    return {
        "available": True,
        "date": f"{y0:04d}-{m0:02d}-{d0:02d}",
        "score": round(score, 4),
        "decision": decision,
        "risk_level": risk,
        "traffic_light": light,
        "biomarkers": biomarkers,
        "breath_today": None if not np.isfinite(breath[0, 0]) else round(float(breath[0, 0]), 1),
        "status": {"NO_SIGNS": "NO_SIGNS", "MINOR_SIGNS": "MINOR_SIGNS",
                   "MAJOR_SIGNS": "MAJOR_SIGNS"}[light],
        "days_with_data": int(np.isfinite(temp_dev[:, 0]).sum()),
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    profile = None
    if "--profile" in sys.argv:
        profile = sys.argv[sys.argv.index("--profile") + 1]
    db = args[0] if args else str(REPO / "oura.db")
    tz = int(args[1]) if len(args) > 1 else 0
    if profile is None:
        pj = Path(db).resolve().parent / "profile.json"
        profile = str(pj) if pj.exists() else None
    result = run(db, tz, profile)
    print(json.dumps(result, indent=None if "--json" in sys.argv else 2))


if __name__ == "__main__":
    main()
