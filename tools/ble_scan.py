#!/usr/bin/env python3
"""Scan for nearby BLE devices and print likely Oura candidates."""

import argparse
import asyncio
from datetime import datetime, timezone
from typing import Optional

from bleak import BleakScanner


def looks_like_oura(name: Optional[str]) -> bool:
    if not name:
        return False
    lowered = name.lower()
    return "oura" in lowered or "ring" in lowered


async def main() -> None:
    parser = argparse.ArgumentParser(description="Scan for BLE devices.")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    started = datetime.now(timezone.utc).isoformat()
    print(f"scan_started_utc={started}")
    devices = await BleakScanner.discover(timeout=args.timeout, return_adv=True)

    for device, adv in sorted(devices.values(), key=lambda item: item[0].address):
        name = device.name or adv.local_name or ""
        marker = "*" if looks_like_oura(name) else " "
        uuids = ",".join(adv.service_uuids or [])
        print(
            f"{marker} address={device.address} rssi={adv.rssi} "
            f"name={name!r} services={uuids}"
        )


if __name__ == "__main__":
    asyncio.run(main())
