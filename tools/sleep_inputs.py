"""Pure SleepNet input/output checks shared with the iOS implementation."""


def aligned_stages(timestamps_ms, stages, start_ms, end_ms):
    """Place 30-second model epochs on the bedtime grid; uncovered cells are 0."""
    if len(timestamps_ms) != len(stages) or end_ms <= start_ms:
        raise ValueError("invalid sleep output/window")
    if any(b <= a for a, b in zip(timestamps_ms, timestamps_ms[1:])):
        raise ValueError("sleep output timestamps must increase")
    if any(code not in (1, 2, 3, 4) for code in stages):
        raise ValueError("invalid sleep stage code")
    result = [0] * max(1, (end_ms - start_ms) // 30000)
    for timestamp, code in zip(timestamps_ms, stages):
        index = (timestamp - start_ms) // 30000
        if 0 <= index < len(result):
            result[index] = code
    return result


def collect_inputs(rows, start_ds, end_ds, captured_unix, unix_ms):
    """Reject events from overlapping relative-counter ranges in other boots."""
    start_ms, end_ms = unix_ms(start_ds, captured_unix), unix_ms(end_ds, captured_unix)
    beats, motion, temp = [], [], []
    for ds, tag, value, captured in rows:
        if not start_ds - 6000 <= ds <= end_ds + 6000:
            continue
        timestamp = unix_ms(ds, captured)
        if not start_ms - 600000 <= timestamp <= end_ms + 600000:
            continue
        if abs(timestamp - (start_ms + (ds - start_ds) * 100)) > 300000:
            continue
        if tag in (0x60, 0x80):
            amplitude = value.get("amplitude", [])
            quality = value.get("quality", [])
            elapsed = 0
            for i, ibi in enumerate(value.get("ibi_ms", [])):
                if ibi <= 0:
                    continue
                elapsed += ibi
                valid = 300 <= ibi <= 2000 and (tag != 0x80 or (i < len(quality) and quality[i] == 1))
                beats.append((timestamp + elapsed, float(ibi),
                              float(amplitude[i]) if i < len(amplitude) else 0.0, float(valid)))
        elif tag == 0x47 and value.get("motion_seconds") is not None:
            motion.append((timestamp, float(value["motion_seconds"])))
        elif tag == 0x46 and value.get("temps_c"):
            temp.append((timestamp, float(value["temps_c"][0])))
    return sorted(beats), sorted(motion), sorted(temp)
