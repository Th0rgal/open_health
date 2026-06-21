#!/usr/bin/env python3
"""Connect to a BLE device and enumerate services/characteristics."""

import argparse
import asyncio

from bleak import BleakClient


async def main() -> None:
    parser = argparse.ArgumentParser(description="Enumerate BLE services.")
    parser.add_argument("address", help="BLE address or platform identifier")
    args = parser.parse_args()

    async with BleakClient(args.address) as client:
        print(f"connected={client.is_connected}")
        try:
            print(f"mtu_size={client.mtu_size}")
        except Exception:
            pass

        for service in client.services:
            print(f"service uuid={service.uuid} handle={service.handle}")
            for char in service.characteristics:
                props = ",".join(char.properties)
                print(
                    f"  characteristic uuid={char.uuid} handle={char.handle} "
                    f"properties={props}"
                )
                for descriptor in char.descriptors:
                    print(
                        f"    descriptor uuid={descriptor.uuid} "
                        f"handle={descriptor.handle}"
                    )


if __name__ == "__main__":
    asyncio.run(main())
