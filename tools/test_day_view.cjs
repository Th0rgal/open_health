// DOM integration check: npm install --prefix /tmp/oura-dom-check jsdom@26
// NODE_PATH=/tmp/oura-dom-check/node_modules node tools/test_day_view.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { JSDOM } = require('jsdom');
const dom = new JSDOM(fs.readFileSync('dashboard/web/index.html', 'utf8'), {
  url: 'http://localhost:8090', runScripts: 'outside-only',
});
const w = dom.window;
w.HTMLElement.prototype.scrollIntoView = function () {};
w.TextDecoder = TextDecoder;
const requests = [];
w.fetch = async url => {
  requests.push(url);
  return { ok: true, json: async () => ({ minutes: 15, bins: [], latest: null }) };
};
w.eval(fs.readFileSync('dashboard/web/app.js', 'utf8').replace(/load\(\);\s*$/, '') + '\nwindow.openDayPage = openDayPage; window.toggleLive = toggleLive; window.renderStagerChoice = renderStagerChoice; window.setStager = (s) => { CURRENT_STAGER = s; };');
const start = Date.UTC(2026, 8, 25, 22) / 1000;
const night = { ymd: '2026-09-25', wake_ymd: '2026-09-26', start_unix: start,
  end_unix: start + 8 * 3600, start: '22:00', end: '06:00', in_bed_h: 8,
  stages_full: [2, 0, 4], staging_complete: false, metrics: {},
  series_t: { motion: [[start + 60, 2]], hr: [[start, 60], [start + 300, 62]] }, series: {} };
const data = { tz: 5.75, nights: [night], activity_daily: {}, activity_profile: {}, activity: [] };
w.openDayPage(data, '2026-09-26');
assert(w.document.querySelector('#sec-sleep'));
assert(w.document.querySelector('#sec-activity'));
assert(w.document.querySelector('#sec-heart'));
assert(w.document.querySelector('#sec-sleep').textContent.includes('Incomplete sleep analysis'));
assert(!w.document.querySelector('#sec-sleep').textContent.includes('Efficiency of'));
const motion = [...w.document.querySelectorAll('.tl-row')].find(row => row.textContent.includes('Motion'));
// A sparse motion measurement must remain visible and must not become a smooth curve.
assert(motion, 'motion lane missing');
assert(!motion.querySelector('path'));
// An NSSA night also gets the official app's 5-minute chart, laid from its first epoch.
const nssa = { ...data, nights: [{ ...night, stages_full: new Array(40).fill(2), staging_complete: true,
  staging_source: 'nssa', stages_5min: [4, 2, 1, 3], stages_t0_unix: start - 20 }] };
w.openDayPage(nssa, '2026-09-26');
const lanes = [...w.document.querySelectorAll('.tl-row')].map(row => row.textContent);
assert(lanes.some(t => t.includes('Stages · 5 min (Oura app)')), '5-minute Oura lane missing');
assert(lanes.some(t => t.includes('Stages') && !t.includes('5 min')), '30 s stage lane missing');
// Any stager gets the 5-minute lane; only NSSA carries the Oura app label.
const builtIn = { ...data, nights: [{ ...night, stages_full: new Array(40).fill(2), staging_complete: true,
  staging_source: 'xgb', stages_5min: [4, 2, 1, 3] }] };
w.openDayPage(builtIn, night.wake_ymd);
const builtInLanes = [...w.document.querySelectorAll('.tl-row')].map(row => row.textContent);
assert(builtInLanes.some(t => t.includes('Stages · 5 min') && !t.includes('Oura app')), '5-minute lane missing for the built-in stager');
// The sleep stager selector disables an option whose model files are missing and shows its notice.
const stager = (official) => ({ choice: 'auto', effective: official ? 'official' : 'xgb', notice: null, options: [
  { id: 'official', label: 'Official staging', detail: 'official detail', available: official,
    notice: official ? null : 'Not available in this build. Missing: sleepstaging_2_6_0_classifier.bin.' },
  { id: 'xgb', label: 'Built-in staging', detail: 'built-in detail', available: true, notice: null }] });
w.setStager(stager(false));
w.renderStagerChoice();
const choice = w.document.getElementById('f-stager');
const options = [...choice.options].map(o => [o.value, o.disabled]);
assert.deepEqual(options, [['auto', false], ['official', true], ['xgb', false]]);
assert(w.document.getElementById('f-stager-note').textContent.includes('sleepstaging_2_6_0_classifier.bin'));
w.setStager(stager(true));
w.renderStagerChoice();
assert(![...w.document.getElementById('f-stager').options].some(o => o.disabled));
assert(!w.document.getElementById('f-stager-note').textContent.includes('Not available'));
const absent = { ...data, nights: [{ ...night, start_ds: 10000, end_ds: 298000, stages_full: [] }] };
w.openDayPage(absent, '2026-09-26');
assert(w.document.querySelector('#sec-sleep').textContent.includes('stages are unavailable'));
assert(!w.document.querySelector('#sec-sleep').textContent.includes('Incomplete sleep analysis'));
const editBtn = w.document.querySelector('.bedtime-edit-btn');
const editorForm = w.document.querySelector('.bedtime-editor');
assert(editBtn && editorForm && editorForm.hidden);
editBtn.click();
assert(!editorForm.hidden);
setImmediate(async () => {
  assert(w.document.querySelector('#sec-heart').textContent.includes('No heart-rate readings'));
  assert(requests.some(url => url.includes('/api/hourly-hr')));
  w.fetch = async () => ({ ok: true, body: new ReadableStream({start(controller) {
    controller.enqueue(new TextEncoder().encode('{"error":"Ring is busy; wait for the current operation to finish."}\n'));
    controller.close();
  }}) });
  await w.toggleLive();
  assert(w.document.getElementById('live-status').textContent.includes('Ring is busy'));
  assert.equal(w.document.getElementById('live-label').textContent, 'Start');
  console.log('Day view DOM integration checks passed');
  dom.window.close();
});
