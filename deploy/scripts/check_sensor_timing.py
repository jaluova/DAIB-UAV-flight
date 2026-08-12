#!/usr/bin/env python3

import argparse
import bisect
import statistics
import time

import rospy
from livox_ros_driver.msg import CustomMsg
from sensor_msgs.msg import Image, Imu


class TimingCheck:
    def __init__(self):
        self.capturing = False
        self.stamps = {"lidar": [], "imu": [], "image": []}
        self.arrivals = {"lidar": [], "imu": [], "image": []}
        self.frames = {}
        self.point_counts = []
        self.scan_durations = []

    def record(self, name, msg):
        if not self.capturing:
            return
        self.stamps[name].append(msg.header.stamp.to_sec())
        self.arrivals[name].append(time.time())
        self.frames[name] = msg.header.frame_id

    def lidar_callback(self, msg):
        if not self.capturing:
            return
        self.record("lidar", msg)
        self.point_counts.append(msg.point_num)
        max_offset = max((point.offset_time for point in msg.points), default=0)
        self.scan_durations.append(max_offset * 1e-9)

    def imu_callback(self, msg):
        self.record("imu", msg)

    def image_callback(self, msg):
        self.record("image", msg)


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[int(fraction * (len(ordered) - 1))]


def print_stream(name, check):
    stamps = check.stamps[name]
    arrivals = check.arrivals[name]
    print("%s: count=%d frame=%s" %
          (name, len(stamps), check.frames.get(name, "<none>")))
    if len(stamps) < 2:
        return

    intervals = [right - left for left, right in zip(stamps, stamps[1:])]
    lags = [arrival - stamp for arrival, stamp in zip(arrivals, stamps)]
    print("  rate=%.3f Hz interval_median=%.3f ms regressions=%d" %
          ((len(stamps) - 1) / (stamps[-1] - stamps[0]),
           statistics.median(intervals) * 1000.0,
           sum(interval <= 0.0 for interval in intervals)))
    print("  arrival_minus_stamp: median=%.3f ms p95=%.3f ms max=%.3f ms" %
          (statistics.median(lags) * 1000.0,
           percentile(lags, 0.95) * 1000.0,
           max(lags) * 1000.0))


def print_nearest(reference_name, check):
    reference = sorted(check.stamps[reference_name])
    differences = []
    for lidar_stamp in check.stamps["lidar"]:
        index = bisect.bisect_left(reference, lidar_stamp)
        candidates = reference[max(0, index - 1):min(len(reference), index + 1)]
        if candidates:
            nearest = min(candidates, key=lambda stamp: abs(stamp - lidar_stamp))
            differences.append(nearest - lidar_stamp)
    if not differences:
        return

    absolute = [abs(value) for value in differences]
    print("nearest_%s_minus_lidar: signed_median=%.3f ms "
          "abs_median=%.3f ms abs_p95=%.3f ms" %
          (reference_name, statistics.median(differences) * 1000.0,
           statistics.median(absolute) * 1000.0,
           percentile(absolute, 0.95) * 1000.0))


def stream_metrics(name, check):
    stamps = check.stamps[name]
    if len(stamps) < 2 or stamps[-1] <= stamps[0]:
        return None
    intervals = [right - left for left, right in zip(stamps, stamps[1:])]
    return {
        "rate": (len(stamps) - 1) / (stamps[-1] - stamps[0]),
        "regressions": sum(interval <= 0.0 for interval in intervals),
    }


def arrival_lag_metrics(name, check):
    stamps = check.stamps[name]
    arrivals = check.arrivals[name]
    if not stamps or len(stamps) != len(arrivals):
        return None
    lags_ms = [(arrival - stamp) * 1000.0
               for arrival, stamp in zip(arrivals, stamps)]
    return {"median_ms": statistics.median(lags_ms)}


def nearest_metrics(reference_name, check):
    reference = sorted(check.stamps[reference_name])
    differences = []
    for lidar_stamp in check.stamps["lidar"]:
        index = bisect.bisect_left(reference, lidar_stamp)
        candidates = reference[max(0, index - 1):min(len(reference), index + 1)]
        if candidates:
            nearest = min(candidates, key=lambda stamp: abs(stamp - lidar_stamp))
            differences.append(abs(nearest - lidar_stamp))
    if not differences:
        return None
    return {"abs_p95_ms": percentile(differences, 0.95) * 1000.0}


