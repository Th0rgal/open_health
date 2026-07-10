"""Epoch-aware ring deciseconds -> wall clock, anchored by ring time-sync events."""

import json

EPOCH_RESET_SLACK_DS = 6 * 3600 * 10


def build_epochs(rows):
    """Build boot epochs from `(ds, captured)` pairs or DB `(ds, tag, json, captured)` rows.

    Epoch layout stays list-based for existing callers:
    `[min_ds, max_ds, fallback_unix, capture_min, capture_max, [(ds, unix), ...]]`.
    """
    normalized = []
    for row in rows:
        if len(row) >= 4:
            ds, tag, js, cu = row[0], row[1], row[2], row[3]
        else:
            ds, cu = row
            tag = js = None
        normalized.append((cu, ds, tag, js))
    epochs = []
    # Callers query by `(captured_unix, id)`. Do not sort by ds here: thousands of
    # rows share one capture second, and sorting those rows would erase reboot jumps.
    for cu, ds, tag, js in normalized:
        if epochs and ds >= epochs[-1][1] - EPOCH_RESET_SLACK_DS:
            e = epochs[-1]
            if ds >= e[1]:
                e[1], e[2] = ds, cu
            e[0], e[3], e[4] = min(e[0], ds), min(e[3], cu), max(e[4], cu)
        else:
            epochs.append([ds, ds, cu, cu, cu, []])
        if tag == 0x42 and js:
            try:
                unix = json.loads(js).get("unix_time")
                if unix is not None:
                    epochs[-1][5].append((ds, int(unix)))
            except (ValueError, TypeError):
                pass
    return epochs


def make_unix_s(epochs):
    """Return `f(ds, captured_unix=None)` using time-sync, with capture fallback."""
    def unix_s(ds, captured_unix=None):
        candidates = [e for e in epochs
                      if e[0] - EPOCH_RESET_SLACK_DS <= ds <= e[1] + EPOCH_RESET_SLACK_DS]
        if captured_unix is not None and candidates:
            def capture_distance(e):
                if captured_unix < e[3]:
                    return e[3] - captured_unix
                if captured_unix > e[4]:
                    return captured_unix - e[4]
                return 0
            e = min(candidates, key=capture_distance)
        elif candidates:
            e = min(candidates, key=lambda x: x[1] - x[0])
        else:
            e = epochs[-1]
        if e[5]:
            anchor_ds, anchor_unix = min(e[5], key=lambda a: abs(a[0] - ds))
            return anchor_unix + (ds - anchor_ds) / 10.0
        return e[2] - (e[1] - ds) / 10.0
    return unix_s


def latest_unix(epochs):
    anchors = [unix for e in epochs for _, unix in e[5]]
    return max(anchors) if anchors else max(e[2] for e in epochs)
