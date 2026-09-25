// open_oura dashboard — fetch /api/summary (Rust computes it) and render.
//
// SIBLING CLIENT: the native iOS app (apps/ios/OuraApp/OuraApp.swift) renders the SAME
// summary JSON. A user-facing change here usually belongs there too — see the feature
// map in docs/clients-web-and-ios.md. New computed fields go in crates/oura-summary.
"use strict";

const $ = (id) => document.getElementById(id);
const el = (tag, cls, html) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
};
const num = (v, d = "—") => (v == null || Number.isNaN(v) ? d : v);
const icon = (name, cls = "") => `<span class="ic ${cls}" style="--i:url(/icons/${name}.svg)"></span>`;
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const cap = (s) => esc(s).replace(/^./, (c) => c.toUpperCase());
const kfmt = (n) => (n >= 1000 ? (n / 1000).toFixed(n >= 10000 ? 0 : 1) + "k" : String(Math.round(n)));

let CURRENT_PROFILE = null;
let LAST_DEVICE_SERIAL = null;

// ── local dashboard fetch helpers ──────────────────────────────────────────
// Every mutating endpoint is gated by the X-Oura-Dash header; these centralize it
// (and the JSON POST envelope) so the call sites can't drift. They return the raw
// Response, so each caller keeps its own r.ok / body / error handling.
const DASH_HEADERS = { "X-Oura-Dash": "1" };
function postDash(url, body) {
  const opts = { method: "POST", headers: { ...DASH_HEADERS } };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  return fetch(url, opts);
}
function getDash(url) {
  return fetch(url, { headers: { ...DASH_HEADERS } });
}

// Smooth curve THROUGH the points using a monotone cubic Hermite spline
// (Fritsch–Carlson). Monotone = the curve never overshoots past a data point, so it
// won't invent peaks/valleys the data doesn't have — the right call for real metrics.
function smoothPath(pts) {
  const n = pts.length;
  if (n < 2) return "";
  const x = pts.map((p) => p[0]), y = pts.map((p) => p[1]);
  if (n === 2) return `M${x[0].toFixed(1)} ${y[0].toFixed(1)} L${x[1].toFixed(1)} ${y[1].toFixed(1)}`;
  const dx = [], dy = [], dd = []; // secant slopes
  for (let i = 0; i < n - 1; i++) { dx[i] = x[i + 1] - x[i]; dy[i] = y[i + 1] - y[i]; dd[i] = dy[i] / dx[i]; }
  const m = new Array(n);
  m[0] = dd[0];
  m[n - 1] = dd[n - 2];
  for (let i = 1; i < n - 1; i++) m[i] = dd[i - 1] * dd[i] <= 0 ? 0 : (dd[i - 1] + dd[i]) / 2;
  for (let i = 0; i < n - 1; i++) {
    if (dd[i] === 0) { m[i] = 0; m[i + 1] = 0; continue; }
    const a = m[i] / dd[i], b = m[i + 1] / dd[i], s2 = a * a + b * b;
    if (s2 > 9) { const t = 3 / Math.sqrt(s2); m[i] = t * a * dd[i]; m[i + 1] = t * b * dd[i]; }
  }
  let d = `M${x[0].toFixed(1)} ${y[0].toFixed(1)}`;
  for (let i = 0; i < n - 1; i++) {
    const h = dx[i] / 3;
    d += ` C${(x[i] + h).toFixed(1)} ${(y[i] + m[i] * h).toFixed(1)} ` +
         `${(x[i + 1] - h).toFixed(1)} ${(y[i + 1] - m[i + 1] * h).toFixed(1)} ` +
         `${x[i + 1].toFixed(1)} ${y[i + 1].toFixed(1)}`;
  }
  return d;
}

// monochrome, thin, with a faint area fill — subtle and elegant
function sparkline(series) {
  const s = (series || []).filter((x) => x != null);
  if (s.length < 2) return "";
  const w = 100, h = 26, min = Math.min(...s), max = Math.max(...s);
  const rng = max - min || 1;
  const pts = s.map((v, i) => [(i / (s.length - 1)) * w, h - ((v - min) / rng) * (h - 5) - 3]);
  const d = smoothPath(pts);
  const area = `${d} L${w.toFixed(1)} ${h} L0 ${h} Z`;
  const last = pts[pts.length - 1];
  // the SVG is stretched non-uniformly (preserveAspectRatio=none), which would
  // squash an in-SVG <circle> into an ellipse — so the end dot is a separate,
  // unstretched element positioned at the last point (vertical axis is 1:1 with px).
  return `<svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
    <path d="${area}" fill="var(--spark-fill)" stroke="none"/>
    <path d="${d}" fill="none" stroke="var(--spark)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>
  </svg><i class="spark-dot" style="top:${last[1].toFixed(1)}px"></i>`;
}

// a status pill (colored dot + label); kind ∈ ok | warn | neutral
function pill(label, kind) {
  const p = el("span", "pill " + kind);
  p.append(el("i"), document.createTextNode(label));
  return p;
}

// Normal / attention status from a delta% and which direction is healthy.
function statusFor(deltaPct, good) {
  if (deltaPct == null) return null;
  if (Math.abs(deltaPct) <= 5) return { label: "Normal", kind: "ok" };
  const improving = good === "up" ? deltaPct > 0 : deltaPct < 0;
  if (improving) return { label: good === "up" ? "High" : "Low", kind: "ok" };
  return { label: good === "up" ? "Low" : "Elevated", kind: "warn" };
}

// baseline comparison bar: current value as a fill, the reference (personal baseline
// or target) as a marker, on a shared 0…(max×1.3) scale — the "your result vs
// reference" pattern from clinical dashboards.
function cmpBar(value, ref, unit, refLabel = "baseline") {
  const hi = Math.max(value, ref) * 1.3 || 1;
  const wrap = el("div", "cmp");
  const track = el("div", "cmp-track");
  const fill = el("i", "cmp-fill");
  fill.style.width = Math.max(3, Math.min(100, (value / hi) * 100)) + "%";
  const mark = el("span", "cmp-mark");
  mark.style.left = Math.min(100, (ref / hi) * 100) + "%";
  track.append(fill, mark);
  const dRaw = Math.round((value - ref) * 10) / 10;
  const cap = el("div", "cmp-cap");
  cap.innerHTML = `${refLabel} <b>${num(Math.round(ref * 10) / 10)}</b>${unit} · ${dRaw >= 0 ? "+" : ""}${dRaw}${unit}`;
  wrap.append(track, cap);
  return wrap;
}

function metricCard(label, value, unit, opts = {}) {
  const { deltaPct, ref, refLabel, good = "up", status, sub } = opts;
  const t = el("article", "tile");
  const head = el("div", "tile-head");
  head.append(el("div", "label", label));
  const st = status !== undefined ? status : statusFor(deltaPct, good);
  if (st) head.append(pill(st.label, st.kind));
  t.append(head);
  t.append(el("div", "value", `${num(value)}<span class="unit">${unit || ""}</span>`));
  if (typeof value === "number" && ref != null) t.append(cmpBar(value, ref, unit || "", refLabel));
  else if (sub) t.append(el("div", "sub", sub));
  return t;
}

const relAge = (diff) => {
  const a = Math.abs(Math.round(diff * 10) / 10);
  if (diff < -0.05) return { short: `${a} yr younger`, long: `${a} ${a === 1 ? "year" : "years"} younger than` };
  if (diff > 0.05) return { short: `${a} yr older`, long: `${a} ${a === 1 ? "year" : "years"} older than` };
  return { short: "in line", long: "in line with" };
};

function renderTiles(d) {
  const box = $("tiles");
  box.innerHTML = "";
  box.classList.add("reveal");
  const hv = d.vitals?.hrv || {}, rh = d.vitals?.rhr || {};
  const n0 = (d.nights || [])[0] || {};
  box.append(metricCard("HRV (RMSSD)", hv.latest, " ms", { deltaPct: hv.delta_pct, ref: hv.baseline, good: "up" }));
  box.append(metricCard("Resting HR", rh.latest, " bpm", { deltaPct: rh.delta_pct, ref: rh.baseline, good: "down" }));
  const eff = n0.efficiency;
  box.append(metricCard("Sleep efficiency", eff, "%", {
    ref: 85, refLabel: "target", good: "up",
    status: eff == null ? null : eff >= 85 ? { label: "Normal", kind: "ok" } : eff >= 75 ? { label: "Fair", kind: "neutral" } : { label: "Low", kind: "warn" },
  }));
  const cv = d.cardio;
  if (cv && cv.vascular_age != null) {
    const diff = cv.vascular_age - cv.chronological_age;
    box.append(metricCard("Vascular age", cv.vascular_age, " yr", {
      ref: cv.chronological_age, refLabel: "your age", good: "down",
      status: diff < -0.5 ? { label: "Younger", kind: "ok" } : diff > 0.5 ? { label: "Older", kind: "warn" } : { label: "In line", kind: "neutral" },
    }));
  } else {
    box.append(metricCard("Vascular age", "—", "", { sub: "needs cva_ppg on" }));
  }
}

function hypnogram(stages) {
  const wrap = el("div", "hyp");
  (stages || []).forEach((s) => wrap.append(el("i", "s" + s)));
  return wrap;
}

// ── the unified "day" (night + activity of the same date) ──────────────────
// A day is keyed by YYYY-MM-DD. The most recent one is the hero card; the rest
// live behind "Show all N days". This mirrors the iOS app's home + AllDaysView.

