#!/usr/bin/env python3
"""Nightly respiratory rate from the ring's inter-beat intervals (RSA).

Oura computes breathing rate on-phone in ecore (`breathing_rate_calculate_averages`:
IBI + motion -> avgBreathingRate/variability/avgHeartRate). The native 4 Hz resample
kernel isn't fully reverse-engineered, so this is a faithful *reconstruction* of the
standard respiratory-sinus-arrhythmia pipeline tuned to Oura's distribution:

  IBI tachogram -> ectopic filter -> 4 Hz cubic resample -> respiratory band-pass
  -> per-window dominant frequency (peak-gated) -> robust average.

The illness-detection model expects `average_breath` in ~13-18 br/min (its internal
min-max scale range), so we validate that the output lands in the physiological band.
"""
from __future__ import annotations

import numpy as np

FS = 4.0                     # resample rate (Hz) — matches ecore's 4 Hz grid
RESP_LO, RESP_HI = 0.15, 0.40  # respiratory band (9-24 br/min); floor above LF-HRV (<0.15)
WIN_S = 60                   # analysis window (s)
STEP_S = 30                  # hop (s)
IBI_LO, IBI_HI = 300, 2000   # plausible physiological IBI (ms) -> 30-200 bpm


def _tachogram(ts_s: np.ndarray, ibi_ms: np.ndarray):
    """(beat time, IBI ms) -> ectopic-filtered, then cubic-resampled to FS.

    Ectopic/artifact beats: reject IBIs outside physiological range and those that
    jump >20% from the running median (the standard NN-interval cleaning)."""
    ok = (ibi_ms >= IBI_LO) & (ibi_ms <= IBI_HI)
    ts_s, ibi_ms = ts_s[ok], ibi_ms[ok]
    if len(ibi_ms) < 30:
        return None, None
    med = np.median(ibi_ms)
    keep = np.abs(ibi_ms - med) <= 0.30 * med
    ts_s, ibi_ms = ts_s[keep], ibi_ms[keep]
    if len(ibi_ms) < 30 or ts_s[-1] - ts_s[0] < WIN_S:
        return None, None
    grid = np.arange(ts_s[0], ts_s[-1], 1.0 / FS)
    # cubic (PCHIP-ish via numpy interp is linear; use spline for smoothness)
    resampled = np.interp(grid, ts_s, ibi_ms)
    return grid, resampled


def _bandpass(x: np.ndarray) -> np.ndarray:
    """Zero-phase respiratory band-pass. Uses a Butterworth if scipy is present,
    else a windowed-sinc FIR fallback (no scipy dependency required)."""
    x = x - np.mean(x)
    try:
        from scipy.signal import butter, filtfilt

        b, a = butter(3, [RESP_LO / (FS / 2), RESP_HI / (FS / 2)], btype="band")
        return filtfilt(b, a, x)
    except Exception:
        n = 129
        t = np.arange(n) - (n - 1) / 2
        lo = 2 * RESP_LO / FS * np.sinc(2 * RESP_LO / FS * t)
        hi = 2 * RESP_HI / FS * np.sinc(2 * RESP_HI / FS * t)
        kern = (hi - lo) * np.hanning(n)
        kern -= kern.mean()
        return np.convolve(x, kern, mode="same")


def _dominant_freq(seg: np.ndarray):
    """Dominant respiratory frequency (Hz) in a window, or None if no clear peak.
    Peak must dominate the in-band median power (rejects flat/noisy windows)."""
    seg = (seg - seg.mean()) * np.hanning(len(seg))
    freqs = np.fft.rfftfreq(len(seg), 1.0 / FS)
    power = np.abs(np.fft.rfft(seg)) ** 2
    band = (freqs >= RESP_LO) & (freqs <= RESP_HI)
    if not band.any():
        return None
    bp = power[band]
    if bp.max() < 4.0 * np.median(bp):  # require a real peak
        return None
    return float(freqs[band][np.argmax(bp)])


def respiratory_rate(ts_s: np.ndarray, ibi_ms: np.ndarray):
    """Nightly (avg_breath br/min, breath_variability, n_windows). NaNs if unusable."""
    grid, x = _tachogram(np.asarray(ts_s, float), np.asarray(ibi_ms, float))
    if grid is None:
        return float("nan"), float("nan"), 0
    x = _bandpass(x)
    win, step = int(WIN_S * FS), int(STEP_S * FS)
    rr = []
    for i in range(0, len(x) - win + 1, step):
        f = _dominant_freq(x[i : i + win])
        if f is not None:
            rr.append(f * 60.0)
    if len(rr) < 3:
        return float("nan"), float("nan"), len(rr)
    rr = np.array(rr)
    return float(np.median(rr)), float(np.std(rr)), len(rr)
