#!/usr/bin/env python3
"""Republish the latched Explorer goal with a fresh receive age.

Used only after restarting the observation planner. The bridge still applies
its normal frame, odom, distance and bounds validation.
"""
import time
import rospy
from geometry_msgs.msg import PoseStamped


def main():
    rospy.init_node("daib_goal_refresh", anonymous=True, disable_rosout=True)
    publisher = rospy.Publisher("/daib_explorer/goal", PoseStamped,
                                queue_size=1, latch=True)
    received = {"goal": None}

    def callback(message):
        if received["goal"] is None:
            received["goal"] = message

    subscriber = rospy.Subscriber("/daib_explorer/goal", PoseStamped,
                                  callback, queue_size=1)
    deadline = time.monotonic() + 4.0
    while received["goal"] is None and time.monotonic() < deadline:
        time.sleep(0.05)
    subscriber.unregister()
    if received["goal"] is None:
        return 2

    goal = PoseStamped()
    goal.header = received["goal"].header
    goal.header.stamp = rospy.Time(0)
    goal.pose = received["goal"].pose
    deadline = time.monotonic() + 3.0
    while publisher.get_num_connections() == 0 and time.monotonic() < deadline:
        time.sleep(0.05)
    for _ in range(5):
        publisher.publish(goal)
        time.sleep(0.1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