// The calendar date you WOKE from a night. Nights are labelled by onset date (the
// evening you went to bed), so an overnight sleep that crosses midnight belongs to
// the next day's "morning". Pairing a day with the sleep you woke from — not the
// sleep you started that evening — is what makes "night + activity of the day" read
// as one coherent day. Kept identical to the iOS Summary.wakeYmd.
function wakeYmd(n) {
  if (!n || !n.ymd) return null;
  if (n.wake_ymd) return n.wake_ymd;
  if (n.start && n.end && n.end < n.start) {
    const [y, m, dd] = n.ymd.split("-").map(Number);
    const t = new Date(y, m - 1, dd + 1);
    return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}`;
  }
  return n.ymd;
}

// every date that has a night (by wake date), a movement profile, daily totals, or a
// session — newest first
function dayKeys(d) {
  const set = new Set();
  (d.nights || []).forEach((n) => { const w = wakeYmd(n); if (w) set.add(w); });
  Object.keys(d.activity_profile || {}).forEach((k) => set.add(k));
  Object.keys(d.activity_daily || {}).forEach((k) => set.add(k));
  (d.activity || []).forEach((s) => { const y = (s.start || "").split(" ")[0]; if (y) set.add(y); });
  return [...set].filter(Boolean).sort().reverse();
}

// the primary sleep you woke from on the morning of `ymd` — the longest in-bed night
// wins over same-morning naps. Falls back to a MM-DD match for older data lacking ymd.
function nightForDay(d, ymd) {
  const cands = (d.nights || []).filter((n) => wakeYmd(n) === ymd);
  if (cands.length) return cands.reduce((a, b) => ((b.in_bed_h || 0) > (a.in_bed_h || 0) ? b : a));
  return (d.nights || []).find((n) => n.ymd == null && (n.date || "").endsWith(ymd.slice(5))) || null;
}

// this day's sessions, start rewritten to minutes-past-midnight so openActDetail()
// (which formats s.start with hhmm()) renders them correctly.
function sessionsForDay(d, ymd) {
  return (d.activity || [])
    .filter((s) => (s.start || "").startsWith(ymd))
    .map((s) => {
      const [h, m] = ((s.start || "").split(" ")[1] || "0:0").split(":").map(Number);
      return { ...s, start: (h || 0) * 60 + (m || 0) };
    })
    .sort((a, b) => a.start - b.start);
}

const dayTitle = (ymd) => {
  const p = (ymd || "").split("-");
  if (p.length !== 3) return ymd;
  const dt = new Date(+p[0], +p[1] - 1, +p[2]);
  return `${WD[dt.getDay()]} · ${fmtDay(ymd)}`;
};

// continuous movement ridge (96 × 15-min MET buckets) as a filled SVG area
const RIDGE_H = 30;
function ridgeSvg(profile) {
  const prof = (profile || []).map((v) => v || 0);
  if (prof.length < 2) return "";
  const peak = Math.max(0.5, ...prof);
  const pts = prof.map((v, i) => [(i / (prof.length - 1)) * 100, RIDGE_H - Math.min(1, v / peak) * RIDGE_H]);
  const d = `${smoothPath(pts)} L100 ${RIDGE_H} L0 ${RIDGE_H} Z`;
  return `<svg class="day-ridge" viewBox="0 0 100 ${RIDGE_H}" preserveAspectRatio="none"><path d="${d}"/></svg>`;
}

// the combined day card: a clickable Sleep region (→ sleep detail) above a clickable
// Activity region (→ activity detail). Used as the hero on the home panel.
function dayCard(d, ymd) {
  const card = el("div", "day-card");
  card.append(el("div", "day-date", dayTitle(ymd)));

  const n = nightForDay(d, ymd);
  if (n) {
    const sp = el("button", "day-part");
    sp.type = "button";
    sp.append(el("div", "dp-head",
      `<span class="dp-tag">Sleep</span><span class="dp-meta">${esc(n.start || "—")}–${esc(n.end || "—")} · ${num(n.in_bed_h)}h</span><span class="dp-chev"></span>`));
    if (n.stages && n.stages.length) sp.append(hypnogram(n.stages));
    const comp = el("div", "breakdown");
    const seg = (l, v) => `<span>${l} <b>${num(v)}%</b></span>`;
    comp.innerHTML = seg("Deep", n.deep_pct) + seg("Light", n.light_pct) + seg("REM", n.rem_pct) + seg("Awake", n.wake_pct);
    sp.append(comp);
    sp.addEventListener("click", () => openDayPage(d, ymd, "sleep"));
    card.append(sp);
  }

  const ap = el("button", "day-part");
  ap.type = "button";
  const ds = (d.activity_daily || {})[ymd];
  const stat = ds ? `${kfmt(ds.steps)} steps · ${Math.round(ds.active_kcal)} kcal` : "no activity totals";
  ap.append(el("div", "dp-head",
    `<span class="dp-tag">Activity</span><span class="dp-meta">${stat}</span><span class="dp-chev"></span>`));
  const prof = (d.activity_profile || {})[ymd];
  if (prof && prof.length > 1) ap.insertAdjacentHTML("beforeend", ridgeSvg(prof));
  const sessions = sessionsForDay(d, ymd);
  if (sessions.length) {
    const chips = el("div", "day-sessions");
    sessions.forEach((s) => {
      const chip = el("span", "day-chip" + (s.is_workout >= 0.5 ? " workout" : ""));
      const ico = el("span", "ic");
      ico.style.setProperty("--i", `url(/icons/${actIcon(s.label)}.svg)`);
      const nm = el("span", "day-chip-name");
      nm.textContent = s.label || "activity";
      chip.append(ico, nm);
      chips.append(chip);
    });
    ap.append(chips);
  }
  ap.addEventListener("click", () => openDayPage(d, ymd, "activity"));
  card.append(ap);

  // heart rate: the tab's 15-minute bars as a strip on the same 24 h as the ridge above
  const hp = el("button", "day-part");
  hp.type = "button";
  hp.append(el("div", "dp-head",
    `<span class="dp-tag">Heart rate</span><span class="dp-meta">loading…</span><span class="dp-chev"></span>`));
  const strip = el("div", "day-hr");
  hp.append(strip);
  hp.addEventListener("click", () => openDayPage(d, ymd, "heart"));
  card.append(hp);
  fillDayHr(ymd, hp.querySelector(".dp-meta"), strip);
  return card;
}

// The summary doesn't carry per-slot heart rate, so the "Your day" strip fetches it
// on its own and fills in when it arrives.
function fillDayHr(ymd, meta, strip) {
  fetch("/api/hourly-hr?minutes=15")
    .then((r) => r.json())
    .then((j) => {
      if (j.error) throw new Error(j.error);
      const { bySlot, rows } = hrDaySlots(j, ymd);
      if (!rows.length) { meta.textContent = "no readings yet"; return; }
      const r0 = Math.round;
      const low = Math.min(...rows.map((r) => r.low)), high = Math.max(...rows.map((r) => r.high));
      const latest = hrLatestOn(j, ymd);
      meta.textContent = (latest != null ? `latest ${r0(latest)} bpm · ` : "") + `${r0(low)}–${r0(high)} bpm`;
      strip.innerHTML =
        `<div class="day-hr-plot">${hrBinsSvg(bySlot, Math.max(0, low - 5), high + 5, 1000, 44, false)}</div>` +
        `<div class="met-axis">${[0, 6, 12, 18, 24].map((h) => `<span style="left:${(h / 24 * 100).toFixed(1)}%">${String(h).padStart(2, "0")}</span>`).join("")}</div>`;
    })
    .catch(() => { meta.textContent = "couldn't load"; });
}

function renderDay(d) {
  const box = $("day");
  box.innerHTML = "";
  const days = dayKeys(d);
  if (!days.length) {
    box.append(el("div", "error", "No days yet. Wear the ring and sync."));
    $("sleep-legend").hidden = true;
    return;
  }
  const top = days[0];
  $("sleep-legend").hidden = !(nightForDay(d, top) || {}).stages;
  box.append(dayCard(d, top));
  if (days.length > 1) {
    const btn = el("button", "more-toggle");
    btn.textContent = `Show all ${days.length} days`;
    btn.addEventListener("click", () => openDaysBrowser(d, days));
    box.append(btn);
  }
}

const debtDuration = (minutes) => {
  const m = Math.max(0, Math.round(minutes || 0));
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
};
const debtStateCopy = (state) => ({
  high: "Your sleep debt is high right now. Prioritize several consistent nights with enough sleep.",
  moderate: "You’ve built up a moderate amount of sleep debt. A few longer nights can help you recover.",
  low: "You’re mostly meeting your sleep need, with a small amount left to recover.",
  none: "You’ve met your sleep need consistently over the past two weeks.",
}[state] || "You’ve met your sleep need consistently over the past two weeks.");

function sleepDebtSvg(sd, mode) {
  const values = (sd.days || []).map((x) => mode === "debt" ? x.cumulative_debt_min : x.total_sleep_min);
  const w = 900, h = 190, max = mode === "debt" ? 600 : Math.max(720, ...values.filter((x) => x != null));
  const x = (i) => i / Math.max(1, values.length - 1) * w;
  const y = (v) => h - Math.min(1, Math.max(0, v / max)) * h;
  let path = "", started = false;
  values.forEach((v, i) => {
    if (v == null) { started = false; return; }
    path += `${started ? " L" : "M"}${x(i).toFixed(1)} ${y(v).toFixed(1)}`; started = true;
  });
  const grid = [0.25, 0.5, 0.75].map((f) => `<line x1="0" y1="${h * (1-f)}" x2="${w}" y2="${h * (1-f)}"/>`).join("");
  const need = mode === "sleep" ? `<line class="sd-need" x1="0" y1="${y(sd.need_h * 60)}" x2="${w}" y2="${y(sd.need_h * 60)}"/>` : "";
  return `<svg class="sd-chart" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none"><g class="sd-grid">${grid}</g>${need}<path class="sd-line" d="${path}"/></svg>`;
}

function openSleepDebt(sd) {
  let dlg = $("sleep-debt-dialog");
  if (!dlg) {
    dlg = el("dialog", "dialog sleep-debt-dialog"); dlg.id = "sleep-debt-dialog";
    document.body.append(dlg);
    dlg.addEventListener("click", (e) => { if (e.target === dlg) dlg.close(); });
  }
  const valid = sd.valid;
  dlg.innerHTML = `<form method="dialog">
    <div class="sd-detail-head"><div><h3>Sleep debt</h3><div class="dialog-sub">Past ${sd.window_days || 14} days</div></div><button class="dd-close" aria-label="Close">×</button></div>
    ${valid ? `<div class="sd-value">${debtDuration(sd.debt_min)} <span>${esc(sd.state)}</span></div><p class="sd-copy">${debtStateCopy(sd.state)}</p>`
      : `<div class="sd-value small">Not enough data yet</div><p class="sd-copy">${sd.valid_days || 0} of 5 sleep days available within the past 2 weeks.</p>`}
    <div class="sd-tabs"><button type="button" data-mode="debt" class="active">Cumulative debt</button><button type="button" data-mode="sleep">Total sleep</button></div>
    <div class="sd-graph">${sleepDebtSvg(sd, "debt")}</div>
    <div class="sd-axis"><span>${esc((sd.days?.[0]?.date || "").slice(5))}</span><span>${esc((sd.days?.at(-1)?.date || "").slice(5))}</span></div>
    <p class="subhead">How it works</p><p class="sd-copy">Sleep debt estimates missed sleep over the past 14 days. Total sleep combines main sleep and naps, recent days carry more weight, and your sleep need (${debtDuration(sd.need_h * 60)}) is personalized from your typical sleep over the past 3 months, ignoring unusually short or long days.</p>
  </form>`;
  dlg.querySelectorAll(".sd-tabs button").forEach((button) => button.addEventListener("click", () => {
    dlg.querySelectorAll(".sd-tabs button").forEach((b) => b.classList.toggle("active", b === button));
    dlg.querySelector(".sd-graph").innerHTML = sleepDebtSvg(sd, button.dataset.mode);
  }));
  dlg.showModal();
}

function renderSleepDebt(d) {
  const box = $("sleep-debt"), sd = d.sleep_debt;
  box.innerHTML = "";
  if (!sd) { box.append(el("div", "error", "No sleep data yet.")); return; }
  const button = el("button", "sd-card"); button.type = "button";
  if (sd.valid) button.innerHTML = `<div class="sd-card-value">${debtDuration(sd.debt_min)} <span>${esc(sd.state)}</span></div><p>${debtStateCopy(sd.state)}</p><span class="sd-period">Past ${sd.window_days || 14} days · view details →</span>`;
  else button.innerHTML = `<div class="sd-card-value pending">${sd.valid_days || 0} of 5 days available</div><p>5 days of sleep data are needed within the past 2 weeks.</p><span class="sd-period">View details →</span>`;
  button.addEventListener("click", () => openSleepDebt(sd)); box.append(button);
}

// Symptom Radar: Oura's on-device illness-detection model. Traffic-light state from the
// calibrated decision + the biomarkers (breath / lowest HR / HRV / temp) that deviate
// from your personal baseline. See docs/algorithms/illness-detection.md.
const ILLNESS_COPY = {
  NO_SIGNS: "No signs of illness. Your biometrics are within your normal range.",
  MINOR_SIGNS: "Minor signs. A few biometrics are outside your usual range — worth an easy day.",
  MAJOR_SIGNS: "Major signs. Several biometrics are elevated — your body may be fighting something.",
};
const ILLNESS_LIGHT = { NO_SIGNS: "ok", MINOR_SIGNS: "warn", MAJOR_SIGNS: "alert" };
const BIOMARKER_LABEL = {
  AverageBreath: "Breathing rate", LowestHeartRate: "Lowest heart rate",
  AverageHrv: "HRV", TemperatureDeviation: "Body temperature",
};
const BIOMARKER_UNIT = {
  AverageBreath: " br/min", LowestHeartRate: " bpm", AverageHrv: " ms", TemperatureDeviation: "°C",
};

function renderIllness(d) {
  const box = $("illness");
  box.innerHTML = "";
  const ill = d.illness;
  if (!ill) { box.append(el("div", "error", "Symptom radar needs the model runner (desktop dashboard).")); return; }
  if (!ill.available) {
    const why = ill.status === "MISSING_LAST_NIGHT_SLEEP" ? "Last night's sleep is missing — wear the ring overnight and sync."
      : ill.status === "MISSING_SLEEP_DATA" ? "Too many recent nights are missing (needs ≥ 7 of the last 14)."
      : "Not enough history yet.";
    box.append(el("div", "error", why));
    return;
  }
  const light = ILLNESS_LIGHT[ill.traffic_light] || "ok";
  const head = el("div", `il-status il-${light}`);
  const label = ill.traffic_light === "NO_SIGNS" ? "No signs" : ill.traffic_light === "MINOR_SIGNS" ? "Minor signs" : "Major signs";
  head.innerHTML = `<span class="il-dot"></span><span class="il-label">${label}</span>`;
  box.append(head);
  box.append(el("p", "il-copy", ILLNESS_COPY[ill.status] || ""));

  const flagged = (ill.biomarkers || []).filter((b) => b.indicatesSymptoms);
  if (flagged.length) {
    const list = el("div", "il-biomarkers");
    for (const b of flagged) {
      const dir = b.reason === "ELEVATED" ? "↑ elevated" : "↓ decreased";
      const unit = BIOMARKER_UNIT[b.type] || "";
      list.append(el("div", `il-bm il-${b.reason === "ELEVATED" ? "up" : "down"}`,
        `<span class="il-bm-name">${BIOMARKER_LABEL[b.type] || b.type}</span>` +
        `<span class="il-bm-val">${b.value}${unit} <em>${dir}</em></span>`));
    }
    box.append(list);
  }
  box.append(el("div", "il-foot", `On-device illness model · ${ill.days_with_data} of 30 days · ${esc(ill.date)}`));
}

