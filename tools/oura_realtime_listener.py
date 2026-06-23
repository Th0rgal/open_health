#!/usr/bin/env python3
"""Listen for exploratory Oura realtime notifications.

This is intentionally conservative: it always restores the known realtime-off
packet on exit unless --no-restore-off is passed.
"""

import argparse
import asyncio
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from bleak import BleakClient
from bleak.exc import BleakError

from oura_protocol import (
    COMMANDS,
    OURA_NOTIFY,
    OURA_WRITE,
    authenticate,
    describe_packet,
    find_device,
    load_key,
    parse_packet,
    packet,
    write_capture,
)


KNOWN_MODES = {
    "off": bytes.fromhex("00000000"),
    "mode1": bytes.fromhex("01000000"),
    "mode2": bytes.fromhex("02000000"),
    "mode3": bytes.fromhex("03000000"),
    "motion_guess": bytes.fromhex("01010000"),
    "hr_guess": bytes.fromhex("01020000"),
    "all_guess": bytes.fromhex("ffffffff"),
}


def realtime_request(payload: bytes) -> bytes:
    if len(payload) != 4:
        raise ValueError("realtime payload must be exactly 4 bytes")
    return packet(0x06, payload)


async def write_named(client: BleakClient, capture: Optional[Path], name: str, request: bytes) -> None:
    write_capture(
        capture,
        {
            "utc": datetime.now(timezone.utc).isoformat(),
            "command": name,
            "direction": "write",
            "uuid": OURA_WRITE,
            "hex": request.hex(),
        },
    )
    print(f"write command={name} uuid={OURA_WRITE} hex={request.hex()}")
    await client.write_gatt_char(OURA_WRITE, request, response=True)


async def main() -> None:
    parser = argparse.ArgumentParser(description="Listen for Oura realtime notifications.")
    parser.add_argument("--address", help="BLE address/platform identifier to target")
    parser.add_argument("--name-contains", default="Oura Ring Gen3")
    parser.add_argument("--scan-timeout", type=float, default=30.0)
    parser.add_argument("--connect-timeout", type=float, default=60.0)
    parser.add_argument("--auth-key", help="16-byte auth key hex")
    parser.add_argument("--auth-key-file", default="captures/horizon-ring3-auth-key.hex")
    parser.add_argument("--capture", default="captures/horizon-ring3-realtime-listener.jsonl")
    parser.add_argument("--mode", choices=sorted(KNOWN_MODES), default="motion_guess")
    parser.add_argument("--payload-hex", help="Override --mode with exactly four payload bytes for tag 0x06")
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--no-auth", action="store_true", help="Skip app auth before enabling realtime mode")
    parser.add_argument("--no-restore-off", action="store_true", help="Do not send realtime-off on exit")
    parser.add_argument(
        "--poll-latest",
        action="store_true",
        help="Poll feature status/latest values once per interval while listening",
    )
    parser.add_argument("--poll-interval", type=float, default=5.0)
    args = parser.parse_args()

    payload = bytes.fromhex(args.payload_hex) if args.payload_hex else KNOWN_MODES[args.mode]
    if len(payload) != 4:
        raise SystemExit("--payload-hex must be exactly four bytes")

    capture = Path(args.capture) if args.capture else None
    key = None if args.no_auth else load_key(args)
    if not args.no_auth and key is None:
        raise SystemExit("auth requires --auth-key or --auth-key-file; pass --no-auth to skip")

    candidates = await find_device(args)
    if not candidates:
        print("no_oura_candidates")
        return
    for index, (device, adv) in enumerate(candidates):
        name = device.name or adv.local_name or ""
        print(f"candidate[{index}] address={device.address} rssi={adv.rssi} name={name!r}")

    device, adv = candidates[0]
    name = device.name or adv.local_name or ""
    print(f"connecting address={device.address} rssi={adv.rssi} name={name!r}")

    responses = 0

    def on_notify(sender, data: bytearray) -> None:
        nonlocal responses
        responses += 1
        payload_bytes = bytes(data)
        parsed = parse_packet(payload_bytes)
        record = {
            "utc": datetime.now(timezone.utc).isoformat(),
            "command": "listen",
            "direction": "notification",
            "sender": str(sender),
            "packet": parsed,
        }
        write_capture(capture, record)
        print(f"notification[{responses}] sender={sender} {describe_packet(payload_bytes)}")

    async with BleakClient(device, timeout=args.connect_timeout) as client:
        print(f"connected={client.is_connected}")
        print(f"mtu_size={client.mtu_size}")
        if key is not None:
            await authenticate(client, key, 1.0, capture)
        await client.start_notify(OURA_NOTIFY, on_notify)
        try:
            await write_named(client, capture, f"realtime_{args.mode}", realtime_request(payload))
            print(f"listening seconds={args.seconds} realtime_payload={payload.hex()}")
            if args.poll_latest:
                deadline = asyncio.get_running_loop().time() + args.seconds
                poll_commands = [
                    "feature_daytime_hr",
                    "feature_latest_daytime_hr",
                    "feature_exercise_hr",
                    "feature_latest_exercise_hr",
                    "feature_latest_spo2",
                ]
                while asyncio.get_running_loop().time() < deadline:
                    for command_name in poll_commands:
                        await write_named(client, capture, command_name, COMMANDS[command_name].request)
                        await asyncio.sleep(0.5)
                    await asyncio.sleep(max(0.0, args.poll_interval - 0.5 * len(poll_commands)))
            else:
                await asyncio.sleep(args.seconds)
        finally:
            if not args.no_restore_off:
                try:
                    await write_named(client, capture, "realtime_off_restore", realtime_request(KNOWN_MODES["off"]))
                    await asyncio.sleep(1.0)
                except BleakError as exc:
                    print(f"restore_off_failed error={exc}")
            try:
                await client.stop_notify(OURA_NOTIFY)
            except BleakError as exc:
                print(f"stop_notify_failed error={exc}")
            print(f"done notifications={responses}")


if __name__ == "__main__":
    asyncio.run(main())
