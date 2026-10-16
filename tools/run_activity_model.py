#!/usr/bin/env python3
"""Run the activity detection model on one local day at a time.

The official Android app evaluates one local calendar day at a time and feeds
the 12-column step-motion series produced by steps_motion_decoder. Those details
are essential: omitting or misordering gait can turn a hike into cycling.
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys
import warnings
from pathlib import Path

import torch

from _common import clock_events_relation, resolve_db, resolve_models_dir
from activity_features import decoder_to_aad, unpack_real_step
from epoch_time import build_epochs, is_dated, make_unix_s

warnings.filterwarnings("ignore", message=".*searchsorted.*")

REPO = Path(__file__).resolve().parent.parent
MODEL_NAME = "automatic_activity_detection_3_1_15.pt"
MODEL = resolve_models_dir(REPO, MODEL_NAME) / MODEL_NAME
STEP_MODEL = MODEL.parent / "steps_motion_decoder_2_0_0.pt"
MODEL_VERSION = "3.1.15"

BEHAVIOR = {
    -1: "nothing", 0: "<empty>", 1: "badminton", 2: "boxing", 3: "crossCountrySkiing",
    4: "crossTraining", 5: "cycling", 6: "dance", 7: "elliptical", 8: "strengthTraining",
    9: "hockey", 10: "pilates", 11: "rowing", 12: "running", 13: "swimming", 14: "walking",
    15: "yoga", 16: "golf", 17: "tennis", 18: "climbing", 19: "downhillSkiing",
    20: "snowboarding", 21: "hiking", 22: "horsebackRiding", 23: "volleyball", 24: "basketball",
    25: "americanFootball", 26: "soccer", 27: "baseball", 28: "coreExercise", 29: "cricket",
    30: "HIIT", 31: "diving", 32: "fitnessClass", 33: "floorball", 34: "gymnastics",
    35: "handball", 36: "houseWork", 37: "iceSkating", 38: "jumpingRope", 39: "martialArts",
    40: "flexibility", 41: "mountainBiking", 42: "nordicWalking", 48: "stairExercise",
    49: "stretching", 50: "surfing", 51: "waterFitness", 52: "yardwork", 53: "padel",
    69: "skateboarding", 65535: "other", 65536: "nap", 65537: "sleep", 65538: "pause",
    70937: "meditation", 71201: "eating", 71227: "relax", 71239: "transport",
}


def parse_args():
    parser = argparse.ArgumentParser(description="Label activities with Oura's AAD model.")
    parser.add_argument("db", nargs="?", default=None)
    parser.add_argument("--tz", type=float, default=1.0, help="Fixed UTC offset in hours (default 1)")
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--min-duration", type=float, default=10.0,
                        help="Minimum segment minutes; Android default is 10")
    parser.add_argument("--date", help="Only process one local day (YYYY-MM-DD)")
    parser.add_argument("--no-stepmotion", action="store_true", help="Diagnostic fallback without gait")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args, extra = parser.parse_known_args()
    if extra:
        try:
            args.tz = float(extra[0])
        except (ValueError, IndexError):
            pass
    if args.db is not None and not Path(args.db).exists():
        try:
            args.tz = float(args.db)
            args.db = None
        except ValueError:
            pass
    # Retain the old debugging switch, but real gait is now the safe default.
    if os.environ.get("STEPMOTION") == "0":
        args.no_stepmotion = True
    return args


def tensor(rows, columns, window=None):
    """Rows as float32; `window=(lo, hi)` is the MET span of the day.

    A series with no sample inside that span is dropped entirely by the model's
    valid-time clipping, after which it indexes the empty tensor and throws. A NaN
    placeholder at the first MET minute keeps the channel present (it is treated as
    missing data). Mirror of ActivityModel.matrix on iOS.
    """
    if window is not None:
        lo, hi = window
        if not any(lo <= row[0] <= hi for row in rows):
            rows = sorted(rows + [[lo] + [float("nan")] * (columns - 1)], key=lambda row: row[0])
    if rows:
        return torch.tensor(rows, dtype=torch.float32)
    return torch.empty((0, columns), dtype=torch.float32)


NON_WEAR_MET_THRESHOLD = 0.2
MIN_VALID_METS = 10
ACCEPTABLE_LAST_HR_MISSING_MINUTES = 5


def model_would_reject(met, motion, temperature, heart_rate, step_rows):
    """Mirror of the model's last-valid-time preprocessing step.

    With fewer than MIN_VALID_METS worn MET minutes before the last motion sample the
    valid window collapses to minute 0 and the graph indexes an empty MET tensor.
    Such a day has no evaluable data: skip it instead of catching the exception.
    Kept identical to ActivityModel.isDegenerate on iOS.
    """
    import math
    last = lambda rows: rows[-1][0] if rows else 0.0
    last_motion = math.ceil(last(motion))
    worn = [row[0] for row in met if row[1] > NON_WEAR_MET_THRESHOLD and row[0] <= last_motion]
    if len(worn) < MIN_VALID_METS:
        return met[0][0] > 0
    last_valid = min(worn[-1], last_motion, math.ceil(last(heart_rate)) + ACCEPTABLE_LAST_HR_MISSING_MINUTES,
                     math.ceil(last(step_rows)), math.ceil(last(temperature)))
    return met[0][0] > last_valid


STEP_MODEL_MOBILE = MODEL.parent / "mobile" / "steps_motion_decoder_2_0_0.ptl"


def load_step_decoder():
    """The gait decoder: the full TorchScript when installed, else the mobile export
    (same weights, lite-interpreter bytecode) that ships in the iOS app. Without it
    the model runs on MET/motion alone and finds far fewer sessions than the app."""
    if STEP_MODEL.exists():
        return torch.jit.load(str(STEP_MODEL), map_location="cpu").eval()
    if STEP_MODEL_MOBILE.exists():
        from torch.jit.mobile import _load_for_lite_interpreter
        return _load_for_lite_interpreter(str(STEP_MODEL_MOBILE))
    return None


def decode_stepmotion(db, unix_seconds, enabled, epochs):
    if not enabled:
        return []
    decoder = load_step_decoder()
    if decoder is None:
        print(f"warning: step decoder not found ({STEP_MODEL} or {STEP_MODEL_MOBILE}); "
              "running without gait features, expect fewer and differently labelled sessions",
              file=sys.stderr)
        return []
    packets = db.execute(
        "SELECT ring_timestamp, tag, body, captured_unix FROM events "
        "WHERE tag IN (126,127) AND body IS NOT NULL ORDER BY captured_unix,id"
    ).fetchall()
    seconds = {}
    for ds, tag, body, captured in packets:
        if tag == 0x7F and len(body) == 14 and is_dated(epochs, ds, captured):
            wall_ds = round(unix_seconds(ds, captured) * 10)
            seconds[wall_ds] = body
    raw, timestamps = [], []
    for ds, tag, body, captured in packets:
        if tag != 0x7E or len(body) != 14 or not is_dated(epochs, ds, captured):
            continue
        wall_ds = round(unix_seconds(ds, captured) * 10)
        second = seconds.get(wall_ds + 1)
        if second is None:
            continue
        raw.append(unpack_real_step(body, second))
        timestamps.append(wall_ds * 100)
    if not raw:
        return []
    # The decoder windows consecutive packets: feed them in time order (the DB is in
    # capture order, which interleaves boots after a re-anchor), as the iOS app does.
    order = sorted(range(len(raw)), key=lambda i: timestamps[i])
    raw, timestamps = [raw[i] for i in order], [timestamps[i] for i in order]
    with torch.no_grad():
        out_ts, out_data = decoder(torch.tensor(timestamps, dtype=torch.int64),
                                   torch.tensor(raw, dtype=torch.float32))
    # Keep all three 10-second sub-windows, as Android's TimeseriesDbStepMotion does.
    return sorted((ts / 60_000.0, decoder_to_aad(values))
                  for ts, values in zip(out_ts.flatten().tolist(), out_data.tolist()))


def run_day(model, day, day_start_min, signals, steps, args):
    day_end_min = day_start_min + 24 * 60

    def select(name):
        return sorted(([t - day_start_min] + values for t, values in signals[name]
                       if day_start_min <= t < day_end_min), key=lambda row: row[0])

    # The ring may resend a MET minute; Android's Realm series has one value per timestamp.
    met_by_minute = {round(row[0]): row for row in select("met")}
    met = sorted(met_by_minute.values(), key=lambda row: row[0])
    if not met:
        return []
    motion, temperature, heart_rate = select("motion"), select("temperature"), select("heart_rate")
    step_rows = [[t - day_start_min] + values for t, values in steps
                 if day_start_min <= t < day_end_min]
    if model_would_reject(met, motion, temperature, heart_rate, step_rows):
        return []
    lo, hi = met[0][0], met[-1][0]
    step_rows = [[lo] + [float("nan")] * 11] + step_rows + [[hi] + [float("nan")] * 11]

    context = torch.tensor([day.year, day.month, day.day, day.weekday()], dtype=torch.float32)
    user = torch.tensor(args.user_vector + [float("nan")] * 10, dtype=torch.float32)
    with torch.no_grad():
        workouts, _, _ = model(
            context, user, tensor(met, 2), tensor(step_rows, 12), tensor(motion, 9, (lo, hi)),
            tensor(temperature, 2, (lo, hi)), tensor(heart_rate, 2, (lo, hi)), None, None,
            torch.tensor(args.threshold), torch.tensor(args.min_duration), torch.tensor(0.0),
        )

    sessions = []
    local_midnight = datetime.datetime.combine(day, datetime.time())
    for row in workouts.tolist():
        start = local_midnight + datetime.timedelta(minutes=row[0])
        end = local_midnight + datetime.timedelta(minutes=row[1])
        top = [(BEHAVIOR.get(int(row[3 + 2 * i]), str(int(row[3 + 2 * i]))),
                round(row[4 + 2 * i], 3)) for i in range(3)]
        sessions.append({
            "start": start.strftime("%Y-%m-%d %H:%M"), "end": end.strftime("%H:%M"),
            "duration_min": round(row[1] - row[0]), "is_workout": round(row[2], 3),
            "label": top[0][0], "label_confidence": top[0][1], "top3": top,
        })
    return sessions


def main():
    args = parse_args()
    db_path = resolve_db(args.db, REPO)
    if not MODEL.exists():
        sys.exit(f"error: model not found: {MODEL}")
    db = sqlite3.connect(str(db_path))
    rows = db.execute(
        "SELECT ring_timestamp,tag,decoded_json,captured_unix FROM " + clock_events_relation(db) + " "
        "WHERE decoded_json IS NOT NULL ORDER BY captured_unix,id"
    ).fetchall()
    if not rows:
        sys.exit(f"error: no decoded events in {db_path}")
    epochs = build_epochs(rows)
    unix_seconds = make_unix_s(epochs)
    signals = {name: [] for name in ("met", "motion", "temperature", "heart_rate")}
    scale = float(os.environ.get("ACM_SCALE", "1"))
    for ds, tag, payload, captured in rows:
        try:
            value = json.loads(payload)
        except Exception:
            continue
        # Undated data (an untrustworthy boot clock) belongs to no calendar day.
        if not is_dated(epochs, ds, captured):
            continue
        # Ring summaries are minute buckets. Epoch reconstruction can leave them a
        # few seconds off the boundary; Android stores the bucket timestamp itself.
        minute = round(unix_seconds(ds, captured) / 60)
        if tag == 0x50 and isinstance(value.get("met"), list):
            signals["met"].extend((minute + i, [float(v)]) for i, v in enumerate(value["met"]))
        elif tag == 0x47:
            signals["motion"].append((minute, [
                float(value.get("orientation", 0)), float(value.get("motion_seconds", 0)),
                float(value.get("avg_x", 0)) * scale, float(value.get("avg_y", 0)) * scale,
                float(value.get("avg_z", 0)) * scale, float("nan"),
                float(value.get("low_intensity", 0)), float(value.get("high_intensity", 0)),
            ]))
        elif tag == 0x46 and value.get("temps_c"):
            signals["temperature"].append((minute, [float(value["temps_c"][0])]))
        elif tag == 0x80 and value.get("hr_bpm"):
            bpm = value["hr_bpm"]
            signals["heart_rate"].append((minute, [sum(bpm) / len(bpm)]))
    if not signals["met"]:
        sys.exit("no MET events in DB — cannot run activity model")

    steps = decode_stepmotion(db, unix_seconds, not args.no_stepmotion, epochs)
    # Demographics from profile.json next to the DB (what the iOS app and the CVA
    # runner use); the model takes [age, sex(M=1), height_m, weight_kg].
    profile = {}
    try:
        profile = json.loads((Path(db_path).parent / "profile.json").read_text())
    except Exception:
        pass
    args.user_vector = [float(profile.get("age") or 30), 1.0 if str(profile.get("sex", "M")).upper() == "M" else 0.0,
                        float(profile.get("height_m") or 1.78), float(profile.get("weight_kg") or 75)]
    offset_minutes = args.tz * 60
    dates = sorted({datetime.datetime.utcfromtimestamp(t * 60 + args.tz * 3600).date()
                    for t, _ in signals["met"]})
    if args.date:
        dates = [datetime.date.fromisoformat(args.date)]
    model = torch.jit.load(str(MODEL), map_location="cpu").eval()
    sessions = []
    for day in dates:
        utc_midnight = datetime.datetime.combine(day, datetime.time()) - datetime.timedelta(minutes=offset_minutes)
        day_start_min = utc_midnight.replace(tzinfo=datetime.timezone.utc).timestamp() / 60
        try:
            sessions.extend(run_day(model, day, day_start_min, signals, steps, args))
        except (torch.jit.Error, RuntimeError) as error:
            if args.verbose:
                print(f"{day}: model rejected incomplete day ({error})", file=sys.stderr)
    result = {"model": MODEL_VERSION, "pipeline": "android-parity", "sessions": sessions}
    if args.json:
        print(json.dumps(result, indent=2))
        return
    print(f"Activity sessions — Oura AAD v{MODEL_VERSION}, Android-parity inputs\n")
    if not sessions:
        print("  No activity segments detected.")
        return
    print(f"  {'date':<10} {'time':<13} {'dur':>4}  {'workout':>7}  activity (model confidence)")
    for session in sessions:
        date, start = session["start"].split(" ")
        alternatives = "   ".join(f"{name} {prob:.2f}" for name, prob in session["top3"][1:])
        mark = "✓" if session["is_workout"] >= args.threshold else " "
        print(f"  {date:<10} {start}-{session['end']:<8} {session['duration_min']:>3}m  "
              f"{session['is_workout']:.2f} {mark}  {session['label']} "
              f"{session['label_confidence']:.2f}   ·   {alternatives}")


if __name__ == "__main__":
    main()
