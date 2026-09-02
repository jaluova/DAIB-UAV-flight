#!/usr/bin/env python3
"""Generate a synthetic ROS1 bag with /cloud_registered PointCloud2 frames.

Produces the same 50 cm square + 20 cm crossbar board as make_test_pcd.py,
emitted as several registered frames with small noise, so the whole
record -> extract -> measure chain can be tested without real data:

    python3 make_test_bag.py test_board.bag [frames]

Requires: rosbags (pip install rosbags).
"""

from __future__ import annotations

import random
import sys

import numpy as np
from rosbags.rosbag1 import Writer
from rosbags.typesys import Stores, get_typestore

STORE = get_typestore(Stores.ROS1_NOETIC)
PC2 = "sensor_msgs/msg/PointCloud2"
Header = STORE.types["std_msgs/msg/Header"]
Time = STORE.types["builtin_interfaces/msg/Time"]
PointField = STORE.types["sensor_msgs/msg/PointField"]
PointCloud2 = STORE.types["sensor_msgs/msg/PointCloud2"]


def board_points(noise: float = 0.0, rng: random.Random | None = None):
    W, BAR, N = 0.50, 0.20, 25
    pts = []
    for i in range(N):
        t = i / (N - 1)
        pts += [(t * W, 0.0, 0.0), (t * W, W, 0.0), (0.0, t * W, 0.0), (W, t * W, 0.0)]
    for i in range(N):
        t = i / (N - 1)
        pts.append((0.25 + t * BAR, 0.25, 0.0))
    if noise > 0:
        rng = rng or random.Random()
        pts = [(x + rng.gauss(0, noise), y + rng.gauss(0, noise), z + rng.gauss(0, noise)) for x, y, z in pts]
    return pts


def build_pc2(points, stamp_ns: int) -> PointCloud2:
    xyz = np.asarray(points, dtype=np.float32)
    n = len(xyz)
    fields = [
        PointField(name="x", offset=0, datatype=7, count=1),
        PointField(name="y", offset=4, datatype=7, count=1),
        PointField(name="z", offset=8, datatype=7, count=1),
    ]
    return PointCloud2(
        header=Header(seq=0, stamp=Time(sec=stamp_ns // 1_000_000_000, nanosec=stamp_ns % 1_000_000_000), frame_id="camera_init"),
        height=1,
        width=n,
        fields=fields,
        is_bigendian=False,
        point_step=12,
        row_step=12 * n,
        data=xyz.reshape(-1).view(np.uint8),  # rosbags expects a flat uint8 ndarray
        is_dense=True,
    )


def main() -> int:
    import random as _r

    out = sys.argv[1] if len(sys.argv) > 1 else "test_board.bag"
    frames = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    rng = _r.Random(42)
    with Writer(out) as writer:
        conn = writer.add_connection("/cloud_registered", PC2, typestore=STORE)
        t0 = 1_700_000_000_000_000_000
        for i in range(frames):
            pts = board_points(noise=0.002, rng=rng)  # ~2 mm jitter per frame
            msg = build_pc2(pts, t0 + i * 100_000_000)
            writer.write(conn, t0 + i * 100_000_000, STORE.serialize_ros1(msg, PC2))
    print("wrote {} with {} frames of /cloud_registered".format(out, frames))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
