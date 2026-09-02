#!/usr/bin/env python3
"""Generate a synthetic calibration PCD for testing measure_pcd_distances.py.

A 50 cm x 50 cm square of points on the z=0 plane plus a 20 cm crossbar.
Known distances: square edges 0.50 m, crossbar 0.20 m, square diagonal ~0.7071 m.
"""
import math

W = 0.50          # square side, meters
BAR = 0.20        # crossbar length, meters
N = 25            # points per square edge

pts = []
# square edges
for i in range(N):
    t = i / (N - 1)
    pts.append((t * W, 0.0, 0.0))
    pts.append((t * W, W, 0.0))
    pts.append((0.0, t * W, 0.0))
    pts.append((W, t * W, 0.0))
# crossbar: from (0.25, 0.25) to (0.45, 0.25), i.e. 20 cm
for i in range(N):
    t = i / (N - 1)
    pts.append((0.25 + t * BAR, 0.25, 0.0))

with open("test_board.pcd", "w") as f:
    f.write("# .PCD v0.7 - Point Cloud Data file format\n")
    f.write("VERSION 0.7\n")
    f.write("FIELDS x y z\n")
    f.write("SIZE 4 4 4\n")
    f.write("TYPE F F F\n")
    f.write("COUNT 1 1 1\n")
    f.write("WIDTH {}\n".format(len(pts)))
    f.write("HEIGHT 1\n")
    f.write("VIEWPOINT 0 0 0 1 0 0 0\n")
    f.write("POINTS {}\n".format(len(pts)))
    f.write("DATA ascii\n")
    for x, y, z in pts:
        f.write("{:.8f} {:.8f} {:.8f}\n".format(x, y, z))
print("wrote test_board.pcd with", len(pts), "points")
