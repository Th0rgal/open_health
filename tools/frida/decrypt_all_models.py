#!/usr/bin/env python3
"""Decrypt every Oura .pt.enc model asset with a captured key (see capture_model_key.py).

Reads the AES-256-GCM key from local/oura-model-key.txt, pulls each assets/*.pt.enc from
the split models APK, and writes the plaintext TorchScript to notes/models/<name>.pt. The
GCM tag verifies each decrypt, so a wrong/rotated key is reported rather than producing
garbage. Nothing here needs frida — the key does all the work.
"""
from __future__ import annotations
import subprocess, sys
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PKG = "com.ouraring.oura"
REPO = Path(__file__).resolve().parent.parent.parent
OUT = REPO / "notes" / "models"
KEY_FILE = REPO / "local" / "oura-model-key.txt"


def models_apk() -> str:
    paths = subprocess.run(["adb", "shell", "pm", "path", PKG], capture_output=True, text=True).stdout
    for line in paths.splitlines():
        if "oura_models" in line:
            return line.replace("package:", "").strip()
    sys.exit("split_oura_models.apk not found on device")


def main() -> int:
    if not KEY_FILE.exists():
        sys.exit(f"no key at {KEY_FILE} — run capture_model_key.py first")
    keys = [bytes.fromhex(k.strip()) for k in KEY_FILE.read_text().split() if k.strip()]
    apk = models_apk()
    # toybox unzip has no -Z1; parse `unzip -l`, whose last column is the name.
    names = subprocess.run(["adb", "shell", f"unzip -l {apk}"], capture_output=True, text=True).stdout
    encs = []
    for line in names.splitlines():
        parts = line.split()
        if parts and parts[-1].startswith("assets/") and parts[-1].endswith(".pt.enc"):
            encs.append(parts[-1])
    OUT.mkdir(parents=True, exist_ok=True)
    ok = fail = 0
    for entry in sorted(encs):
        blob = subprocess.run(["adb", "exec-out", f"unzip -p {apk} {entry}"], capture_output=True).stdout
        name = Path(entry).name[:-len(".enc")]  # <name>.pt
        plain = None
        for key in keys:
            try:
                plain = AESGCM(key).decrypt(blob[:12], blob[12:], None)
                break
            except Exception:
                continue
        if plain and plain[:4] == b"PK\x03\x04":
            (OUT / name).write_bytes(plain)
            print(f"  ok   {name}  ({len(plain)//1024} KB)")
            ok += 1
        else:
            print(f"  FAIL {name}  (no captured key decrypts it)")
            fail += 1
    print(f"\n{ok} decrypted into {OUT}, {fail} failed")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
