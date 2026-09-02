#!/usr/bin/env python3
"""Extract a PointCloud2 topic from a ROS1 rosbag into .pcd file(s).

Pure-python (rosbags package), no ROS install needed on this machine:

    python3 bag_to_pcd.py flight.bag /cloud_registered map.pcd          # last frame
    python3 bag_to_pcd.py flight.bag /cloud_registered --every-n 30     # frames -> map_XXXX.pcd
    python3 bag_to_pcd.py flight.bag /cloud_registered map.pcd --accumulate  # merge all frames

/cloud_registered is the per-frame registered cloud from FAST-LIVO; all frames
are in the same map frame (camera_init), so --accumulate merges them into one
denser cloud, which is what you want for measuring a physical target. If the
bag has an accumulated-map topic such as /Laser_map, extracting its last
message is equivalent and cheaper.
"""

from __future__ import annotations

import argparse
import sys

import numpy as np
from rosbags.rosbag1 import Reader
from rosbags.typesys import Stores, get_typestore

TYPESTORE = get_typestore(Stores.ROS1_NOETIC)
PC2 = "sensor_msgs/msg/PointCloud2"

_FIELD_SIZES = {1: 1, 2: 1, 3: 2, 4: 2, 5: 4, 6: 4, 7: 4, 8: 8}
_DTYPES = {1: "i1", 2: "u1", 3: "i2", 4: "u2", 5: "i4", 6: "u4", 7: "f4", 8: "f8"}


def cloud_to_pcd(points: np.ndarray, out_path: str) -> int:
    n = len(points)
    with open(out_path, "w") as f:
        f.write("# .PCD v0.7\nVERSION 0.7\n")
        f.write("FIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\n")
        f.write("WIDTH {}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\n".format(n))
        f.write("POINTS {}\nDATA ascii\n".format(n))
        np.savetxt(f, points, fmt="%.6f")
    return n


def points_of(msg) -> np.ndarray:
    """Return (N,3) float64 array of x/y/z from a deserialized PointCloud2."""
    if len(msg.data) == 0 or msg.height * msg.width == 0:
        return np.zeros((0, 3))
    raw = np.frombuffer(msg.data, dtype=np.uint8)
    step = msg.point_step or len(raw) // max(1, msg.height * msg.width)
    arr = raw[: msg.height * msg.width * step].reshape(-1, step)
    out = np.zeros((len(arr), 3), dtype=np.float64)
    for i, name in enumerate(("x", "y", "z")):
        for f in msg.fields:
            if f.name != name:
                continue
            col = arr[:, f.offset : f.offset + _FIELD_SIZES.get(f.datatype, 4)]
            col = col.reshape(-1).view(_DTYPES.get(f.datatype, "f4")).astype(np.float64)
            if f.datatype == 5 or f.datatype == 6:  # int32/uint32 -> signed meters
                col = col.astype(np.int64)
            out[:, i] = col
            break
    good = np.isfinite(out).all(axis=1)
    return out[good]


def last_message(bag_path: str, topic: str):
    with Reader(bag_path) as reader:
        msgs = list(reader.messages(connections=[c for c in reader.connections if c.topic == topic]))
        if not msgs:
            return None
        _, _, raw = msgs[-1]
        conn = next(c for c in reader.connections if c.topic == topic)
        return TYPESTORE.deserialize_ros1(raw, conn.msgtype)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("bag", help="input .bag file")
    ap.add_argument("topic", help="PointCloud2 topic to extract")
    ap.add_argument("out", nargs="?", default="out.pcd", help="output .pcd / prefix")
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--every-n", type=int, default=0, help="write every N-th frame instead of the last")
    group.add_argument("--accumulate", action="store_true", help="merge all frames into one cloud")
    args = ap.parse_args()

    frames = 0
    written = 0
    acc = []
    with Reader(args.bag) as reader:
        conns = [c for c in reader.connections if c.topic == args.topic]
        if not conns:
            print("topic {} not in bag".format(args.topic), file=sys.stderr)
            return 2
        for i, (conn, _, raw) in enumerate(reader.messages(connections=conns)):
            msg = TYPESTORE.deserialize_ros1(raw, conn.msgtype)
            pts = points_of(msg)
            frames += 1
            if args.accumulate:
                acc.append(pts)
            elif args.every_n and i % args.every_n == 0:
                n = cloud_to_pcd(pts, "{}_frames{:05d}.pcd".format(args.out, i))
                written += 1
                print("wrote {}_frames{:05d}.pcd ({} pts)".format(args.out, i, n))
    if args.accumulate:
        total = np.concatenate(acc, axis=0) if acc else np.zeros((0, 3))
        n = cloud_to_pcd(total, args.out)
        print("merged {} frames -> {} ({} pts)".format(frames, args.out, n))
    elif not args.every_n:
        last = None
        with Reader(args.bag) as reader:
            msgs = list(reader.messages(connections=[c for c in reader.connections if c.topic == args.topic]))
        if msgs:
            raw = msgs[-1][2]
            last = TYPESTORE.deserialize_ros1(raw, conns[0].msgtype)
        if last is None:
            print("topic {} not in bag".format(args.topic), file=sys.stderr)
            return 2
        n = cloud_to_pcd(points_of(last), args.out)
        print("last of {} frames -> {} ({} pts)".format(frames, args.out, n))
    print("ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
