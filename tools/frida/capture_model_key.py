#!/usr/bin/env python3
"""Capture the Oura model-decryption key, then decrypt every assets/*.pt.enc offline.

The key is server-delivered and cached on a logged-in device (see
docs/algorithms/sleepnet.md), so it cannot be pulled from the APK. This attaches to the
running app, hooks Cipher.init to read the AES-256 key it uses for a model DECRYPT, then
decrypts all the .enc assets locally with the documented recipe:

    [12-byte IV][AES-256-GCM ciphertext + 16-byte tag]

The GCM tag verifies which captured key is right, so nothing is guessed. Decrypted models
land in notes/models/ (gitignored), where docs/model-runners.md and tools/export_mobile.py
expect them. The key is written only to a 0600 file, never printed.

    python tools/frida/capture_model_key.py     # attach, capture, decrypt everything
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

PKG = "com.ouraring.oura"
HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
MODELS_OUT = REPO / "notes" / "models"
KEY_OUT = REPO / "local" / "oura-model-key.txt"


def sh(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True)


def oura_pid() -> int | None:
    out = sh(["adb", "shell", "pidof", PKG]).stdout.strip()
    return int(out.split()[0]) if out.split() else None


def enc_assets() -> dict[str, bytes]:
    """Every assets/*.pt.enc, pulled from the split models APK, keyed by plaintext name."""
    apks = sh(["adb", "shell", "pm", "path", PKG]).stdout
    models_apk = next(
        (l.replace("package:", "").strip() for l in apks.splitlines() if "oura_models" in l),
        None,
    )
    if not models_apk:
        return {}
    names = sh(["adb", "shell", f"unzip -Z1 {models_apk}"]).stdout
    out: dict[str, bytes] = {}
    for entry in names.splitlines():
        entry = entry.strip()
        if not (entry.startswith("assets/") and entry.endswith(".pt.enc")):
            continue
        blob = subprocess.run(
            ["adb", "exec-out", f"unzip -p {models_apk} {entry}"], capture_output=True
        ).stdout
        if blob:
            out[Path(entry).name[: -len(".enc")]] = blob  # <name>.pt
    return out


def decrypt(blob: bytes, key: bytes) -> bytes | None:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    iv, ct = blob[:12], blob[12:]
    try:
        return AESGCM(key).decrypt(iv, ct, None)  # tag is the last 16 bytes of ct
    except Exception:
        return None


def main() -> int:
    import frida

    pid = oura_pid()
    if pid is None:
        print(f"{PKG} is not running — launch the Oura app first.", file=sys.stderr)
        return 2

    device = frida.get_usb_device(timeout=15)
    session = None
    for attempt in range(1, 6):
        try:
            session = device.attach(pid)
            break
        except Exception as e:
            print(f"attach {attempt}/5 failed ({e}) — retrying", file=sys.stderr)
            time.sleep(3)
            pid = oura_pid() or pid
    if session is None:
        return 3

    keys: list[bytes] = []
    bundle = HERE / "capture_model_key.compiled.js"
    src = bundle if bundle.exists() else (HERE / "capture_model_key.js")
    script = session.create_script(src.read_text())

    def on_message(msg, _data):
        payload = msg.get("payload") if isinstance(msg, dict) else None
        if not payload:
            return
        if payload.get("t") == "key":
            k = bytes.fromhex(payload["key"])
            if k not in keys:
                keys.append(k)
                print(f"captured an AES-256 model key (fingerprint {payload['key'][:8]}…)")

    script.on("message", on_message)
    script.load()
    print(
        "Hook installed. In the Oura app, open a past night's Sleep detail (and Activity /\n"
        "Cardiovascular / Symptom Radar) so it loads a model. Waiting up to 3 min…"
    )

    deadline = time.time() + 180
    while time.time() < deadline and not keys:
        time.sleep(2)
    session.detach()

    if not keys:
        print("No model key seen — the app never decrypted a model. Open a Sleep detail and "
              "retry.", file=sys.stderr)
        return 1

    KEY_OUT.parent.mkdir(parents=True, exist_ok=True)
    KEY_OUT.write_text("\n".join(k.hex() for k in keys) + "\n")
    KEY_OUT.chmod(0o600)
    print(f"{len(keys)} key(s) saved to {KEY_OUT}")

    print("Pulling encrypted model assets…")
    assets = enc_assets()
    print(f"  {len(assets)} .pt.enc assets")
    MODELS_OUT.mkdir(parents=True, exist_ok=True)
    ok = 0
    for name, blob in assets.items():
        plain = None
        for k in keys:
            plain = decrypt(blob, k)
            if plain:
                break
        if plain:
            (MODELS_OUT / name).write_bytes(plain)
            ok += 1
        else:
            print(f"  ! {name}: no captured key decrypts it (different label?)")
    print(f"decrypted {ok}/{len(assets)} models into {MODELS_OUT}")
    print("Next: python tools/export_mobile.py   (produces the .ptl for on-device use)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
