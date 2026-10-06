"""Pure SleepNet input/output checks shared with the iOS implementation."""


def aligned_stages(timestamps_ms, stages, start_ms, end_ms):
    """Place 30-second model epochs on the bedtime grid; uncovered cells are 0."""
    if len(timestamps_ms) != len(stages) or end_ms <= start_ms:
        raise ValueError("invalid sleep output/window")
    if any(b <= a for a, b in zip(timestamps_ms, timestamps_ms[1:])):
        raise ValueError("sleep output timestamps must increase")
    if any(code not in (1, 2, 3, 4) for code in stages):
        raise ValueError("invalid sleep stage code")
    # SleepNet stamps each epoch with its END time: the first output is start+30 s and
    # the last lands on (or just past) the bedtime end. Epoch k covers (t-30 s, t], so
    # a window that is not a whole number of epochs keeps its final partial epoch.
    result = [0] * max(1, -(-(end_ms - start_ms) // 30000))
    for timestamp, code in zip(timestamps_ms, stages):
        if timestamp <= start_ms:
            continue
        index = int((timestamp - start_ms - 1) // 30000)
        if index < len(result):
            result[index] = code
    return result


def collect_inputs(rows, start_ds, end_ds, captured_unix, unix_ms):
    """Reject events from overlapping relative-counter ranges in other boots."""
    start_ms, end_ms = unix_ms(start_ds, captured_unix), unix_ms(end_ds, captured_unix)
    beats_60, beats_80, hrv_rows = [], [], []
    motion, temp_46, temp_75 = [], [], []
    for ds, tag, value, captured in rows:
        if not start_ds - 6000 <= ds <= end_ds + 6000:
            continue
        timestamp = unix_ms(ds, captured)
        if not start_ms - 600000 <= timestamp <= end_ms + 600000:
            continue
        if abs(timestamp - (start_ms + (ds - start_ds) * 100)) > 300000:
            continue
        if tag == 0x60:
            amplitude = value.get("amplitude", [])
            ibis = value.get("ibi_ms", [])
            elapsed = 0
            for i, ibi in enumerate(ibis):
                if ibi <= 0:
                    continue
                elapsed += ibi
                amp = float(amplitude[i]) if i < len(amplitude) else 0.0
                tail_noise = (len(ibis) >= 4 and i >= len(ibis) - 2 and ibi < 600 and amp <= 0)
                valid = (300 <= ibi <= 2000) and not tail_noise
                beats_60.append((timestamp + elapsed, float(ibi), amp, float(valid)))
        elif tag == 0x80:
            amplitude = value.get("amplitude", [])
            quality = value.get("quality", [])
            elapsed = 0
            for i, ibi in enumerate(value.get("ibi_ms", [])):
                if ibi <= 0:
                    continue
                elapsed += ibi
                valid = 300 <= ibi <= 2000 and (i < len(quality) and quality[i] == 1)
                beats_80.append((timestamp + elapsed, float(ibi),
                                 float(amplitude[i]) if i < len(amplitude) else 0.0, float(valid)))
        elif tag == 0x5D:
            hrv_rows.append((timestamp, value))
        elif tag == 0x47 and value.get("motion_seconds") is not None:
            motion.append((timestamp, float(value["motion_seconds"])))
        elif tag == 0x75 and value.get("temps_c"):
            vals = [float(x) for x in value["temps_c"] if x and float(x) > 0]
            if vals:
                temp_75.append((timestamp, sum(vals) / len(vals)))
        elif tag == 0x46 and value.get("temps_c"):
            temp_46.append((timestamp, float(value["temps_c"][0])))

    if beats_60 and beats_80:
        beats_60.sort()
        ts_60 = [b[0] for b in beats_60]
        amps_60 = sorted(b[2] for b in beats_60 if b[2] > 0)
        med_amp = amps_60[len(amps_60) // 2] if amps_60 else 1200.0
        import bisect
        merged = list(beats_60)
        for ts, ibi, amp, valid in beats_80:
            idx = bisect.bisect_left(ts_60, ts)
            near = False
            if idx < len(ts_60) and abs(ts_60[idx] - ts) <= 15000:
                near = True
            if idx > 0 and abs(ts_60[idx - 1] - ts) <= 15000:
                near = True
            if not near:
                merged.append((ts, ibi, amp if amp > 0 else med_amp, valid))
        beats = merged
    elif beats_60:
        beats = beats_60
    else:
        beats = beats_80

    if not any(b[3] == 1.0 for b in beats) and hrv_rows:
        synth = []
        for ts0, value in sorted(hrv_rows):
            step_ms = max(1, int(value.get("interval_min", 5) or 5)) * 60000
            hrs = value.get("hr_bpm", []) or []
            rmssds = value.get("rmssd_ms", []) or []
            for i, hr in enumerate(hrs):
                if not hr or float(hr) <= 0:
                    continue
                mean_ibi = max(350.0, min(1800.0, 60000.0 / float(hr)))
                rmssd = float(rmssds[i]) if i < len(rmssds) and rmssds[i] else 30.0
                jitter = max(4.0, min(60.0, rmssd * 0.5))
                slot_start = ts0 + i * step_ms
                t_cur = float(slot_start)
                k = 0
                while t_cur < slot_start + step_ms:
                    sign = 1.0 if (k % 2 == 0) else -1.0
                    ibi = max(330.0, min(1950.0, round(mean_ibi + sign * jitter * 0.5)))
                    t_cur += ibi
                    synth.append((int(t_cur), ibi, 1200.0, 1.0))
                    k += 1
        beats = synth

    temp = temp_75 if temp_75 else temp_46
    return sorted(beats), sorted(motion), sorted(temp)


def refine_deep_stages(stages, hr_t, hrv_t, motion_t, start_ds, end_ds):
    """Recover N3 deep sleep (code 1) when Oura Gen 4 0x80 missing PPG amplitude
    causes SleepNet to collapse all NREM sleep into Light sleep (code 2)."""
    n = len(stages)
    if n < 20 or end_ds <= start_ds or 1 in stages:
        return list(stages)
    hrs = sorted(v for _, v in hr_t if 30.0 < v < 140.0)
    if len(hrs) < 8:
        return list(stages)

    def pct(arr, q):
        if not arr:
            return None
        pos = max(0.0, min(1.0, q)) * (len(arr) - 1)
        lo = int(pos)
        hi = min(lo + 1, len(arr) - 1)
        return arr[lo] * (1.0 - (pos - lo)) + arr[hi] * (pos - lo)

    hr_p35 = pct(hrs, 0.35)
    hr_p50 = pct(hrs, 0.50)
    hrvs = sorted(v for _, v in hrv_t if v > 0.0)
    hrv_p45 = pct(hrvs, 0.45) if hrvs else 0.0
    span_ds = float(end_ds - start_ds)

    cand = [False] * n
    for idx, code in enumerate(stages):
        if code != 2:
            continue
        e_start = start_ds + idx * 300
        e_end = e_start + 300
        e_mid = e_start + 150
        frac = (e_mid - start_ds) / span_ds
        if frac > 0.82:
            continue
        mot = [v for ds, v in motion_t if e_start - 300 <= ds <= e_end + 300]
        if (sum(mot) / len(mot) if mot else 0.0) > 2.5:
            continue
        near_hr = [v for ds, v in hr_t if abs(ds - e_mid) <= 3600 and 30.0 < v < 140.0]
        if not near_hr:
            continue
        local_hr = sum(near_hr) / len(near_hr)
        near_hrv = [v for ds, v in hrv_t if abs(ds - e_mid) <= 3600 and v > 0.0]
        local_hrv = sum(near_hrv) / len(near_hrv) if near_hrv else hrv_p45
        first_two_thirds = frac <= 0.68
        hr_limit = (hr_p35 + 0.6) if first_two_thirds else (hr_p35 - 0.3)
        very_low_hr = local_hr <= (hr_p35 - 0.8)
        calm_autonomic = local_hr <= hr_limit and (not hrvs or local_hrv >= hrv_p45 * 0.88 or very_low_hr)
        early_nrem_dip = frac <= 0.55 and local_hr <= hr_p50 and (not mot or max(mot) <= 1.0) and (not hrvs or local_hrv >= hrv_p45)
        cand[idx] = calm_autonomic or early_nrem_dip

    smoothed = list(cand)
    for i in range(n):
        if stages[i] != 2:
            smoothed[i] = False
            continue
        lo, hi = max(0, i - 3), min(n, i + 4)
        votes = sum(1 for x in cand[lo:hi] if x)
        smoothed[i] = votes * 2 >= (hi - lo)

    out = list(stages)
    i = 0
    while i < n:
        if not smoothed[i]:
            i += 1
            continue
        j = i
        while j < n and smoothed[j]:
            j += 1
        if j - i >= 6:
            for k in range(i, j):
                if out[k] == 2:
                    out[k] = 1
        i = j

    max_deep = max(1, int(n * 0.24))
    deep_indices = [idx for idx, c in enumerate(out) if c == 1]
    if len(deep_indices) > max_deep:
        for idx in deep_indices[max_deep:]:
            out[idx] = 2
    return out