def validate(check):
    failures = []
    rate_limits = {
        "lidar": (8.0, 12.0),
        "imu": (150.0, 260.0),
        "image": (25.0, 35.0),
    }
    for name, (minimum, maximum) in rate_limits.items():
        metrics = stream_metrics(name, check)
        if metrics is None:
            failures.append("%s has fewer than two current messages" % name)
            continue
        if not minimum <= metrics["rate"] <= maximum:
            failures.append("%s rate %.3f Hz is outside %.1f..%.1f Hz" %
                            (name, metrics["rate"], minimum, maximum))
        if metrics["regressions"] != 0:
            failures.append("%s has %d timestamp regressions" %
                            (name, metrics["regressions"]))

    arrival_lag_limits = {
        "imu": (-20.0, 80.0),
        "image": (-20.0, 120.0),
    }
    for name, (minimum_ms, maximum_ms) in arrival_lag_limits.items():
        metrics = arrival_lag_metrics(name, check)
        if metrics is None:
            failures.append("%s has no arrival lag samples" % name)
        elif not minimum_ms <= metrics["median_ms"] <= maximum_ms:
            failures.append(
                "%s arrival-minus-stamp median %.3f ms is outside %.1f..%.1f ms" %
                (name, metrics["median_ms"], minimum_ms, maximum_ms))

    if not check.point_counts:
        failures.append("lidar has no point counts")
    elif statistics.median(check.point_counts) < 9000:
        failures.append("lidar median point count is below 9000")

    if not check.scan_durations:
        failures.append("lidar has no scan duration")
    else:
        scan_ms = statistics.median(check.scan_durations) * 1000.0
        if not 80.0 <= scan_ms <= 120.0:
            failures.append("lidar scan duration %.3f ms is outside 80..120 ms" % scan_ms)

        lidar_lags_ms = [
            (arrival - stamp - scan_duration) * 1000.0
            for arrival, stamp, scan_duration in zip(
                check.arrivals["lidar"], check.stamps["lidar"],
                check.scan_durations)
        ]
        if lidar_lags_ms:
            scan_end_lag_ms = statistics.median(lidar_lags_ms)
            if not -20.0 <= scan_end_lag_ms <= 80.0:
                failures.append(
                    "lidar scan-end arrival lag median %.3f ms is outside -20..80 ms" %
                    scan_end_lag_ms)

    nearest_limits = {"imu": 10.0, "image": 25.0}
    for name, maximum_ms in nearest_limits.items():
        metrics = nearest_metrics(name, check)
        if metrics is None:
            failures.append("no lidar-to-%s timestamp pairs" % name)
        elif metrics["abs_p95_ms"] > maximum_ms:
            failures.append("nearest %s-to-lidar p95 %.3f ms exceeds %.1f ms" %
                            (name, metrics["abs_p95_ms"], maximum_ms))

    if failures:
        print("validation: FAIL")
        for failure in failures:
            print("  - %s" % failure)
        return False

    print("validation: PASS")
    return True


def main():
    parser = argparse.ArgumentParser(
        description="Measure FAST-LIVO2 sensor timestamp consistency.")
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--warmup", type=float, default=1.0)
    parser.add_argument("--validate", action="store_true",
                        help="Fail if rates or synchronization exceed rig limits.")
    args = parser.parse_args(rospy.myargv()[1:])

    rospy.init_node("fast_livo_sensor_timing_check", anonymous=True,
                    disable_signals=True)
    check = TimingCheck()
    subscribers = [
        rospy.Subscriber("/livox/lidar", CustomMsg, check.lidar_callback,
                         queue_size=100),
        rospy.Subscriber("/camera/imu", Imu, check.imu_callback,
                         queue_size=1000),
        rospy.Subscriber("/camera/color/image_raw", Image,
                         check.image_callback, queue_size=100),
    ]

    time.sleep(max(0.0, args.warmup))
    check.capturing = True
    start = time.monotonic()
    while time.monotonic() - start < args.duration and not rospy.is_shutdown():
        time.sleep(0.05)
    check.capturing = False

    print("capture_duration=%.3f s" % (time.monotonic() - start))
    for name in ("lidar", "imu", "image"):
        print_stream(name, check)
    if check.point_counts:
        print("lidar_points: median=%d range=%d..%d scan_duration_median=%.3f ms" %
              (int(statistics.median(check.point_counts)),
               min(check.point_counts), max(check.point_counts),
               statistics.median(check.scan_durations) * 1000.0))
    print_nearest("imu", check)
    print_nearest("image", check)

    valid = not args.validate or validate(check)

    # Keep references alive until all callbacks have stopped.
    del subscribers
    if not valid:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