function renderCardio(d) {
  const box = $("cardio");
  const cv = d.cardio;
  const vo2 = d.fitness?.vo2max;
  box.innerHTML = "";
  // VO₂max is model-free (from demographics), so it shows even without the CVA model.
  const vo2Kv = vo2 != null ? el("div", "kv", `<div class="k">VO₂max estimate</div><div class="v">${vo2} ml/kg/min</div>`) : null;
  if (!cv || cv.vascular_age == null) {
    box.append(el("div", "error", "Cardiovascular age needs the cva_ppg feature on. Enable it, then sync overnight."));
    if (vo2Kv) { const kvs = el("div", "kvs"); kvs.append(vo2Kv); box.append(kvs); }
    return;
  }
  box.append(el("div", "big-metric", `<span class="n">${cv.vascular_age}</span><span class="u">years vascular age</span>`));
  box.append(el("div", "sub", `${relAge(cv.vascular_age - cv.chronological_age).long} your age (${cv.chronological_age})`));
  const kvs = el("div", "kvs");
  kvs.append(el("div", "kv", `<div class="k">Pulse-wave velocity</div><div class="v">${cv.pwv_ms != null ? cv.pwv_ms + " m/s" : "—"}</div>`));
  kvs.append(el("div", "kv", `<div class="k">Segments analysed</div><div class="v">${num(cv.segments)}</div>`));
  if (vo2Kv) kvs.append(vo2Kv);
  box.append(kvs);
}

function renderSpo2(d) {
  const box = $("spo2");
  box.innerHTML = "";
  const n0 = (d.nights || []).find((n) => n.spo2_mean != null);
  if (!n0) {
    box.append(el("div", "error", "Blood oxygen needs the spo2 feature on overnight."));
    return;
  }
  // SpO2 gauge scale: clamp the reading into [SPO2_MIN, 100] and map to 0–100% fill.
  const SPO2_MIN = 85, SPO2_HEALTHY = 95;
  box.append(el("div", "big-metric", `<span class="n">${n0.spo2_mean}</span><span class="u">% avg, last night</span>`));
  box.append(el("div", "sub", "Calibrated from the ring's R-ratio (Oura's own curve)."));
  const pct = Math.max(0, Math.min(100, ((n0.spo2_mean - SPO2_MIN) / (100 - SPO2_MIN)) * 100));
  const g = el("div", "gauge");
  const fill = el("i");
  fill.style.width = pct + "%";
  g.append(fill);
  box.append(g);
  box.append(el("div", "scale", `<span>${SPO2_MIN}</span><span>healthy ≥ ${SPO2_HEALTHY}</span><span>100</span>`));
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const fmtDay = (ymd) => {
  const p = (ymd || "").split("-");
  return p.length === 3 ? `${MONTHS[+p[1] - 1]} ${+p[2]}` : ymd;
};

const WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const hhmm = (min) => `${String((min / 60) | 0).padStart(2, "0")}:${String(min % 60).padStart(2, "0")}`;

// activity type → vendored glyph (keyword-matched so the ~40 AAD labels resolve to one
// of the clean vendored icons; unknowns fall back to a generic activity mark).
const ACT_ICON = [
  [/run/, "act-running"],
  [/walk|hik|nordic/, "act-walking"],
  [/cycl|bik/, "act-cycling"],
  [/swim|dive/, "act-swimming"],
  [/yoga|pilates|stretch|meditat/, "act-yoga"],
  [/strength|core|cross ?train|hiit|interval|fitness|elliptical|row|box|martial|climb/, "act-strength"],
];
const actIcon = (label) => {
  const l = (label || "").toLowerCase();
  for (const [re, icon] of ACT_ICON) if (re.test(l)) return icon;
  return "act-default";
};

// session detail popover (opened from a day's session row)
function openActDetail(s) {
  let dlg = $("act-dialog");
  if (!dlg) {
    dlg = el("dialog", "dialog act-dialog");
    dlg.id = "act-dialog";
    document.body.append(dlg);
    dlg.addEventListener("click", (e) => { if (e.target === dlg) dlg.close(); });
  }
  const work = s.is_workout >= 0.5;
  const conf = s.label_confidence != null ? Math.round(s.label_confidence * 100) + "%" : "—";
  const kv = (k, v) => `<div class="kv"><div class="k">${k}</div><div class="v">${v}</div></div>`;
  const top3 = (s.top3 || [])
    .map(([n, p]) => `<div class="t3"><span class="t3n">${cap(n)}</span><span class="t3bar"><i style="width:${Math.round(p * 100)}%"></i></span><span class="t3p">${Math.round(p * 100)}%</span></div>`)
    .join("");
  dlg.innerHTML =
    `<form method="dialog">
      <div class="ad-head">
        <span class="ic" style="--i:url(/icons/${actIcon(s.label)}.svg)"></span>
        <h3>${cap(s.label || "activity")}</h3>
        ${work ? '<span class="ad-tag">workout</span>' : ""}
      </div>
      <div class="ad-grid">
        ${kv("Time", `${hhmm(s.start)}–${s.end}`)}
        ${kv("Duration", `${s.duration_min} min`)}
        ${s.active_kcal != null ? kv("Active calories", `${Math.round(s.active_kcal).toLocaleString()} kcal`) : ""}
        ${kv("Confidence", conf)}
        ${kv("Workout", work ? "yes" : "no")}
      </div>
      <p class="subhead">Model's guesses</p>
      <div class="t3list">${top3 || '<div class="ad-muted">no alternates</div>'}</div>
      <p class="ad-foot">Oura automatic_activity_detection — best guess from MET / motion / HR / temp.</p>
      <div class="dialog-actions"><button class="btn-primary">Close</button></div>
    </form>`;
  dlg.showModal();
}

// ── full-page sleep & activity reports ─────────────────────────────────────
// Detail opens as a full page (not a modal): a scientific report with a stacked
// polysomnograph (hypnogram + aligned signal lanes sharing one night-time axis and a
// hover crosshair), clinical metrics, and interpretation. Activity gets its own page.

const STAGE = {
  1: { name: "Deep", cls: "deep", lvl: 3 },
  2: { name: "Light", cls: "light", lvl: 2 },
  3: { name: "REM", cls: "rem", lvl: 1 },
  4: { name: "Awake", cls: "wake", lvl: 0 },
};
const parseHM = (s) => { const [h, m] = (s || "0:0").split(":").map(Number); return (h || 0) * 60 + (m || 0); };
// the night's clock window unwrapped across midnight (end can exceed 1440)
function nightWin(n) {
  let a = parseHM(n.start), b = parseHM(n.end);
  if (b <= a) b += 1440;
  return { a, b, span: Math.max(1, b - a) };
}
const clockAt = (win, f) => {
  const t = Math.round(win.a + f * win.span) % 1440;
  return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
};

// full-page overlay control
function showPage(node) {
  const p = $("page");
  p.replaceChildren(node);
  p.hidden = false;
  p.scrollTop = 0;
  document.body.classList.add("page-open");
}
function closePage() {
  const p = $("page");
  p.hidden = true;
  p.replaceChildren();
  document.body.classList.remove("page-open");
  DAY_NAV = null;
}
let DAY_NAV = null; // the open day page's ← / → targets
document.addEventListener("keydown", (e) => {
  if ($("page").hidden) return;
  if (e.key === "Escape") closePage();
  else if (DAY_NAV && !e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey) {
    const go = e.key === "ArrowLeft" ? DAY_NAV.older : e.key === "ArrowRight" ? DAY_NAV.newer : null;
    if (go) { e.preventDefault(); go(); }
  }
});

// ── day page: one scrolling page — Sleep, Activity, Heart rate — on one time axis ─
// Every chart plots against the same axis (dayAxis) and shares one cursor (dayCursor),
// so a vertical line marks the same moment in all of them. `focus` ("sleep" |
// "activity" | "heart") scrolls to that section on open.
function openDayPage(d, ymd, focus = null, keepScroll = false) {
  const wrap = el("div", "rpt");
  const head = el("div", "rpt-head");
  const back = el("button", "rpt-back", "‹ Back");
  back.type = "button";
  back.addEventListener("click", closePage);
  const axis = dayAxis(d, ymd);
  const exp = el("button", "rpt-back rpt-export", "Export JSON");
  exp.type = "button";
  exp.title = "Download this day's sleep, activity and heart-rate data as JSON";
  exp.addEventListener("click", () => exportDayJson(d, ymd, axis));
  // ‹ › step through the days that have data (dayKeys, newest first) at the same
  // scroll position — so one chart can be compared across days
  const days = dayKeys(d);
  const older = days.find((k) => k < ymd) || null;
  const newer = days.slice().reverse().find((k) => k > ymd) || null;
  const go = (k) => openDayPage(d, k, null, true);
  const step = (k, label, name, key) => {
    const b = el("button", "rpt-day", label);
    b.type = "button";
    b.title = k ? `${name} day: ${dayTitle(k)} (${key})` : `No ${name === "Previous" ? "earlier" : "later"} day`;
    b.setAttribute("aria-label", b.title);
    if (k) b.addEventListener("click", () => go(k));
    else b.disabled = true;
    return b;
  };
  const when = el("div", "rpt-when");
  when.append(step(older, "‹", "Previous", "←"), el("div", "rpt-title", dayTitle(ymd)), step(newer, "›", "Next", "→"));
  head.append(back, when, exp);
  const cursor = dayCursor(axis);
  const body = el("div", "rpt-body");
  body.append(sleepSection(d, ymd, axis, cursor), activitySection(d, ymd, axis, cursor), heartSection(ymd, axis, cursor));
  wrap.append(head, body);
  const top = $("page").scrollTop;
  showPage(wrap);
  if (keepScroll) $("page").scrollTop = top;
  else if (focus) wrap.querySelector(`#sec-${focus}`)?.scrollIntoView({ block: "start" });
  DAY_NAV = { older: older && (() => go(older)), newer: newer && (() => go(newer)) };
}

// The day page's shared time axis, in unix seconds: from the start of this day's night
// (floored to the hour) when it began the evening before, else local midnight, to the
// midnight that ends the day. `frac` maps a time onto it and `at` maps back.
function dayAxis(d, ymd) {
  const tz = d.tz || 0;
  const [y, mo, dd] = ymd.split("-").map(Number);
  const dayStart = Date.UTC(y, mo - 1, dd) / 1000 - tz * 3600;
  const n = nightForDay(d, ymd);
  const t0 = n && n.start_unix != null && n.start_unix < dayStart ? Math.floor(n.start_unix / 3600) * 3600 : dayStart;
  const t1 = dayStart + 86400;
  const pad = (v) => String(v).padStart(2, "0");
  return {
    t0, t1, dayStart,
    frac: (t) => (t - t0) / (t1 - t0),
    at: (f) => t0 + f * (t1 - t0),
    clock: (t) => {
      const s = (((Math.floor(t) + tz * 3600) % 86400) + 86400) % 86400;
      return `${pad(Math.floor(s / 3600))}:${pad(Math.floor((s % 3600) / 60))}`;
    },
    // 6-hourly ticks on the local clock, plus the axis start when it isn't one
    ticks() {
      const out = [];
      for (let t = Math.ceil(t0 / 3600) * 3600; t <= t1; t += 3600) {
        const h = ((((t + tz * 3600) / 3600) % 24) + 24) % 24;
        if (h % 6 === 0 || t === t0) out.push({ f: (t - t0) / (t1 - t0), label: t === t1 ? "24" : pad(h) });
      }
      return out;
    },
  };
}

// One cursor for the whole day page: hovering any timeline box draws the line at the
// same moment through every box, shows the clock in each box's pill, and swaps each
// row's summary for its value at that time. Boxes register as they render (heart rate
// arrives later and re-renders on the 15 min / 1 h switch); `onMove` hooks extra
// readouts, one per key.
function dayCursor(axis) {
  let boxes = [];
  const hooks = new Map();
  const show = (f) => {
    boxes = boxes.filter((b) => b.el.isConnected);
    const t = axis.at(f);
    for (const b of boxes) {
      b.line.hidden = b.pill.hidden = false;
      b.line.style.setProperty("--f", f);
      b.pill.style.setProperty("--f", f);
      b.pill.textContent = axis.clock(t);
      for (const r of b.rows) r.val.textContent = r.valueAt(t);
    }
    hooks.forEach((fn) => fn(t));
  };
  const hide = () => {
    for (const b of boxes) {
      b.line.hidden = b.pill.hidden = true;
      for (const r of b.rows) r.val.textContent = r.summary;
    }
    hooks.forEach((fn) => fn(null));
  };
  return {
    add(b) {
      boxes.push(b);
      const move = (e) => {
        const r = b.el.querySelector(".tl-plot").getBoundingClientRect();
        show(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)));
      };
      b.plots.addEventListener("pointermove", move);
      b.plots.addEventListener("pointerdown", move);
      b.plots.addEventListener("pointerleave", hide);
    },
    onMove(key, fn) { hooks.set(key, fn); },
  };
}

