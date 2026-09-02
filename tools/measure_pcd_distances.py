#!/usr/bin/env python3
"""Measure 3-D distances in a PCD file with Open3D.

Examples:
  python3 measure_pcd_distances.py board.pcd
  python3 measure_pcd_distances.py board.pcd --expected 0.20 0.20 0.20 0.20
  python3 measure_pcd_distances.py board.pcd \
      --points 1.0,2.0,0.5 1.2,2.0,0.5

With the interactive mode, hold Shift and click points in the Open3D window,
then close the window. Click order is preserved in the printed output.
"""

from __future__ import annotations

import argparse
import itertools
import math
import sys
from typing import Iterable, List, Sequence, Tuple


Point = Tuple[float, float, float]


def parse_point(value: str) -> Point:
    fields = value.split(",")
    if len(fields) != 3:
        raise argparse.ArgumentTypeError("point must be x,y,z")
    try:
        return (float(fields[0]), float(fields[1]), float(fields[2]))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("point must be x,y,z") from exc


def distance(a: Point, b: Point) -> float:
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def print_measurements(points: Sequence[Point], expected: Sequence[float]) -> None:
    if len(points) < 2:
        print("Need at least two points.", file=sys.stderr)
        return

    print("Selected points:")
    for index, point in enumerate(points):
        print("  {}: ({:.6f}, {:.6f}, {:.6f})".format(index, *point))

    print("Adjacent distances:")
    adjacent = []
    for index, (first, second) in enumerate(zip(points, points[1:])):
        measured = distance(first, second)
        adjacent.append(measured)
        line = "  {} -> {}: {:.4f} m ({:.1f} cm)".format(
            index, index + 1, measured, measured * 100.0
        )
        if index < len(expected):
            error = measured - expected[index]
            line += "  expected {:.4f} m, error {:+.4f} m ({:+.1f} cm)".format(
                expected[index], error, error * 100.0
            )
        print(line)

    if len(points) > 2:
        print("All pairwise distances:")
        for first_index, second_index in itertools.combinations(range(len(points)), 2):
            measured = distance(points[first_index], points[second_index])
            print(
                "  {} <-> {}: {:.4f} m ({:.1f} cm)".format(
                    first_index, second_index, measured, measured * 100.0
                )
            )

    if expected and len(expected) != len(adjacent):
        print(
            "Note: {} expected values supplied for {} adjacent distances.".format(
                len(expected), len(adjacent)
            ),
            file=sys.stderr,
        )


def interactive_points(pcd_path: str, voxel_size: float):
    try:
        import open3d as o3d
    except ImportError:
        print("Open3D is required: python3 -m pip install open3d", file=sys.stderr)
        raise SystemExit(2)

    cloud = o3d.io.read_point_cloud(pcd_path)
    if cloud.is_empty():
        print("PCD contains no points: {}".format(pcd_path), file=sys.stderr)
        raise SystemExit(2)
    if voxel_size > 0.0:
        cloud = cloud.voxel_down_sample(voxel_size)

    print("Point count shown: {}".format(len(cloud.points)))
    print("In the window, hold Shift and click points in order; close it when done.")
    visualizer = o3d.visualization.VisualizerWithEditing()
    visualizer.create_window(window_name="PCD distance measurement")
    visualizer.add_geometry(cloud)
    visualizer.run()
    visualizer.destroy_window()
    picked_indices = visualizer.get_picked_points()
    return [tuple(float(value) for value in cloud.points[index]) for index in picked_indices]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pcd", help="input .pcd file")
    parser.add_argument(
        "--points",
        nargs="+",
        type=parse_point,
        help="skip GUI and measure explicit points as x,y,z ...",
    )
    parser.add_argument(
        "--expected",
        nargs="+",
        type=float,
        default=(),
        metavar="METERS",
        help="known lengths for adjacent picked points, in meters",
    )
    parser.add_argument(
        "--voxel-size",
        type=float,
        default=0.0,
        help="optional display-only downsampling size in meters (default: no downsampling)",
    )
    args = parser.parse_args()

    points: Iterable[Point]
    if args.points:
        points = args.points
    else:
        points = interactive_points(args.pcd, args.voxel_size)
    print_measurements(list(points), args.expected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
