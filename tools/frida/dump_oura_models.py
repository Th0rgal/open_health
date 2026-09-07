#!/usr/bin/env python3
"""Drive the on-device Oura model decryption dump (dump_oura_models.js).

The models decrypt with a server-delivered key cached on a logged-in device
(docs/algorithms/sleepnet.md), so they cannot be decrypted from the APK alone.
This attaches Frida to the running Oura app, hooks its own AES-GCM decryption,
and keeps every plaintext that is a TorchScript container. You then navigate the
app so it loads the models you want; each decrypt lands in
/data/local/tmp/oura_models_dump/ on the device.

Nothing here prints or stores key material — only the decrypted model bytes,
which are the same artifacts docs/model-runners.md expects in notes/models/.

Prereqs: frida-server (matching frida major version, device arch) running as
root on the device; `pip install frida-tools` on the host.

    python tools/frida/dump_oura_models.py            # attach + hook, Ctrl-C to stop
    python tools/frida/dump_oura_models.py --pull      # after: match + pull to notes/models/
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

PKG = "com.ouraring.oura"
DEVICE_OUT = "/data/local/tmp/oura_models_dump"
HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "dump_oura_models.js"
REPO = HERE.parent.parent
MODELS_OUT = REPO / "notes" / "models"


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def su(cmd: str) -> str:
    return sh(["adb", "shell", "su", "-c", cmd]).stdout


def _oura_pid() -> int | None:
    out = sh(["adb", "shell", "pidof", PKG]).stdout.strip()
    return int(out.split()[0]) if out.split() else None


def hook() -> int:
    import frida

    device = frida.get_usb_device(timeout=15)
    # Attach by pid straight from `pidof`: enumerate_applications() spawns a helper in
    # every installed app to read its label and times out badly under load. The agent
    # handshake can also close once while the app is busy (post-boot, mid-render), so
    # retry a few times before giving up.
    pid = _oura_pid()
    if pid is None:
        print(f"{PKG} is not running — launch the Oura app first, then re-run.", file=sys.stderr)
        return 2
    session = None
    for attempt in range(1, 6):
        try:
            session = device.attach(pid)
            break
        except frida.TransportError as e:
            print(f"attach {attempt}/5 failed ({e}); the app is busy — retrying", file=sys.stderr)
            time.sleep(3)
            pid = _oura_pid() or pid
    if session is None:
        print("could not attach — is frida-server running and its version matched?", file=sys.stderr)
        return 3
    script = session.create_script(SCRIPT.read_text())
    script.on("message", lambda msg, data: print("  frida:", msg.get("payload", msg)))
    script.load()
    print(
        "Hooks installed. In the Oura app, open the screens whose models you want:\n"
        "  Sleep  -> sleepnet_moonstone / sleepstaging\n"
        "  Activity/Workouts -> automatic_activity_detection, steps_motion_decoder\n"
        "  Cardiovascular age -> cva\n"
        "  Symptom Radar / illness -> illness_detection\n"
        "Each decrypt is written on the device. Press Ctrl-C here when done, then run "
        "with --pull.",
    )
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\nDetaching.")
    session.detach()
    return 0


def pull() -> int:
    """Match each dumped plaintext to a .enc asset by size, then pull and name it."""
    listing = su(f"ls -1 {DEVICE_OUT}/*.pt 2>/dev/null")
    dumped = [line.strip() for line in listing.splitlines() if line.strip()]
    if not dumped:
        print(f"No dumps found in {DEVICE_OUT} — did the app load any models?", file=sys.stderr)
        return 1

    # Size of each dump on device.
    sizes: dict[str, int] = {}
    for path in dumped:
        out = su(f"stat -c %s {path}").strip()
        if out.isdigit():
            sizes[path] = int(out)

    # The .enc assets are 12 (IV) + 16 (GCM tag) bytes larger than their plaintext.
    enc_index = _enc_asset_sizes()
    MODELS_OUT.mkdir(parents=True, exist_ok=True)
    pulled = 0
    for path, size in sizes.items():
        name = enc_index.get(size + 28)
        local = MODELS_OUT / (name if name else f"unknown-{size}.pt")
        if sh(["adb", "exec-out", "su", "-c", f"cat {path}"], **{}).returncode != 0:
            continue
        with local.open("wb") as fh:
            proc = subprocess.run(["adb", "exec-out", "su", "-c", f"cat {path}"], stdout=fh)
        if proc.returncode == 0:
            tag = name or f"UNMATCHED ({size} bytes)"
            print(f"  pulled {tag}")
            pulled += 1
    print(f"{pulled} model(s) written to {MODELS_OUT}")
    print("Next: python tools/export_mobile.py   (produces the .ptl for Android/iOS)")
    return 0


def _enc_asset_sizes() -> dict[int, str]:
    """Map .enc asset size -> plaintext .pt filename, from the split models APK."""
    apk = su(
        "pm path com.ouraring.oura | sed 's/package://' | tr -d '\\r'"
    )
    paths = [p.strip() for p in apk.splitlines() if "oura_models" in p]
    index: dict[int, str] = {}
    for apk_path in paths:
        out = sh(["adb", "shell", f"unzip -l {apk_path}"]).stdout
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[-1].startswith("assets/") and parts[-1].endswith(".pt.enc"):
                size = int(parts[0])
                name = Path(parts[-1]).name[: -len(".enc")]  # strip .enc -> <name>.pt
                index[size] = name
    return index


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pull", action="store_true", help="Match + pull dumps to notes/models/")
    args = ap.parse_args()
    return pull() if args.pull else hook()


if __name__ == "__main__":
    raise SystemExit(main())