// A timeline box: labelled rows over the shared axis, faint 6-hour lines, an hour axis,
// and this box's share of the page cursor. Each row: { label, summary, html, height,
// valueAt(t), rticks } — `rticks` is HTML for the right-hand scale column.
function tlBox(axis, cursor, rows) {
  const box = el("div", "tl");
  const plots = el("div", "tl-plots");
  const ticks = axis.ticks();
  plots.insertAdjacentHTML("beforeend", ticks.map((k) => `<i class="tl-vline" style="--f:${k.f.toFixed(4)}"></i>`).join(""));
  const live = [];
  for (const R of rows) {
    const row = el("div", "tl-row");
    if (R.height) row.style.height = R.height + "px";
    const gut = el("div", "tl-gut");
    const val = el("div", "tl-val");
    val.textContent = R.summary || "";
    gut.append(el("div", "tl-label", esc(R.label)), val);
    const plot = el("div", "tl-plot", R.html);
    row.append(gut, plot, el("div", "tl-rgut", R.rticks || ""));
    plots.append(row);
    live.push({ val, summary: R.summary || "", valueAt: R.valueAt });
  }
  const line = el("div", "tl-cursor");
  const pill = el("div", "tl-pill");
  line.hidden = pill.hidden = true;
  plots.append(line, pill);
  const axisRow = el("div", "tl-axis", ticks.map((k) => `<span style="--f:${k.f.toFixed(4)}">${k.label}</span>`).join(""));
  box.append(plots, axisRow);
  cursor.add({ el: box, plots, line, pill, rows: live });
  return box;
}

const secHead = (title, extra) => {
  const h = el("div", "rpt-sec-head");
  h.append(el("h2", "", title));
  if (extra) h.append(extra);
  return h;
};
const statTile = (k, v) => `<div class="ss"><div class="ss-v">${v}</div><div class="ss-k">${k}</div></div>`;

