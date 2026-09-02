#!/usr/bin/env python3
"""Replace a clicked goal's altitude with the latest aircraft odometry Z."""

import threading

import rospy
from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import Odometry


class GoalAltitudeBridge:
    def __init__(self):
        input_topic = rospy.get_param("~input_topic", "/daib_ego/goal_raw")
        output_topic = rospy.get_param("~output_topic", "/daib_ego/goal")
        odom_topic = rospy.get_param("~odom_topic", "/daib_slam/odom")
        self._lock = threading.Lock()
        self._latest_z = None
        self._publisher = rospy.Publisher(output_topic, PoseStamped,
                                          queue_size=1, latch=True)
        rospy.Subscriber(odom_topic, Odometry, self._odom_callback,
                         queue_size=1, tcp_nodelay=True)
        rospy.Subscriber(input_topic, PoseStamped, self._goal_callback,
                         queue_size=1, tcp_nodelay=True)
        rospy.loginfo("[goal altitude bridge] %s -> %s, odom=%s",
                      input_topic, output_topic, odom_topic)

    def _odom_callback(self, message):
        z = message.pose.pose.position.z
        if z == z and abs(z) != float("inf"):
            with self._lock:
                self._latest_z = z

    def _goal_callback(self, message):
        with self._lock:
            z = self._latest_z
        if z is None:
            rospy.logwarn_throttle(2.0,
                                   "[goal altitude bridge] waiting for odometry")
            return
        goal = PoseStamped()
        goal.header = message.header
        goal.pose = message.pose
        goal.pose.position.z = z
        self._publisher.publish(goal)
        rospy.loginfo("[goal altitude bridge] goal=(%.3f, %.3f, %.3f)",
                      goal.pose.position.x, goal.pose.position.y, z)


if __name__ == "__main__":
    # openEuler's Python 3.11 ROS logging can recurse during rosout setup.
    rospy.init_node("goal_altitude_bridge", disable_rosout=True)
    GoalAltitudeBridge()
    rospy.spin()
