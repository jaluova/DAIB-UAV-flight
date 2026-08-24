#include <cmath>
#include <ros/ros.h>
#include <geometry_msgs/TwistStamped.h>
#include <nav_msgs/Odometry.h>
#include <quadrotor_msgs/PositionCommand.h>

#include "psdk_velocity_adapter/velocity_adapter.hpp"

namespace {

using psdk_velocity_adapter::Convert;
using psdk_velocity_adapter::Limits;
using psdk_velocity_adapter::OdomState;
using psdk_velocity_adapter::PlannerCommand;

ros::Publisher command_pub;
OdomState odom;
PlannerCommand latest;
bool have_command = false;
Limits limits;
std::string output_frame;

void OdomCallback(const nav_msgs::OdometryConstPtr &message)
{
  const auto &q = message->pose.pose.orientation;
  const double sin_yaw = 2.0 * (q.w * q.z + q.x * q.y);
  const double cos_yaw = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
  odom.yaw_rad = std::atan2(sin_yaw, cos_yaw);
  odom.valid = true;
}

void CommandCallback(const quadrotor_msgs::PositionCommandConstPtr &message)
{
  latest.vx = message->velocity.x;
  latest.vy = message->velocity.y;
  latest.vz = message->velocity.z;
  latest.yaw_dot_rad_s = message->yaw_dot;
  latest.stamp_s = message->header.stamp.toSec();
  if (latest.stamp_s <= 0.0) {
    latest.stamp_s = ros::Time::now().toSec();
  }
  have_command = true;
}

void PublishCallback(const ros::TimerEvent &event)
{
  geometry_msgs::TwistStamped output;
  output.header.stamp = event.current_real;
  output.header.frame_id = output_frame;
  if (have_command) {
    const auto converted = Convert(latest, odom, event.current_real.toSec(), limits);
    if (converted.valid) {
      output.twist.linear.x = converted.x;
      output.twist.linear.y = converted.y;
      output.twist.linear.z = converted.z;
      output.twist.angular.z = converted.yaw_deg_s * M_PI / 180.0;
    }
  }
  command_pub.publish(output);
}

}  // namespace

int main(int argc, char **argv)
{
  ros::init(argc, argv, "psdk_velocity_adapter");
  ros::NodeHandle nh;
  ros::NodeHandle private_nh("~");

  std::string command_topic;
  std::string odom_topic;
  std::string output_topic;
  private_nh.param<std::string>("command_topic", command_topic, "/position_cmd");
  private_nh.param<std::string>("odom_topic", odom_topic, "/daib_slam/odom");
  private_nh.param<std::string>("output_topic", output_topic, "/psdk/velocity_command");
  private_nh.param<std::string>("output_frame", output_frame, "body");
  private_nh.param("horizontal_limit_m_s", limits.horizontal_m_s, limits.horizontal_m_s);
  private_nh.param("vertical_limit_m_s", limits.vertical_m_s, limits.vertical_m_s);
  private_nh.param("yaw_limit_deg_s", limits.yaw_deg_s, limits.yaw_deg_s);
  private_nh.param("stale_timeout_s", limits.stale_timeout_s, limits.stale_timeout_s);
  private_nh.param("output_body_frame", limits.output_body_frame, limits.output_body_frame);

  command_pub = nh.advertise<geometry_msgs::TwistStamped>(output_topic, 20);
  ros::Subscriber command_sub = nh.subscribe(command_topic, 20, CommandCallback);
  ros::Subscriber odom_sub = nh.subscribe(odom_topic, 20, OdomCallback);
  ros::Timer timer = nh.createTimer(ros::Duration(0.05), PublishCallback);
  ros::spin();
  return 0;
}