// The whole day as a JSON download: header + the sleep, activity and heart-rate
// sections (iOS `DayExport` exports one tab's section in the same shapes).
function exportDayJson(d, ymd, axis) {
  const n = nightForDay(d, ymd);
  const debt = ((d.sleep_debt || {}).days || []).find((x) => x.date === ymd) || null;
  const hr = HOURLY_HR || {};
  const payload = {
    day: ymd, kind: "day", generated_at: new Date().toISOString(),
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    app_version: "web", profile: d.profile || null,
    sleep: n ? { night: n, sleep_debt: debt } : null,
    activity: {
      daily: (d.activity_daily || {})[ymd] || null,
      profile_met: (d.activity_profile || {})[ymd] || [],
      workouts: (Array.isArray(d.activity) ? d.activity : []).filter((w) => String(w.start || "").startsWith(ymd)),
    },
    heart_rate: { minutes: hr.minutes || 60, bins: (hr.bins || []).filter((b) => b.unix >= axis.t0 && b.unix < axis.t1) },
  };
  const blob = new Blob([JSON.stringify(payload, null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = `oura-${ymd}.json`;
  document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

const stageLegend = () => el("div", "legend rpt-legend",
  `<span><i class="sw deep"></i>Deep</span><span><i class="sw light"></i>Light</span>` +
  `<span><i class="sw rem"></i>REM</span><span><i class="sw wake"></i>Awake</span>`);

// stepped clinical hypnogram: y = stage level (Awake top → Deep bottom), colored runs
function hypnoSvg(stages, w, h, span = [0, 1]) {
  const n = stages.length;
  const padT = 8, plotH = h - 16;
  const yOf = (lvl) => padT + (lvl / 3) * plotH;
  const xOf = (i) => (span[0] + (i / (n - 1)) * (span[1] - span[0])) * w;
  let grid = "";
  for (let l = 0; l < 4; l++) grid += `<line x1="${xOf(0).toFixed(1)}" y1="${yOf(l).toFixed(1)}" x2="${xOf(n - 1).toFixed(1)}" y2="${yOf(l).toFixed(1)}" stroke="var(--line-soft)" stroke-width="0.5"/>`;
  let runs = "", conn = "", prevLvl = null, i = 0;
  while (i < n) {
    const code = stages[i]; let j = i;
    while (j < n && stages[j] === code) j++;
    const st = STAGE[code] || STAGE[2];
    const x1 = xOf(i), x2 = xOf(Math.min(j, n - 1)), y = yOf(st.lvl);
    runs += `<line x1="${x1.toFixed(1)}" y1="${y.toFixed(1)}" x2="${x2.toFixed(1)}" y2="${y.toFixed(1)}" stroke="var(--${st.cls})" stroke-width="2.5" vector-effect="non-scaling-stroke"/>`;
    if (prevLvl !== null) conn += `<line x1="${x1.toFixed(1)}" y1="${yOf(prevLvl).toFixed(1)}" x2="${x1.toFixed(1)}" y2="${y.toFixed(1)}" stroke="var(--faint)" stroke-width="0.8" opacity="0.5" vector-effect="non-scaling-stroke"/>`;
    prevLvl = st.lvl; i = j;
  }
  return `<svg class="lane-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">${grid}${conn}${runs}</svg>`;
}

// smooth auto-scaled line + faint area + dashed mean, for one signal lane
function laneSvg(v, w, h, color, span = [0, 1]) {
  if (v.length < 2) return null;
  const min = Math.min(...v), max = Math.max(...v), rng = (max - min) || 1;
  const mean = v.reduce((a, b) => a + b, 0) / v.length;
  const pad = 5, y = (val) => pad + (1 - (val - min) / rng) * (h - 2 * pad);
  const x0 = span[0] * w, x1 = span[1] * w;
  const pts = v.map((val, i) => [x0 + (i / (v.length - 1)) * (x1 - x0), y(val)]);
  const line = smoothPath(pts), my = y(mean).toFixed(1);
  return {
    mean, min, max,
    svg: `<svg class="lane-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">` +
      `<path d="${line} L${x1} ${h} L${x0} ${h} Z" fill="${color}" opacity="0.09"/>` +
      `<line x1="${x0}" y1="${my}" x2="${x1}" y2="${my}" stroke="${color}" stroke-width="0.6" stroke-dasharray="3 3" opacity="0.45"/>` +
      `<path d="${line}" fill="none" stroke="${color}" stroke-width="1.4" vector-effect="non-scaling-stroke"/></svg>`,
  };
}

// A signal lane from time-true [unix, value] points (nights[].series_t) on the day axis.
// The line breaks wherever the ring recorded nothing for more than LANE_GAP_S, instead
// of being stretched over the gap.
const LANE_GAP_S = 15 * 60;
function timedLaneSvg(pts, axis, w, h, color) {
  if (pts.length < 2) return null;
  const vals = pts.map((p) => p[1]);
  const min = Math.min(...vals), max = Math.max(...vals), rng = (max - min) || 1;
  const mean = vals.reduce((a, b) => a + b, 0) / vals.length;
  const pad = 5, x = (t) => axis.frac(t) * w, y = (v) => pad + (1 - (v - min) / rng) * (h - 2 * pad);
  const segs = [[]];
  pts.forEach((p, i) => {
    if (i && p[0] - pts[i - 1][0] > LANE_GAP_S) segs.push([]);
    segs[segs.length - 1].push([x(p[0]), y(p[1])]);
  });
  let area = "", line = "";
  for (const s of segs) {
    if (s.length === 1) s.push([s[0][0] + 1.5, s[0][1]]); // a lone point still shows
    const d = smoothPath(s);
    line += d + " ";
    area += `${d} L${s[s.length - 1][0].toFixed(1)} ${h} L${s[0][0].toFixed(1)} ${h} Z `;
  }
  const my = y(mean).toFixed(1);
  return {
    mean,
    svg: `<svg class="lane-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">` +
      `<path d="${area}" fill="${color}" opacity="0.09"/>` +
      `<line x1="${x(pts[0][0]).toFixed(1)}" y1="${my}" x2="${x(pts[pts.length - 1][0]).toFixed(1)}" y2="${my}" stroke="${color}" stroke-width="0.6" stroke-dasharray="3 3" opacity="0.45"/>` +
      `<path d="${line}" fill="none" stroke="${color}" stroke-width="1.4" vector-effect="non-scaling-stroke"/></svg>`,
  };
}
// the point nearest `t` within `tol` seconds, else null
function nearestPoint(pts, t, tol) {
  let best = null;
  for (const p of pts) if (Math.abs(p[0] - t) <= tol && (!best || Math.abs(p[0] - t) < Math.abs(best[0] - t))) best = p;
  return best;
}

// horizontal stage-proportion bar (Deep/Light/REM/Awake)
function stageBar(n) {
  const bar = el("div", "stagebar");
  const parts = [["deep", n.deep_pct], ["light", n.light_pct], ["rem", n.rem_pct], ["wake", n.wake_pct]];
  bar.innerHTML = parts.map(([c, v]) => `<i class="sw-${c}" style="width:${Math.max(0, v || 0)}%" title="${Math.round(v || 0)}%"></i>`).join("");
  return bar;
}

// science-based read of the night → a few plain-language sentences + a sleep-debt note
function sleepInterpretation(d, n, m) {
  const wrap = el("div", "interp");
  const out = [];
  if (n.efficiency != null)
    out.push(n.efficiency >= 85 ? `Sleep efficiency of ${n.efficiency}% is solid — little time awake once down.`
      : n.efficiency >= 75 ? `Efficiency ${n.efficiency}% is fair; some fragmentation kept you from deeper rest.`
      : `Efficiency ${n.efficiency}% is low — a lot of the night in bed wasn't spent asleep.`);
  if (n.deep_pct != null)
    out.push(n.deep_pct < 10 ? `Deep sleep was scarce (${n.deep_pct}%) — the physically-restorative stage; low deep often follows late meals, alcohol, or stress.`
      : `Deep sleep ${n.deep_pct}% (target ~13–23%), the physically-restorative stage.`);
  if (n.rem_pct != null && m.rem_latency_min != null)
    out.push(`REM was ${n.rem_pct}% with first REM ${Math.round(m.rem_latency_min)} min after onset (a short REM latency can signal REM pressure or sleep debt).`);
  if (m.waso_min != null && m.awakenings != null)
    out.push(`You spent ${Math.round(m.waso_min)} min awake across ${m.awakenings} awakening${m.awakenings === 1 ? "" : "s"} after first falling asleep.`);
  out.forEach((t) => wrap.append(el("p", "interp-p", t)));
  const sd = d.sleep_debt;
  if (sd && sd.valid && sd.debt_min != null) {
    const h = Math.floor(sd.debt_min / 60), mm = Math.round(sd.debt_min % 60);
    const note = el("div", "interp-debt");
    note.innerHTML = `<div class="id-v">${h}h ${mm}m</div><div class="id-k">accumulated sleep debt vs an ${sd.need_h} h nightly need` +
      `${sd.recent_shortfall_min > 0 ? ` · last night ${Math.round(sd.recent_shortfall_min)} min short` : ""}</div>`;
    wrap.append(note);
  }
  return wrap;
}

// Sleep: stats, then the overnight lanes on the night's slice of the day axis — shown
// with or without a hypnogram (stages need Oura's SleepNet model; the signals don't) —
// then the stage-derived architecture and interpretation when stages exist.
function sleepSection(d, ymd, axis, cursor) {
  const sec = el("section", "rpt-sec");
  sec.id = "sec-sleep";
  sec.append(secHead("Sleep"));
  const n = nightForDay(d, ymd);
  if (!n) {
    sec.append(el("div", "ad-muted", "No sleep ended on this day in the ring's data."));
    return sec;
  }
  const m = n.metrics || {}, s = n.series || {};
  const staged = !!(n.stages_full && n.stages_full.length);
  const asleepH = m.asleep_min != null ? m.asleep_min / 60 : null;
  const strip = el("div", "stat-strip");
  strip.innerHTML =
    statTile("Time in bed", num(n.in_bed_h) + " h") +
    statTile("Asleep", asleepH != null ? asleepH.toFixed(1) + " h" : "—") +
    statTile("Efficiency", n.efficiency != null ? n.efficiency + "%" : "—") +
    statTile("Bedtime", `${n.start}–${n.end}`);
  sec.append(strip);
  if (staged) sec.append(stageLegend());
  else sec.append(el("p", "hr-note", "Sleep stages need Oura's sleep model, which isn't installed, so there's no hypnogram. The lanes below are what the ring recorded overnight."));

  const W = 1000, a = axis.frac(n.start_unix), b = axis.frac(n.end_unix);
  const rows = [];
  if (staged) {
    const st = n.stages_full;
    rows.push({
      label: "Stages", summary: "", height: 96, html: hypnoSvg(st, W, 92, [a, b]),
      valueAt: (t) => {
        const f = axis.frac(t);
        return f < a || f > b ? "—" : (STAGE[st[Math.round(((f - a) / Math.max(1e-9, b - a)) * (st.length - 1))]] || {}).name || "";
      },
    });
  }
  const timed = n.series_t; // real times; the flat `series` is only spread evenly
  const addLane = (key, label, unit, color, dp = 0, span = [0, 1]) => {
    if (timed) {
      const pts = timed[key] || [];
      const L = timedLaneSvg(pts, axis, W, 50, color);
      if (!L) return;
      const fmt = (x) => (dp ? x.toFixed(dp) : Math.round(x));
      rows.push({
        label, summary: `${fmt(L.mean)} ${unit}`, html: L.svg,
        valueAt: (t) => { const p = nearestPoint(pts, t, LANE_GAP_S / 2); return p ? `${fmt(p[1])} ${unit}` : "—"; },
      });
      return;
    }
    const v = (s[key] || []).filter((x) => x != null);
    const sa = a + span[0] * (b - a), sb = a + span[1] * (b - a);
    const L = laneSvg(v, W, 50, color, [sa, sb]);
    if (!L) return;
    const fmt = (x) => (dp ? x.toFixed(dp) : Math.round(x));
    rows.push({
      label, summary: `${fmt(L.mean)} ${unit}`, html: L.svg,
      valueAt: (t) => {
        const f = axis.frac(t);
        return f < sa || f > sb ? "—" : `${fmt(v[Math.round(((f - sa) / Math.max(1e-9, sb - sa)) * (v.length - 1))])} ${unit}`;
      },
    });
  };
  addLane("hr", "Heart rate", "bpm", "var(--warn)");
  addLane("hrv", "HRV", "ms", "var(--accent)");
  addLane("spo2", "Blood O₂", "%", "var(--rem)");
  addLane("temp", "Skin temp", "°C", "var(--light)", 1, s.temp_span || [0, 1]);
  addLane("motion", "Motion", "s", "var(--faint)");
  if (rows.length) sec.append(el("p", "subhead", "Overnight"), tlBox(axis, cursor, rows));
  if (!staged) return sec;

  // architecture + clinical metrics
  sec.append(el("p", "subhead", "Sleep architecture"), stageBar(n));
  const mg = el("div", "metric-grid");
  const mins = (x) => (x != null ? Math.round(x) + " min" : "—");
  const mc = (k, v) => `<div class="mc"><div class="mc-v">${v}</div><div class="mc-k">${k}</div></div>`;
  mg.innerHTML =
    mc("Sleep onset", mins(m.sol_min)) +
    mc("REM latency", mins(m.rem_latency_min)) +
    mc("Awake (WASO)", mins(m.waso_min)) +
    mc("Awakenings", m.awakenings != null ? m.awakenings : "—") +
    mc("Sleep cycles", m.cycles != null ? m.cycles : "—") +
    mc("Fragmentation", m.frag_index != null ? m.frag_index + " /h" : "—");
  sec.append(mg);

  // autonomic recovery resolved by sleep stage. Deep-sleep HRV is the recovery-relevant
  // number; we deliberately don't show a single overnight HRV "slope" — nocturnal HRV is
  // stage-driven (deep ↑, REM ↓), so a slope mostly tracks stage order, not recovery.
  const au = n.autonomic;
  if (au && [au.hrv_deep, au.hrv_light, au.hrv_rem, au.hr_deep, au.hr_light, au.hr_rem].some((x) => x != null)) {
    sec.append(el("p", "subhead", "Autonomic recovery by stage"));
    const at = el("div", "metric-grid");
    const val = (x, u) => (x != null ? x + u : "—");
    at.innerHTML =
      mc("HRV · Deep", val(au.hrv_deep, " ms")) +
      mc("HRV · Light", val(au.hrv_light, " ms")) +
      mc("HRV · REM", val(au.hrv_rem, " ms")) +
      mc("HR · Deep", val(au.hr_deep, " bpm")) +
      mc("HR · Light", val(au.hr_light, " bpm")) +
      mc("HR · REM", val(au.hr_rem, " bpm"));
    sec.append(at);
  }
  sec.append(el("p", "subhead", "Interpretation"), sleepInterpretation(d, n, m));
  return sec;
}

// 15-minute MET-above-rest buckets across the day's own 24 h, on the day axis
function movementSvg(prof, axis, w, h) {
  const p = (prof || []).map((x) => x || 0);
  if (p.length < 2) return "";
  const x0 = axis.frac(axis.dayStart) * w, peak = Math.max(1, ...p), pad = 6;
  const pts = p.map((v, i) => [x0 + ((i + 0.5) / p.length) * (w - x0), pad + (1 - Math.min(1, v / peak)) * (h - 2 * pad)]);
  const line = smoothPath(pts);
  const [first, last] = [pts[0][0].toFixed(1), pts[pts.length - 1][0].toFixed(1)];
  return `<svg class="lane-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">` +
    `<path d="${line} L${last} ${h} L${first} ${h} Z" fill="var(--accent)" opacity="0.14"/>` +
    `<path d="${line}" fill="none" stroke="var(--accent)" stroke-width="1.4" vector-effect="non-scaling-stroke"/></svg>`;
}

function activitySection(d, ymd, axis, cursor) {
  const sec = el("section", "rpt-sec");
  sec.id = "sec-activity";
  sec.append(secHead("Activity"));
  const ds = (d.activity_daily || {})[ymd];
  const prof = (d.activity_profile || {})[ymd] || [];
  const strip = el("div", "stat-strip");
  strip.innerHTML =
    statTile("Steps", ds ? Math.round(ds.steps || 0).toLocaleString() : "—") +
    statTile("Active energy", ds ? Math.round(ds.active_kcal || 0) + " kcal" : "—") +
    statTile("Total energy", ds ? Math.round(ds.total_kcal || 0) + " kcal" : "—") +
    (ds && ds.distance_m != null ? statTile("Distance", (ds.distance_m / 1000).toFixed(1) + " km") : "");
  sec.append(strip);

  const svg = movementSvg(prof, axis, 1000, 90);
  if (svg) {
    const p = prof.map((v) => v || 0), bucketS = 86400 / p.length;
    const at = (t) => {
      const i = Math.floor((t - axis.dayStart) / bucketS);
      return i >= 0 && i < p.length ? `${p[i].toFixed(1)} MET` : "—";
    };
    sec.append(el("p", "subhead", "Movement"),
      tlBox(axis, cursor, [{ label: "Movement", summary: `peak ${Math.max(...p).toFixed(1)}`, height: 90, html: svg, valueAt: at }]));
  }

  // intensity-derived metrics (buckets are 15-min MET-above-rest)
  const bucketMin = 24 * 60 / (prof.length || 96);
  const activeMin = prof.filter((v) => (v || 0) >= 3).length * bucketMin;
  const lightMin = prof.filter((v) => (v || 0) >= 1.5 && (v || 0) < 3).length * bucketMin;
  const peakMet = prof.length ? Math.max(...prof.map((v) => v || 0)) : 0;
  const sessions = sessionsForDay(d, ymd);
  const mg = el("div", "metric-grid");
  const mc = (k, v) => `<div class="mc"><div class="mc-v">${v}</div><div class="mc-k">${k}</div></div>`;
  mg.innerHTML =
    mc("Active", Math.round(activeMin) + " min") +
    mc("Lightly active", Math.round(lightMin) + " min") +
    mc("Peak intensity", peakMet.toFixed(1) + " MET") +
    mc("Sessions", sessions.length);
  sec.append(mg);

  sec.append(el("p", "subhead", "Sessions"));
  if (sessions.length) {
    const list = el("div", "dd-sessions");
    sessions.forEach((sess) => {
      const row = el("button", "dd-session" + (sess.is_workout >= 0.5 ? " workout" : ""));
      row.type = "button";
      const ico = el("span", "ic");
      ico.style.setProperty("--i", `url(/icons/${actIcon(sess.label)}.svg)`);
      const nm = el("span", "dd-s-name"); nm.textContent = sess.label || "activity";
      const meta = el("span", "dd-s-meta"); meta.textContent = `${sess.duration_min} min · ${hhmm(sess.start)}`;
      row.append(ico, nm, meta);
      row.addEventListener("click", () => openActDetail(sess));
      list.append(row);
    });
    sec.append(list);
  } else {
    sec.append(el("div", "ad-muted", "No sessions detected this day."));
  }
  return sec;
}

// ── heart rate across the day ────────────────────────────────
// Mirror of iOS `HeartRate.swift`, finer: one bar per slot spanning its 5th–95th
// percentile band with a tick at the median, from GET /api/hourly-hr?minutes=
// (oura-summary::hourly_hr::hr_bins). 15-minute slots by default, hourly on the
// switch. Slots built from few values are drawn lighter: while you sleep the ring
// keeps only 5-minute averages, three per quarter hour. Empty slots had no readings.
let HOURLY_HR = null; // last /api/hourly-hr response, for the day's JSON export
let HR_BIN_MIN = 15;
let HR_SEQ = 0;
const HR_FEW_VALUES = 10; // below this a band is a handful of values, not a spread

// One day's slots from an /api/hourly-hr response: `bySlot[i]` is slot i's row (or
// null), for the tab chart and the "Your day" strip alike.
function hrDaySlots(j, ymd) {
  const m = j.minutes || 60;
  const slotOf = (r) => Math.floor((r.hour * 60 + (r.minute || 0)) / m);
  const bySlot = new Array(1440 / m).fill(null);
  for (const r of j.bins || []) if (r.ymd === ymd) bySlot[slotOf(r)] = r;
  return { m, slotOf, bySlot, rows: bySlot.filter(Boolean) };
}

// The newest reading's bpm when it falls on `ymd` (local clock), else null.
function hrLatestOn(j, ymd) {
  if (!j.latest) return null;
  const at = new Date((j.latest.unix + (j.tz_offset || 0) * 3600) * 1000).toISOString().slice(0, 10);
  return at === ymd ? j.latest.bpm : null;
}

function hrBinsSvg(bySlot, lo, hi, w, h, withGrid = true) {
  const y = (v) => h - ((v - lo) / (hi - lo)) * h;
  const col = w / bySlot.length;
  const bw = col * (bySlot.length > 24 ? 0.6 : 0.5);
  let grid = "";
  for (let v = Math.ceil(lo / 20) * 20; withGrid && v <= hi; v += 20)
    grid += `<line class="hr-grid" x1="0" x2="${w}" y1="${y(v).toFixed(1)}" y2="${y(v).toFixed(1)}"/>`;
  let bars = "";
  bySlot.forEach((b, i) => {
    if (!b) return;
    const x = i * col + (col - bw) / 2, thin = b.count < HR_FEW_VALUES ? " thin" : "";
    bars += `<rect class="hr-bar${thin}" x="${x.toFixed(2)}" y="${y(b.high).toFixed(1)}" width="${bw.toFixed(2)}" ` +
      `height="${Math.max(2, y(b.low) - y(b.high)).toFixed(1)}"/>` +
      `<line class="hr-med${thin}" x1="${(x - col * 0.08).toFixed(2)}" x2="${(x + bw + col * 0.08).toFixed(2)}" ` +
      `y1="${y(b.median).toFixed(1)}" y2="${y(b.median).toFixed(1)}"/>`;
  });
  return `<svg class="hr-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">${grid}` +
    `<rect class="hr-hover" x="0" y="0" width="${col.toFixed(2)}" height="${h}" style="display:none"/>${bars}</svg>`;
}


// the slots of an /api/hourly-hr response placed by time on the day axis
function hrTimelineSvg(bins, axis, minutes, lo, hi, w, h) {
  const y = (v) => h - ((v - lo) / (hi - lo)) * h;
  const slotW = ((minutes * 60) / (axis.t1 - axis.t0)) * w, bw = slotW * (minutes < 60 ? 0.6 : 0.5);
  let grid = "";
  for (let v = Math.ceil(lo / 20) * 20; v <= hi; v += 20)
    grid += `<line class="hr-grid" x1="0" x2="${w}" y1="${y(v).toFixed(1)}" y2="${y(v).toFixed(1)}"/>`;
  let bars = "";
  for (const b of bins) {
    const x = axis.frac(b.unix) * w + (slotW - bw) / 2, thin = b.count < HR_FEW_VALUES ? " thin" : "";
    bars += `<rect class="hr-bar${thin}" x="${x.toFixed(2)}" y="${y(b.high).toFixed(1)}" width="${bw.toFixed(2)}" ` +
      `height="${Math.max(2, y(b.low) - y(b.high)).toFixed(1)}"/>` +
      `<line class="hr-med${thin}" x1="${(x - slotW * 0.08).toFixed(2)}" x2="${(x + bw + slotW * 0.08).toFixed(2)}" ` +
      `y1="${y(b.median).toFixed(1)}" y2="${y(b.median).toFixed(1)}"/>`;
  }
  return `<svg class="hr-svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">${grid}${bars}</svg>`;
}

function heartSection(ymd, axis, cursor) {
  const sec = el("section", "rpt-sec");
  sec.id = "sec-heart";
  const sw = el("div", "hr-bin");
  sec.append(secHead("Heart rate", sw));
  const strip = el("div", "stat-strip");
  const chart = el("div");
  const readout = el("p", "hr-readout", "&nbsp;");
  sec.append(strip, chart, readout,
    el("p", "hr-note", "Each bar spans that slot's typical range (5th–95th percentile of its values); the tick is the median. " +
      "Lighter bars are built from only a few values: while you sleep the ring stores 5-minute averages rather than beats. " +
      "Empty slots had no readings."));
  const load = () => {
    const seq = ++HR_SEQ; // a slower earlier response must not overwrite a newer one
    sw.querySelectorAll("button").forEach((b) => b.classList.toggle("on", +b.dataset.min === HR_BIN_MIN));
    chart.replaceChildren(el("div", "skeleton skeleton-block"));
    fetch(`/api/hourly-hr?minutes=${HR_BIN_MIN}`)
      .then((r) => r.json())
      .then((j) => {
        if (seq !== HR_SEQ) return;
        if (j.error) throw new Error(j.error);
        HOURLY_HR = j;
        renderHeart(j, ymd, axis, cursor, strip, chart, readout);
      })
      .catch((e) => {
        if (seq !== HR_SEQ) return;
        chart.replaceChildren(el("p", "hr-empty", "Couldn't load heart rate: " + esc(e.message)));
        readout.innerHTML = "&nbsp;";
      });
  };
  for (const [min, label] of [[15, "15 min"], [60, "1 h"]]) {
    const b = el("button", "", label);
    b.type = "button";
    b.dataset.min = min;
    b.addEventListener("click", () => { if (HR_BIN_MIN !== min) { HR_BIN_MIN = min; load(); } });
    sw.append(b);
  }
  load();
  return sec;
}

function renderHeart(j, ymd, axis, cursor, strip, chart, readout) {
  const span = (j.minutes || 60) * 60;
  const bins = (j.bins || []).filter((b) => b.unix >= axis.t0 && b.unix < axis.t1);
  const day = bins.filter((b) => b.ymd === ymd); // the stats cover the day itself
  if (!bins.length) {
    strip.innerHTML = "";
    chart.replaceChildren(el("p", "hr-empty", "No heart-rate readings for this day yet. Wear the ring and sync."));
    readout.innerHTML = "&nbsp;";
    cursor.onMove("heart", () => {});
    return;
  }
  const r0 = Math.round;
  const statRows = day.length ? day : bins;
  const low = Math.min(...statRows.map((r) => r.low)), high = Math.max(...statRows.map((r) => r.high));
  const calm = statRows.reduce((a, b) => (b.median < a.median ? b : a));
  const latest = hrLatestOn(j, ymd);
  strip.innerHTML =
    (latest != null ? statTile("Latest", `${r0(latest)} bpm`) : "") +
    statTile("Range", `${r0(low)}–${r0(high)} bpm`) +
    statTile(`Lowest · ${axis.clock(calm.unix)}`, `${r0(calm.median)} bpm`) +
    statTile("Hours measured", `${new Set(statRows.map((r) => `${r.ymd} ${r.hour}`)).size} of 24`);

  const allLow = Math.min(...bins.map((r) => r.low)), allHigh = Math.max(...bins.map((r) => r.high));
  const lo = Math.max(0, Math.floor(allLow / 10) * 10 - 10), hi = Math.ceil(allHigh / 10) * 10 + 10;
  const H = 140, rticks = [];
  for (let v = Math.ceil(lo / 20) * 20; v <= hi; v += 20)
    rticks.push(`<span style="top:${(((hi - v) / (hi - lo)) * 100).toFixed(1)}%">${v}</span>`);
  const sorted = statRows.map((r) => r.median).sort((a, b) => a - b);
  const at = (t) => bins.find((b) => t >= b.unix && t < b.unix + span);
  chart.replaceChildren(tlBox(axis, cursor, [{
    label: "Heart rate", summary: `${r0(sorted[Math.floor(sorted.length / 2)])} bpm`, height: H,
    html: hrTimelineSvg(bins, axis, span / 60, lo, hi, 1000, H), rticks: rticks.join(""),
    valueAt: (t) => { const b = at(t); return b ? `${r0(b.median)} bpm` : "—"; },
  }]));

  // the detailed slot line under the chart follows the page cursor from any chart
  const plural = (n, word) => `${n.toLocaleString()} ${word}${n === 1 ? "" : "s"}`;
  const madeOf = (b) => [b.beats ? plural(b.beats, "beat") : "", b.averages ? plural(b.averages, "five-minute average") : ""]
    .filter(Boolean).join(" + ");
  const idle = "Move over any chart to see that moment across sleep, activity and heart rate.";
  readout.textContent = idle;
  cursor.onMove("heart", (t) => {
    if (t == null) { readout.textContent = idle; return; }
    const b = at(t), s0 = b ? b.unix : Math.floor(t / span) * span;
    readout.textContent = `${axis.clock(s0)}–${axis.clock(s0 + span)} · ` + (!b ? "no readings" : b.beats
      ? `median ${r0(b.median)} bpm · typical ${r0(b.low)}–${r0(b.high)} · min ${r0(b.min)} · max ${r0(b.max)} · ${madeOf(b)}`
      : `median ${r0(b.median)} bpm · range ${r0(b.min)}–${r0(b.max)} · ${madeOf(b)}`);
  });
}

// the "previous days" page: every day as a row (date, mini-hypnogram, totals) that
// opens its full-page report. Uses its own dialog id.
function openDaysBrowser(d, days) {
  let dlg = $("days-dialog");
  if (!dlg) {
    dlg = el("dialog", "dialog day-dialog");
    dlg.id = "days-dialog";
    dlg.addEventListener("click", (e) => { if (e.target === dlg) dlg.close(); });
    document.body.append(dlg);
  }
  const form = el("form");
  form.method = "dialog";
  const head = el("div", "dd-head");
  const h = el("h3");
  h.textContent = `All ${days.length} days`;
  const close = el("button", "dd-close", "✕");
  close.type = "button";
  close.setAttribute("aria-label", "Close");
  close.addEventListener("click", () => dlg.close());
  head.append(h, close);
  form.append(head);

  const list = el("div", "daylist");
  days.forEach((ymd) => {
    const n = nightForDay(d, ymd);
    const ds = (d.activity_daily || {})[ymd];
    const row = el("button", "daylist-row");
    row.type = "button";
    const left = el("div", "dl-left");
    left.append(el("div", "dl-date", dayTitle(ymd)));
    left.append(el("div", "dl-sub", ds ? `${kfmt(ds.steps)} steps · ${Math.round(ds.active_kcal)} kcal` : (n ? "sleep only" : "—")));
    row.append(left);
    if (n && n.stages && n.stages.length) {
      const hyp = hypnogram(n.stages);
      hyp.classList.add("dl-hyp");
      row.append(hyp);
    }
    row.append(el("span", "dp-chev"));
    row.addEventListener("click", () => { dlg.close(); openDayPage(d, ymd, "sleep"); });
    list.append(row);
  });
  form.append(list);
  dlg.replaceChildren(form);
  dlg.showModal();
}

// capability → glyph (mix of vendored phosphor + hugeicons)
const CAP_ICON = {
  "Daytime HR": "heartbeat", "SpO2": "wind", "Exercise HR": "person-simple-run",
  "Real steps": "act-walking", "Cardio PPG (CVA)": "heartbeat",
};
const capIcon = (name) => CAP_ICON[name] || "cpu";

async function doFeature(feature, name, currentOn, row) {
  if (row.classList.contains("busy")) return;
  const turnOn = !currentOn;
  row.classList.add("busy");
  row.classList.toggle("on", turnOn); // optimistic
  try {
    const j = await (await postDash("/api/feature", { feature, mode: turnOn ? "automatic" : "off" })).json();
    if (j.ok) {
      toast(`${name} turned ${turnOn ? "on" : "off"}. Wear the ring; data appears on the next sync.`, "ok");
      load(); // refresh dev.measuring so a second tap toggles from the real state
    } else {
      toast(syncHint(j.message), "error");
      row.classList.toggle("on", currentOn); // revert
    }
  } catch (e) {
    toast("Couldn't reach the local server.", "error");
    row.classList.toggle("on", currentOn);
  }
  row.classList.remove("busy");
}

function renderDevice(d) {
  const box = $("device");
  const dev = d.device || {};
  box.innerHTML = "";

  const stats = el("div", "dh-stats");
  const stat = (k, v, u) => el("div", "dh-stat", `<div class="k">${k}</div><div class="v">${v}<span class="u">${u || ""}</span></div>`);
  const bpct = dev.battery_pct;
  const bstat = stat("Battery", bpct != null ? bpct : "—", "%");
  if (bpct != null && bpct < 20) bstat.classList.add("low");
  stats.append(bstat);
  const fresh = dev.fresh_hours != null ? (dev.fresh_hours < 1 ? "<1" : Math.round(dev.fresh_hours)) : "—";
  stats.append(stat("Last sync", fresh, " h ago"));
  stats.append(stat("History", num(dev.days_of_data), " days"));
  stats.append(stat("Events", (dev.total_events || 0).toLocaleString()));
  box.append(stats);

  // left = data streams (what the ring is recording)
  const left = el("div");
  const streams = dev.streams || [];
  if (streams.length) {
    left.append(el("p", "subhead", "Data captured"));
    const max = Math.max(...streams.map((s) => s.count), 1);
    const sc = el("div", "streams");
    streams.forEach((s) => {
      const row = el("div", "stream");
      const nm = el("span", "s-name");
      nm.textContent = s.name;
      const bar = el("span", "s-bar");
      const fill = el("i");
      fill.style.width = Math.max(3, (s.count / max) * 100) + "%";
      bar.append(fill);
      const val = el("span", "s-val");
      val.textContent = s.count.toLocaleString();
      row.append(nm, bar, val);
      sc.append(row);
    });
    left.append(sc);
  }
  box.append(left);

  // right = insights
  const right = el("div");
  right.append(el("p", "subhead", "Insights available"));
  const ins = el("div", "insights");
  (dev.insights || []).forEach((i) => {
    const row = el("div", "insight");
    row.append(el("div", null, `${i.name}${i.status === "gated" && i.why ? `<span class="why"> · ${i.why}</span>` : ""}`));
    const st = el("span", "status " + i.status);
    st.innerHTML = `<i></i>${i.status}`;
    row.append(st);
    ins.append(row);
  });
  right.append(ins);
  box.append(right);

  // ── advanced / debugging (collapsed by default) ──────────────────────────
  const adv = el("details", "dh-advanced");
  const sum = el("summary");
  sum.innerHTML = `<span class="ic" style="--i:url(/icons/cpu.svg)"></span>Advanced &amp; debugging<span class="chev"></span>`;
  adv.append(sum);
  const ab = el("div", "adv-body");

  // device identity + sync internals
  ab.append(el("p", "subhead", "Device"));
  const kv = el("div", "adv-kv");
  const kvItem = (k, v) => `<div><i>${k}</i><b>${v}</b></div>`;
  kv.innerHTML =
    kvItem("Ring ID", esc(dev.serial || "—")) +
    kvItem("Firmware", esc(dev.firmware || "—")) +
    kvItem("API", esc(dev.api_version || "—")) +
    kvItem("MAC", esc(dev.mac || "—")) +
    kvItem("Hardware", esc(dev.hardware_id || "—")) +
    kvItem("Battery", dev.battery_v != null ? dev.battery_v + " V" : "—") +
    kvItem("Last sync", `${esc(dev.synced || "—")} ${esc(dev.synced_hm || "")}`) +
    kvItem("Sync cursor", dev.next_cursor != null ? dev.next_cursor.toLocaleString() : "—") +
    kvItem("History", `${num(dev.days_of_data)} days`);
  ab.append(kv);

  // local auth key portability
  ab.append(el("p", "subhead", "Ring auth key"));
  const keyTools = el("div", "key-tools");
  const exportBtn = el("button", "btn-text key-btn", "Export / QR");
  exportBtn.type = "button";
  exportBtn.title = "Show copy, download, and QR options for the local ring auth key.";
  exportBtn.addEventListener("click", exportRingKey);
  const importBtn = el("button", "btn-text key-btn", "Import / scan");
  importBtn.type = "button";
  importBtn.title = "Paste, upload, or scan a ring auth key.";
  importBtn.addEventListener("click", openImportKeyDialog);
  keyTools.append(exportBtn, importBtn);
  ab.append(keyTools);

  // capability toggles
  ab.append(el("p", "subhead", "Capabilities · tap to toggle"));
  const caps = el("div", "caps");
  (dev.measuring || []).forEach((m) => {
    const row = el("div", "cap" + (m.on ? " on" : ""));
    const ic = el("span", "ic");
    ic.style.setProperty("--i", `url(/icons/${capIcon(m.name)}.svg)`);
    const nm = el("span", "cap-name");
    nm.textContent = m.name;
    const sw = el("span", "switch", "<i></i>");
    row.append(ic, nm, sw);
    if (m.feature) {
      row.classList.add("interactive");
      row.title = `Tap to turn ${m.on ? "off" : "on"} (connects to the ring)`;
      row.addEventListener("click", () => doFeature(m.feature, m.name, m.on, row));
    }
    caps.append(row);
  });
  ab.append(caps);

  const ev = dev.event_counts || [];
  if (ev.length) {
    ab.append(el("p", "subhead", `Event stream · ${ev.length} types`));
    const emax = Math.max(...ev.map((e) => e.count), 1);
    const tbl = el("div", "ev-table");
    ev.forEach((e) => {
      const row = el("div", "ev-row");
      const nm = el("span", "ev-n");
      nm.textContent = e.name;
      const bar = el("span", "ev-bar");
      const fi = el("i");
      fi.style.width = Math.max(2, (e.count / emax) * 100) + "%";
      bar.append(fi);
      const c = el("span", "ev-c");
      c.textContent = e.count.toLocaleString();
      row.append(nm, bar, c);
      tbl.append(row);
    });
    ab.append(tbl);
  }
  adv.append(ab);
  box.append(adv);
}

function ringKeyFilename() {
  const serial = (LAST_DEVICE_SERIAL || "oura-ring").replace(/[^A-Za-z0-9_.-]+/g, "-");
  return `${serial}.key`;
}

async function exportRingKey() {
  try {
    const j = await fetchRingKey();
    if (!j) return;
    if (!j.ok) {
      toast(j.message || "No key file is configured. Start the dashboard with --key-file.", "error");
      return;
    }
    openExportKeyDialog(j.key);
  } catch {
    toast("Couldn't export the ring auth key.", "error");
  }
}

async function fetchRingKey() {
  const r = await getDash("/api/ring-key");
  if (!r.ok) {
    toast("Restart the dashboard server to enable key export.", "error");
    return null;
  }
  return await r.json();
}

async function copyText(text, ok = "Copied.") {
  try {
    await navigator.clipboard.writeText(text);
    toast(ok, "ok");
  } catch {
    toast("Couldn't write to the clipboard.", "error");
  }
}

function downloadRingKey(key) {
  const blob = new Blob([key + "\n"], { type: "text/plain" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = ringKeyFilename();
  document.body.append(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(a.href);
  toast("Ring auth key downloaded.", "ok");
}

function openExportKeyDialog(key) {
  let dlg = $("key-export-dialog");
  if (!dlg) {
    dlg = el("dialog", "dialog key-dialog");
    dlg.id = "key-export-dialog";
    dlg.addEventListener("click", (e) => { if (e.target === dlg) dlg.close(); });
    document.body.append(dlg);
  }
  dlg.innerHTML = `
    <form method="dialog">
      <h3>Ring auth key</h3>
      <p class="dialog-sub">Use this on another computer running open_oura with the same ring.</p>
      <div class="qr-wrap"><canvas id="key-qr" width="232" height="232" aria-label="Ring auth key QR code"></canvas></div>
      <input id="key-export-value" class="key-field" readonly value="${esc(key)}" />
      <div class="dialog-actions key-actions">
        <button type="button" id="key-copy" class="btn-primary">Copy</button>
        <button type="button" id="key-download" class="btn-text">Download</button>
        <button class="btn-text">Close</button>
      </div>
    </form>`;
  dlg.querySelector("#key-copy").addEventListener("click", () => copyText(key, "Ring auth key copied."));
  dlg.querySelector("#key-download").addEventListener("click", () => downloadRingKey(key));
  dlg.showModal();
  drawQr($("key-qr"), key.toUpperCase());
}

function openImportKeyDialog() {
  let dlg = $("key-import-dialog");
  if (!dlg) {
    dlg = el("dialog", "dialog key-dialog");
    dlg.id = "key-import-dialog";
    dlg.addEventListener("click", (e) => { if (e.target === dlg) closeImportKeyDialog(); });
    document.body.append(dlg);
  }
  const canScan = "BarcodeDetector" in window && navigator.mediaDevices && navigator.mediaDevices.getUserMedia;
  dlg.innerHTML = `
    <form method="dialog">
      <h3>Import ring key</h3>
      <p class="dialog-sub">Paste a 32-character hex key, upload a .key file, or scan the export QR code.</p>
      <textarea id="key-import-value" class="key-field key-textarea" spellcheck="false" autocomplete="off" placeholder="32 hex characters"></textarea>
      <video id="key-scan-video" class="key-video" playsinline muted hidden></video>
      <div class="dialog-actions key-actions">
        <button type="button" id="key-import-save" class="btn-primary">Import</button>
        <button type="button" id="key-import-file" class="btn-text">File</button>
        <button type="button" id="key-import-scan" class="btn-text"${canScan ? "" : " disabled"}>Scan</button>
        <button type="button" id="key-import-close" class="btn-text">Close</button>
      </div>
      <input id="key-import-file-input" class="key-input" type="file" accept=".key,text/plain" />
    </form>`;
  dlg.querySelector("#key-import-save").addEventListener("click", () => importRingKeyText($("key-import-value").value));
  dlg.querySelector("#key-import-file").addEventListener("click", () => $("key-import-file-input").click());
  dlg.querySelector("#key-import-file-input").addEventListener("change", (e) => importRingKeyFile(e.target));
  dlg.querySelector("#key-import-scan").addEventListener("click", startKeyScan);
  dlg.querySelector("#key-import-close").addEventListener("click", closeImportKeyDialog);
  dlg.showModal();
}

function closeImportKeyDialog() {
  stopKeyScan();
  const dlg = $("key-import-dialog");
  if (dlg) dlg.close();
}

let KEY_SCAN_STREAM = null;
let KEY_SCAN_STOP = false;

async function startKeyScan() {
  try {
    const video = $("key-scan-video");
    const detector = new BarcodeDetector({ formats: ["qr_code"] });
    KEY_SCAN_STOP = false;
    KEY_SCAN_STREAM = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
    video.srcObject = KEY_SCAN_STREAM;
    video.hidden = false;
    await video.play();
    const scan = async () => {
      if (KEY_SCAN_STOP) return;
      const codes = await detector.detect(video).catch(() => []);
      const raw = codes[0] && codes[0].rawValue;
      if (raw) {
        $("key-import-value").value = raw.trim();
        stopKeyScan();
        toast("QR code scanned.", "ok");
        return;
      }
      requestAnimationFrame(scan);
    };
    scan();
  } catch {
    toast("Camera QR scan is not available in this browser.", "error");
    stopKeyScan();
  }
}

function stopKeyScan() {
  KEY_SCAN_STOP = true;
  if (KEY_SCAN_STREAM) KEY_SCAN_STREAM.getTracks().forEach((t) => t.stop());
  KEY_SCAN_STREAM = null;
  const video = $("key-scan-video");
  if (video) {
    video.pause();
    video.srcObject = null;
    video.hidden = true;
  }
}

async function importRingKeyFile(input) {
  const file = input.files && input.files[0];
  input.value = "";
  if (!file) return;
  try {
    await importRingKeyText(await file.text());
  } catch {
    toast("Couldn't read that key file.", "error");
  }
}

async function importRingKeyText(text) {
  const key = (text || "").trim();
  if (!/^[0-9a-fA-F]{32}$/.test(key)) {
    toast("Auth key must be exactly 32 hex characters.", "error");
    return;
  }
  try {
    const j = await (await postDash("/api/ring-key", { key })).json();
    if (j.ok) {
      closeImportKeyDialog();
      toast("Ring auth key imported.", "ok");
    }
    else toast(j.message || "Couldn't import the ring auth key.", "error");
  } catch {
    toast("Couldn't reach the local dashboard server.", "error");
  }
}

// Fixed QR Code version 2-L generator, enough for this 32-char hex key.
function drawQr(canvas, text) {
  const n = 25, modules = Array.from({ length: n }, () => Array(n).fill(false));
  const reserved = Array.from({ length: n }, () => Array(n).fill(false));
  const set = (x, y, v, r = true) => { if (x >= 0 && y >= 0 && x < n && y < n) { modules[y][x] = v; if (r) reserved[y][x] = true; } };
  const finder = (x, y) => {
    for (let dy = -1; dy <= 7; dy++) for (let dx = -1; dx <= 7; dx++) {
      const xx = x + dx, yy = y + dy;
      const on = dx >= 0 && dy >= 0 && dx <= 6 && dy <= 6 && (dx === 0 || dy === 0 || dx === 6 || dy === 6 || (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4));
      set(xx, yy, on);
    }
  };
  finder(0, 0); finder(n - 7, 0); finder(0, n - 7);
  for (let i = 8; i < n - 8; i++) { set(i, 6, i % 2 === 0); set(6, i, i % 2 === 0); }
  for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(18 + dx, 18 + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  set(8, n - 8, true);
  reserveFormatAreas(reserved);
  const data = qrDataCodewords(text), ecc = qrRs(data, 10), bits = [];
  data.concat(ecc).forEach((b) => { for (let i = 7; i >= 0; i--) bits.push(((b >>> i) & 1) === 1); });
  let k = 0, up = true;
  for (let x = n - 1; x > 0; x -= 2) {
    if (x === 6) x--;
    for (let yy = 0; yy < n; yy++) {
      const y = up ? n - 1 - yy : yy;
      for (let dx = 0; dx < 2; dx++) {
        const xx = x - dx;
        if (reserved[y][xx]) continue;
        let bit = bits[k++] || false;
        if ((xx + y) % 2 === 0) bit = !bit;
        set(xx, y, bit, false);
      }
    }
    up = !up;
  }
  placeFormat(modules, reserved, 1, 0);
  const ctx = canvas.getContext("2d"), scale = Math.floor(canvas.width / (n + 8)), off = Math.floor((canvas.width - n * scale) / 2);
  ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.fillStyle = "#111";
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (modules[y][x]) ctx.fillRect(off + x * scale, off + y * scale, scale, scale);
}

function reserveFormatAreas(reserved) {
  const n = reserved.length;
  for (let i = 0; i <= 5; i++) reserved[i][8] = true;
  reserved[7][8] = true; reserved[8][8] = true; reserved[8][7] = true;
  for (let i = 9; i < 15; i++) reserved[8][14 - i] = true;
  for (let i = 0; i < 8; i++) reserved[8][n - 1 - i] = true;
  for (let i = 8; i < 15; i++) reserved[n - 1 - (14 - i)][8] = true;
}

function qrDataCodewords(text) {
  const alpha = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";
  const bits = [];
  const push = (v, n) => { for (let i = n - 1; i >= 0; i--) bits.push((v >>> i) & 1); };
  push(2, 4); push(text.length, 9);
  for (let i = 0; i < text.length; i += 2) {
    const a = alpha.indexOf(text[i]), b = alpha.indexOf(text[i + 1]);
    if (b >= 0) push(a * 45 + b, 11); else push(a, 6);
  }
  push(0, Math.min(4, 272 - bits.length));
  while (bits.length % 8) bits.push(0);
  const out = [];
  for (let i = 0; i < bits.length; i += 8) out.push(bits.slice(i, i + 8).reduce((a, b) => (a << 1) | b, 0));
  for (let p = 0; out.length < 34; p++) out.push(p % 2 ? 0x11 : 0xec);
  return out;
}

function qrRs(data, count) {
  const mul = (x, y) => { let z = 0; for (; y; y >>>= 1) { if (y & 1) z ^= x; x = (x << 1) ^ (x & 0x80 ? 0x11d : 0); } return z & 255; };
  let gen = [1];
  for (let i = 0, root = 1; i < count; i++, root = mul(root, 2)) {
    const next = Array(gen.length + 1).fill(0);
    gen.forEach((c, j) => { next[j] ^= mul(c, root); next[j + 1] ^= c; });
    gen = next;
  }
  const rem = Array(count).fill(0);
  data.forEach((b) => {
    const factor = b ^ rem.shift();
    rem.push(0);
    gen.slice(0, count).forEach((c, i) => { rem[i] ^= mul(c, factor); });
  });
  return rem;
}

function placeFormat(modules, reserved, ecl, mask) {
  let data = (ecl << 3) | mask, rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  const bits = ((data << 10) | rem) ^ 0x5412;
  const set = (x, y, i) => { modules[y][x] = ((bits >>> i) & 1) === 1; reserved[y][x] = true; };
  for (let i = 0; i <= 5; i++) set(8, i, i);
  set(8, 7, 6); set(8, 8, 7); set(7, 8, 8);
  for (let i = 9; i < 15; i++) set(14 - i, 8, i);
  for (let i = 0; i < 8; i++) set(24 - i, 8, i);
  for (let i = 8; i < 15; i++) set(8, 24 - (14 - i), i);
}

function renderActions(d) {
  const dev = d.device || {};
  const b = $("batt");
  if (dev.battery_pct != null) {
    b.innerHTML = icon("battery-high") + `<span>${dev.battery_pct}%</span>`;
    b.classList.toggle("low", dev.battery_pct < 20);
    b.hidden = false;
    b.title = `Ring battery ${dev.battery_pct}%${dev.battery_v ? " · " + dev.battery_v + " V" : ""}`;
  } else {
    b.hidden = true;
  }
  $("foot-meta").textContent = `${dev.nights || 0} nights · ${(dev.total_events || 0).toLocaleString()} events`;
}

// ── profile dialog ──────────────────────────────────────────
function openProfile() {
  const p = CURRENT_PROFILE || {};
  $("f-sex").value = p.sex || "M";
  $("f-age").value = p.age ?? 30;
  $("f-height").value = p.height_m ?? 1.78;
  $("f-weight").value = p.weight_kg ?? 75;
  $("profile-dialog").showModal();
}
async function saveProfile(e) {
  e.preventDefault();
  const body = {
    sex: $("f-sex").value,
    age: +$("f-age").value,
    height_m: +$("f-height").value,
    weight_kg: +$("f-weight").value,
    ring_size: (CURRENT_PROFILE && CURRENT_PROFILE.ring_size) || 10, // not on the ring; kept default
  };
  $("profile-save").disabled = true;
  try {
    const r = await postDash("/api/profile", body);
    const j = await r.json().catch(() => ({}));
    // the server replies 200 with an { error } body on write failures — surface it
    // and keep the dialog open instead of pretending the save succeeded.
    if (!r.ok || j.error) {
      toast(j.error || "Couldn't save profile.", "error");
      return;
    }
    $("profile-dialog").close();
    await load(); // re-runs CVA with the new demographics
  } catch {
    toast("Couldn't reach the local server.", "error");
  } finally {
    $("profile-save").disabled = false;
  }
}

// ── sync ────────────────────────────────────────────────────
function toast(msg, kind = "info") {
  let t = $("toast");
  if (!t) { t = el("div", "toast"); t.id = "toast"; document.body.append(t); }
  t.className = "toast " + kind;
  // status dot + message (textContent on the span keeps the message injection-safe)
  const dot = el("span", "toast-dot");
  const text = el("span", "toast-msg");
  text.textContent = msg;
  t.replaceChildren(dot, text);
  requestAnimationFrame(() => t.classList.add("show"));
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.remove("show"), kind === "error" ? 8000 : 3800);
}

// turn a backend sync error into something actionable
function syncHint(msg) {
  msg = msg || "";
  if (/no matching|not found|no device|no ring/i.test(msg))
    return "Couldn't find your ring. Take it off the charger, keep it nearby, and try again.";
  if (/key|auth|unauthor/i.test(msg))
    return "The ring needs its auth key. Start the dashboard with --key-file.";
  if (/timed out|timeout/i.test(msg))
    return "Bluetooth timed out. Make sure the ring is awake and close, then retry.";
  return "Sync failed: " + msg;
}

async function doSync() {
  const btn = $("sync-btn");
  if (btn.classList.contains("syncing")) return;
  btn.classList.add("syncing");
  $("sync-label").textContent = "Syncing";
  btn.title = "Connecting to the ring over Bluetooth…";
  try {
    const j = await (await postDash("/api/sync")).json();
    if (j.ok) {
      $("sync-label").textContent = "Synced";
      toast(j.message && !/^synced$/i.test(j.message) ? j.message : "Ring synced.", "ok");
      await load();
    } else {
      $("sync-label").textContent = "Failed";
      toast(syncHint(j.message), "error");
    }
  } catch (e) {
    $("sync-label").textContent = "Failed";
    toast("Couldn't reach the local dashboard server.", "error");
  }
  btn.classList.remove("syncing");
  setTimeout(() => { $("sync-label").textContent = "Sync"; btn.title = "Sync the ring over Bluetooth"; }, 3000);
}

// ── live heart rate ─────────────────────────────────────────
// POST /api/live-hr streams newline-delimited JSON while the ring is connected:
// {"status":"live"}, then {"bpm":..,"ibi_ms":..} per beat, then {"done":true} or
// {"error":".."}. Aborting the request (Stop) ends the session on the server.
let LIVE_ABORT = null;

function liveHint(msg) {
  msg = msg || "";
  if (/no matching|not found|no device|no ring/i.test(msg))
    return "Couldn't find your ring. Keep it on your finger, close to the Mac, and try again.";
  if (/key|auth|unauthor/i.test(msg))
    return "The ring needs its auth key. Start the dashboard with --key-file.";
  return "Live heart rate failed: " + msg;
}

function liveSummary(beats) {
  if (!beats.length) return "No beats captured. Make sure the ring is on your finger.";
  const avg = Math.round(beats.reduce((a, b) => a + b, 0) / beats.length);
  return `${beats.length} beats · avg ${avg} · min ${Math.min(...beats)} · max ${Math.max(...beats)} bpm`;
}

async function toggleLive() {
  if (LIVE_ABORT) { LIVE_ABORT.abort(); return; }
  const abort = (LIVE_ABORT = new AbortController());
  const beats = [];
  const status = $("live-status");
  $("live-btn").classList.add("live-on");
  $("live-label").textContent = "Stop";
  $("live-bpm").textContent = "—";
  $("live-spark").innerHTML = "";
  status.textContent = "Connecting to the ring… keep your hand near the Mac (up to 2 min).";
  let end = null;
  try {
    const r = await fetch("/api/live-hr", { method: "POST", headers: { ...DASH_HEADERS }, signal: abort.signal });
    if (!r.ok || !r.body) throw new Error("HTTP " + r.status);
    const reader = r.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (!line.trim()) continue;
        const m = JSON.parse(line);
        if (m.status === "live") status.textContent = "Live. Beats appear as the ring detects them.";
        else if (m.bpm != null) {
          beats.push(m.bpm);
          $("live-bpm").textContent = m.bpm;
          $("live-spark").innerHTML = sparkline(beats.slice(-60));
          status.textContent = liveSummary(beats);
          const dot = $("live-dot");
          dot.classList.remove("beat");
          void dot.offsetWidth; // restart the pulse animation
          dot.classList.add("beat");
        } else if (m.error) end = liveHint(m.error);
        else if (m.done) end = beats.length ? "Done. " + liveSummary(beats) : liveSummary(beats);
      }
    }
  } catch (e) {
    if (e.name === "AbortError") end = beats.length ? "Stopped. " + liveSummary(beats) : "Stopped.";
    else end = "Couldn't reach the local dashboard server.";
  }
  status.textContent = end || liveSummary(beats);
  LIVE_ABORT = null;
  $("live-btn").classList.remove("live-on");
  $("live-label").textContent = "Start";
}

// ── load ────────────────────────────────────────────────────
// show the error in the headline and stop every panel's loading shimmer, so the
// page reads as "errored" rather than stuck mid-load.
function showLoadError(msg) {
  document.querySelectorAll(".skeleton").forEach((el) => {
    if (el.id === "digest") return; // handled below — keep it for the message
    el.remove();
  });
  const dg = $("digest");
  dg.classList.remove("skeleton", "skeleton-text");
  dg.classList.add("reveal");
  dg.textContent = msg;
}

let LOAD_SEQ = 0;
async function load() {
  // guard against overlapping loads (sync/profile-save during an in-flight build):
  // a slower earlier response must not overwrite a newer one.
  const seq = ++LOAD_SEQ;
  let d;
  try {
    d = await (await fetch("/api/summary")).json();
  } catch (e) {
    if (seq === LOAD_SEQ) showLoadError("Could not reach the local server.");
    return;
  }
  if (seq !== LOAD_SEQ) return; // a newer load() superseded this response — drop it
  if (d.error) {
    showLoadError(d.error);
    return;
  }
  CURRENT_PROFILE = d.profile || null;
  LAST_DEVICE_SERIAL = d.device && d.device.serial;
  $("digest").classList.remove("skeleton", "skeleton-text");
  $("digest").classList.add("reveal");
  $("digest").innerHTML = (d.digest || "").replace(/([+-]?\d[\d.]*\s?(?:%|bpm|ms|m\/s))/g, '<span class="metric">$1</span>');
  renderActions(d);
  renderTiles(d);
  renderDay(d);
  renderSleepDebt(d);
  renderIllness(d);
  renderCardio(d);
  renderSpo2(d);
  renderDevice(d);
  document.querySelectorAll(".panel").forEach((p, i) => {
    p.classList.add("reveal");
    p.style.setProperty("--d", i * 60 + "ms");
  });
}

$("sync-btn").addEventListener("click", doSync);
$("live-btn").addEventListener("click", toggleLive);
$("profile-btn").addEventListener("click", openProfile);
$("profile-form").addEventListener("submit", saveProfile);
$("profile-cancel").addEventListener("click", () => $("profile-dialog").close());
load();
