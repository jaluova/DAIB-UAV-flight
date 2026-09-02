#!/usr/bin/env python3
"""Receive DAIB velocity packets on Manifold for PSDK ground testing.

The default mode is deliberately dry-run: packets are validated, printed, and
expired packets produce a neutral command.  Integrating the final command into
DJI's ExecuteJoystickAction API must happen inside the already-tested PSDK
authority state machine; this process never acquires authority or sends flight
commands by itself.
"""

import argparse
import socket
import struct
import time


PACKET = struct.Struct("!4sBBH I Q 4f I")
MAGIC = b"DAIB"
VERSION = 1
TYPE_VELOCITY = 1


def crc32(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
    return (~crc) & 0xFFFFFFFF


def neutral(reason: str) -> None:
    print(f"NEUTRAL reason={reason} x=0 y=0 z=0 yaw=0", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=19090)
    parser.add_argument("--timeout-ms", type=int, default=200)
    parser.add_argument("--horizontal-limit", type=float, default=0.1)
    parser.add_argument("--vertical-limit", type=float, default=0.05)
    parser.add_argument("--yaw-limit", type=float, default=0.0)
    parser.add_argument("--max-packet-age-ms", type=float, default=1000.0,
                        help="diagnostic sender-clock age limit; use 0 to disable")
    parser.add_argument("--max-future-skew-ms", type=float, default=200.0,
                        help="diagnostic sender-clock future limit; use 0 to disable")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    sock.settimeout(0.05)
    print(f"DRY_RUN listening on {args.bind}:{args.port}", flush=True)

    last_receive = 0.0
    last_seq = None
    neutral_sent = True
    while True:
        now = time.monotonic()
        try:
            packet, source = sock.recvfrom(2048)
        except socket.timeout:
            if last_receive and (now - last_receive) * 1000 > args.timeout_ms:
                if not neutral_sent:
                    neutral("timeout")
                    neutral_sent = True
            continue

        if len(packet) != PACKET.size:
            print(f"DROP reason=length bytes={len(packet)} from={source}", flush=True)
            continue
        body = packet[:-4]
        magic, version, msg_type, reserved, seq, stamp_us, x, y, z, yaw, crc = PACKET.unpack(packet)
        if magic != MAGIC or version != VERSION or msg_type != TYPE_VELOCITY or reserved != 0:
            print(f"DROP reason=header seq={seq}", flush=True)
            continue
        if crc32(body) != crc:
            print(f"DROP reason=crc seq={seq}", flush=True)
            continue
        if last_seq is not None and seq <= last_seq:
            # The Orange Pi sender starts a fresh sequence at every process
            # start. After a timeout this is a new sender session, not a
            # reordering event; accept the first packet and rebaseline.
            if last_receive and (now - last_receive) * 1000 > args.timeout_ms:
                print(f"RESET reason=sender_restart seq={seq} last={last_seq}", flush=True)
                last_seq = None
            else:
                print(f"DROP reason=sequence seq={seq} last={last_seq}", flush=True)
                continue
        if last_seq is not None:
            expected_seq = (last_seq + 1) & 0xFFFFFFFF
            if seq != expected_seq:
                print(f"DROP reason=sequence_gap seq={seq} expected={expected_seq} last={last_seq}", flush=True)
                last_seq = seq
                last_receive = now
                neutral("sequence_gap")
                neutral_sent = True
                continue
        last_seq = seq
        last_receive = now
        neutral_sent = False
        age_ms = (time.time() - stamp_us / 1e6) * 1000.0
        if ((args.max_packet_age_ms > 0 and age_ms > args.max_packet_age_ms) or
                (args.max_future_skew_ms > 0 and age_ms < -args.max_future_skew_ms)):
            print(f"DROP reason=timestamp seq={seq} age_ms={age_ms:.1f}", flush=True)
            neutral("timestamp")
            continue
        if (abs(x) > args.horizontal_limit + 1e-4 or
                abs(y) > args.horizontal_limit + 1e-4 or
                abs(z) > args.vertical_limit + 1e-4 or
                abs(yaw) > args.yaw_limit + 1e-3):
            print(f"DROP reason=limit seq={seq} x={x:.4f} y={y:.4f} z={z:.4f} yaw={yaw:.3f}", flush=True)
            neutral("limit")
            continue
        print(
            f"RECV dry_run=1 seq={seq} age_ms={age_ms:.1f} "
            f"x={x:.4f} y={y:.4f} z={z:.4f} yaw={yaw:.3f} from={source[0]}:{source[1]}",
            flush=True,
        )


if __name__ == "__main__":
    raise SystemExit(main())
