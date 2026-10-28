# macOS setup guide

Everything in this repo runs on macOS: the CLI, the web dashboard, the model
runners and the nightly cron sync. This guide is the from-scratch path on an
Apple Silicon Mac; it also works on Intel with the same steps.

## 1. Prerequisites

```bash
# Rust (any recent stable)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Python 3.10+ for the model runners (optional, only if you want the
# on-device models: see docs/model-runners.md)
brew install python
```

Clone and build:

```bash
git clone https://github.com/Th0rgal/open_health.git
cd open_health
cargo build --release -p oura-cli
```

The build takes about a minute and produces `target/release/oura`.

## 2. Bluetooth permission

The first BLE command triggers macOS's Bluetooth permission dialog for the
terminal app you are using (Terminal, iTerm2, or your IDE). **Approve it**;
if you miss the dialog, grant it later in System Settings → Privacy &
Security → Bluetooth. Without it, scans silently return nothing.

## 3. Pair the ring

A factory-fresh (or factory-reset) ring pairs directly; no Oura account is
created or used.

- Keep the ring **on its charger** during pairing: it advertises reliably
  there and sleeps (stops advertising) otherwise. The LED blinks blue; that
  is the normal state for a ring that is not paired to the official app.
- A freshly reset ring may advertise without a name, so scan with an empty
  name filter:

```bash
./target/release/oura --name "" --scan-timeout 20 scan
./target/release/oura --name "" --key-file my-ring.key --scan-timeout 20 pair
```

`pair` mints a 16-byte auth key and installs it on the ring. **This key file
is the only way back into your ring** — back it up somewhere durable the same
day (it is small and hex; a password manager works). Losing every copy means
a factory reset and losing the ring's buffered data.

Gotchas worth knowing:

- The ring advertises in windows and sleeps deeply otherwise. If a connect
  fails with `no matching Oura ring found`, put it on the charger (or wear
  it) and retry; a short retry loop succeeds far more often than one shot.
- A failed bonding attempt can leave the ring unavailable for ~15 s. Wait
  and retry.
- Never let the official Oura app onboard a ring you want to use with this
  project: its onboarding installs its own key and locks this tooling out.
  The only way back is a factory reset.

### Ring already onboarded to the official app?

This client cannot authenticate to it without that app's key (extraction
paths are documented in the open_oura repo for rooted Android). The clean
path is a factory reset — the official app's own "Factory reset ring" is
the easiest — then uninstall the official app before re-pairing here, so it
cannot silently re-onboard the ring in the background.

## 4. Enable measurement features

A self-paired ring starts with its measurement features **off** (the
official app normally turns them on at onboarding):

```bash
./target/release/oura --key-file my-ring.key features --enable-hr --enable-spo2
./target/release/oura --key-file my-ring.key feature-mode real_steps
./target/release/oura --key-file my-ring.key feature-mode cva_ppg
./target/release/oura --key-file my-ring.key feature-mode exercise_hr
```

Check what is actually on:

```bash
./target/release/oura --key-file my-ring.key feature-status
```

## 5. Sync

```bash
./target/release/oura --name "" --key-file my-ring.key --db oura.db sync
```

The sync is incremental (a cursor is persisted in the DB) and triggers the
ring's sleep post-processing, so a finished night lands in the next sync.
Anything you do not sync stays buffered on the ring for days; the Mac just
needs to be awake and in Bluetooth range eventually.

Verify with a real readback — an exit code 0 is not verification:

```bash
./target/release/oura --key-file my-ring.key info        # battery needs the key
./target/release/oura --key-file my-ring.key live-hr --seconds 30  # wear the ring
sqlite3 oura.db "select tag, count(*) from events group by tag order by 2 desc limit 10;"
```

## 6. Automate the sync (launchd)

A LaunchAgent keeps the ring in sync while you are home:

`~/Library/LaunchAgents/com.openhealth.oura-sync.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.openhealth.oura-sync</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>cd /path/to/open_health &amp;&amp; ./target/release/oura --name '' \
      --key-file my-ring.key --db oura.db sync</string>
  </array>
  <key>StartInterval</key><integer>1800</integer>
  <key>StandardOutPath</key><string>/tmp/oura-sync.log</string>
  <key>StandardErrorPath</key><string>/tmp/oura-sync.log</string>
</dict></plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.openhealth.oura-sync.plist
```

Keep the sync script quiet when the ring is simply out of range (`no
matching Oura ring found` is normal daily life, not an error).

## 7. Dashboard

```bash
./target/release/oura --db oura.db --key-file my-ring.key dashboard
```

Then open <http://127.0.0.1:8090>. The dashboard is loopback-only by design;
nothing is exposed to your network. Note that `--key-file` is required for
the dashboard's own Sync/Live-HR buttons to work, and the server keeps
serving after you move the DB, so restart it if you relocate files.

## 8. Models (optional)

The heuristic staging in the dashboard works out of the box. Oura's own
on-device models (the official hypnogram stager, cardiovascular age, and so
on) can also run on your synced data once decrypted into the gitignored
`notes/models/` directory: see [docs/model-runners.md](model-runners.md)
for what each runner needs. The models are Oura's proprietary artifacts and
are deliberately not distributed with this repo.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Scan finds nothing | Ring is asleep: put it on the charger; approve Bluetooth permission; try `--name ""` |
| `no matching Oura ring found` on connect | Advertising window missed; retry with short waits |
| `ring rejected auth ... does not match THIS ring` | If transient, two clients raced for the ring's single BLE slot; if persistent, the ring holds another app's key (factory reset) |
| Dashboard Sync asks for a key / fails | Server was started without `--key-file`; restart with it |
| `NSSA could not stage this window` | Night lacks ACM/IBI/temp inside the bedtime, or the model tooling is incomplete; check `notes/models/` and the torch venv |
| Empty charts but `nights` present | Readings vs events are different layers; re-run the sync and check `events` counts |
