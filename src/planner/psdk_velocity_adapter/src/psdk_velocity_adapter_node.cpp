#include <cmath>
#include <arpa/inet.h>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <ros/ros.h>
#include <geometry_msgs/TwistStamped.h>
#include <nav_msgs/Odometry.h>
#include <quadrotor_msgs/PositionCommand.h>
#include <std_msgs/Float64MultiArray.h>
#include <visualization_msgs/Marker.h>

#include "psdk_velocity_adapter/velocity_adapter.hpp"

namespace {

using psdk_velocity_adapter::Convert;
using psdk_velocity_adapter::DjiVelocityCommand;
using psdk_velocity_adapter::Limits;
using psdk_velocity_adapter::OdomState;
using psdk_velocity_adapter::PlannerCommand;
using psdk_velocity_adapter::YawControllerState;

ros::Publisher command_pub;
ros::Publisher dji_tuple_pub;
ros::Publisher yaw_debug_pub;
ros::Publisher direction_pub;
ros::Publisher dji_direction_pub;
ros::Publisher corrected_odom_pub;
ros::Publisher corrected_axes_pub;
OdomState odom;
nav_msgs::Odometry latest_odom;
bool have_odom = false;
ros::WallTime last_odom_receive;
double odom_timeout_s = 0.5;
double odom_x = 0.0;
double odom_y = 0.0;
double odom_z = 0.0;
PlannerCommand latest;
bool have_command = false;
YawControllerState yaw_state;
Limits limits;
std::string output_frame;
int udp_socket_fd = -1;
sockaddr_in udp_destination{};
bool udp_enabled = false;
uint32_t udp_sequence = 0;

uint32_t Crc32(const uint8_t *data, size_t length)
{
  uint32_t crc = 0xffffffffu;
  for (size_t i = 0; i < length; ++i) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xedb88320u & (-(crc & 1u)));
    }
  }
  return ~crc;
}

void PutU32(uint8_t *dst, uint32_t value)
{
  const uint32_t network = htonl(value);
  std::memcpy(dst, &network, sizeof(network));
}

void PutU64(uint8_t *dst, uint64_t value)
{
  PutU32(dst, static_cast<uint32_t>(value >> 32));
  PutU32(dst + 4, static_cast<uint32_t>(value & 0xffffffffu));
}

void PutF32(uint8_t *dst, float value)
{
  uint32_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  PutU32(dst, bits);
}

void SendUdpCommand(const DjiVelocityCommand &command, const ros::Time &stamp)
{
  if (!udp_enabled || udp_socket_fd < 0) {
    return;
  }
  // DAIB velocity packet, v1, network byte order:
  // magic[4] version[1] type[1] reserved[2] seq[4] stamp_us[8]
  // x/y/z/yaw float32[4] crc32[4].
  uint8_t packet[40]{};
  packet[0] = 'D'; packet[1] = 'A'; packet[2] = 'I'; packet[3] = 'B';
  packet[4] = 1;
  packet[5] = 1;
  PutU32(packet + 8, udp_sequence++);
  PutU64(packet + 12, static_cast<uint64_t>(stamp.toSec() * 1e6));
  PutF32(packet + 20, static_cast<float>(command.valid ? command.x : 0.0));
  PutF32(packet + 24, static_cast<float>(command.valid ? command.y : 0.0));
  PutF32(packet + 28, static_cast<float>(command.valid ? command.z : 0.0));
  PutF32(packet + 32, static_cast<float>(command.valid ? command.yaw_deg_s : 0.0));
  PutU32(packet + 36, Crc32(packet, 36));
  if (sendto(udp_socket_fd, packet, 40, 0,
             reinterpret_cast<const sockaddr *>(&udp_destination),
             sizeof(udp_destination)) < 0) {
    ROS_WARN_THROTTLE(2.0, "PSDK UDP send failed: %s", std::strerror(errno));
  }
}

void OdomCallback(const nav_msgs::OdometryConstPtr &message)
{
  const auto &q = message->pose.pose.orientation;
  const double norm = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  if (!std::isfinite(norm) || norm < 1e-6) {
    odom.valid = false;
    have_odom = false;
    return;
  }
  const double qx = q.x / norm, qy = q.y / norm;
  const double qz = q.z / norm, qw = q.w / norm;
  latest_odom = *message;
  latest_odom.pose.pose.orientation.x = qx;
  latest_odom.pose.pose.orientation.y = qy;
  latest_odom.pose.pose.orientation.z = qz;
  latest_odom.pose.pose.orientation.w = qw;
  have_odom = true;
  last_odom_receive = ros::WallTime::now();
  const double sin_yaw = 2.0 * (qw * qz + qx * qy);
  const double cos_yaw = 1.0 - 2.0 * (qy * qy + qz * qz);
  odom.yaw_rad = std::atan2(sin_yaw, cos_yaw);
  odom.qx = qx;
  odom.qy = qy;
  odom.qz = qz;
  odom.qw = qw;
  if (limits.odom_child_optical) {
    // Aircraft +X (forward), expressed in the optical child frame after the
    // configured mounting correction, is [sin(offset), 0, cos(offset)].
    const double c = std::cos(limits.body_yaw_offset_rad);
    const double s = std::sin(limits.body_yaw_offset_rad);
    const double r00 = 1.0 - 2.0 * (qy * qy + qz * qz);
    const double r02 = 2.0 * (qx * qz + qw * qy);
    const double r10 = 2.0 * (qx * qy + qw * qz);
    const double r12 = 2.0 * (qy * qz - qw * qx);
    odom.body_yaw_rad = std::atan2(r10 * s + r12 * c,
                                   r00 * s + r02 * c);
  } else {
    odom.body_yaw_rad = psdk_velocity_adapter::WrapRadians(
        odom.yaw_rad + limits.body_yaw_offset_rad);
  }
  odom_x = message->pose.pose.position.x;
  odom_y = message->pose.pose.position.y;
  odom_z = message->pose.pose.position.z;
  odom.valid = true;
}

struct Rotation3 {
  double m[3][3]{};
};

Rotation3 Transpose(const Rotation3 &input)
{
  Rotation3 output;
  for (int row = 0; row < 3; ++row) {
    for (int col = 0; col < 3; ++col) {
      output.m[row][col] = input.m[col][row];
    }
  }
  return output;
}

Rotation3 OpticalToDjiBody(double yaw_offset_rad)
{
  // Requested display remap: old optical Z -> new X, old optical X -> new Y,
  // old optical Y -> new Z. This keeps a right-handed cyclic axis order.
  // Then apply the same fixed yaw correction as Convert().
  const double c = std::cos(yaw_offset_rad);
  const double s = std::sin(yaw_offset_rad);
  Rotation3 output;
  output.m[0][0] = s;
  output.m[0][1] = 0.0;
  output.m[0][2] = c;
  output.m[1][0] = c;
  output.m[1][1] = 0.0;
  output.m[1][2] = -s;
  output.m[2][0] = 0.0;
  output.m[2][1] = 1.0;
  output.m[2][2] = 0.0;
  return output;
}

geometry_msgs::Quaternion QuaternionFromRotation(const Rotation3 &r)
{
  geometry_msgs::Quaternion q;
  const double trace = r.m[0][0] + r.m[1][1] + r.m[2][2];
  if (trace > 0.0) {
    const double scale = 2.0 * std::sqrt(trace + 1.0);
    q.w = 0.25 * scale;
    q.x = (r.m[2][1] - r.m[1][2]) / scale;
    q.y = (r.m[0][2] - r.m[2][0]) / scale;
    q.z = (r.m[1][0] - r.m[0][1]) / scale;
  } else if (r.m[0][0] > r.m[1][1] && r.m[0][0] > r.m[2][2]) {
    const double scale = 2.0 * std::sqrt(1.0 + r.m[0][0] - r.m[1][1] - r.m[2][2]);
    q.w = (r.m[2][1] - r.m[1][2]) / scale;
    q.x = 0.25 * scale;
    q.y = (r.m[0][1] + r.m[1][0]) / scale;
    q.z = (r.m[0][2] + r.m[2][0]) / scale;
  } else if (r.m[1][1] > r.m[2][2]) {
    const double scale = 2.0 * std::sqrt(1.0 + r.m[1][1] - r.m[0][0] - r.m[2][2]);
    q.w = (r.m[0][2] - r.m[2][0]) / scale;
    q.x = (r.m[0][1] + r.m[1][0]) / scale;
    q.y = 0.25 * scale;
    q.z = (r.m[1][2] + r.m[2][1]) / scale;
  } else {
    const double scale = 2.0 * std::sqrt(1.0 + r.m[2][2] - r.m[0][0] - r.m[1][1]);
    q.w = (r.m[1][0] - r.m[0][1]) / scale;
    q.x = (r.m[0][2] + r.m[2][0]) / scale;
    q.y = (r.m[1][2] + r.m[2][1]) / scale;
    q.z = 0.25 * scale;
  }
  return q;
}

geometry_msgs::Quaternion Multiply(const geometry_msgs::Quaternion &a,
                                    const geometry_msgs::Quaternion &b)
{
  geometry_msgs::Quaternion q;
  q.w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
  q.x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y;
  q.y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x;
  q.z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w;
  return q;
}

void RotateVector(const Rotation3 &r, const geometry_msgs::Vector3 &input,
                  geometry_msgs::Vector3 &output)
{
  output.x = r.m[0][0] * input.x + r.m[0][1] * input.y + r.m[0][2] * input.z;
  output.y = r.m[1][0] * input.x + r.m[1][1] * input.y + r.m[1][2] * input.z;
  output.z = r.m[2][0] * input.x + r.m[2][1] * input.y + r.m[2][2] * input.z;
}

void PublishCorrectedOdom(const ros::Time &stamp)
{
  if (!have_odom) {
    return;
  }
  nav_msgs::Odometry corrected = latest_odom;
  corrected.header.stamp = stamp;
  corrected.child_frame_id = "dji_body";
  if (limits.odom_child_optical) {
    const Rotation3 optical_to_body = OpticalToDjiBody(limits.body_yaw_offset_rad);
    const geometry_msgs::Quaternion body_to_optical =
        QuaternionFromRotation(Transpose(optical_to_body));
    corrected.pose.pose.orientation =
        Multiply(latest_odom.pose.pose.orientation, body_to_optical);
    RotateVector(optical_to_body, latest_odom.twist.twist.linear,
                 corrected.twist.twist.linear);
    RotateVector(optical_to_body, latest_odom.twist.twist.angular,
                 corrected.twist.twist.angular);
  }
  corrected_odom_pub.publish(corrected);

  // Foxglove versions without an Odometry/Pose 3D display can still render
  // this Marker as the corrected body axes: red X, green Y, blue Z.
  visualization_msgs::Marker axes;
  axes.header = corrected.header;
  axes.ns = "corrected_odom_axes";
  axes.id = 0;
  axes.type = visualization_msgs::Marker::LINE_LIST;
  axes.action = visualization_msgs::Marker::ADD;
  axes.pose.orientation.w = 1.0;
  axes.scale.x = 0.035;
  axes.color.a = 1.0;
  geometry_msgs::Point origin = corrected.pose.pose.position;
  geometry_msgs::Point x_end = origin;
  geometry_msgs::Point y_end = origin;
  geometry_msgs::Point z_end = origin;
  const auto &q = corrected.pose.pose.orientation;
  const double r00 = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
  const double r01 = 2.0 * (q.x * q.y - q.w * q.z);
  const double r02 = 2.0 * (q.x * q.z + q.w * q.y);
  const double r10 = 2.0 * (q.x * q.y + q.w * q.z);
  const double r11 = 1.0 - 2.0 * (q.x * q.x + q.z * q.z);
  const double r12 = 2.0 * (q.y * q.z - q.w * q.x);
  const double r20 = 2.0 * (q.x * q.z - q.w * q.y);
  const double r21 = 2.0 * (q.y * q.z + q.w * q.x);
  const double r22 = 1.0 - 2.0 * (q.x * q.x + q.y * q.y);
  constexpr double kAxisLength = 0.6;
  x_end.x += kAxisLength * r00;
  x_end.y += kAxisLength * r10;
  x_end.z += kAxisLength * r20;
  y_end.x += kAxisLength * r01;
  y_end.y += kAxisLength * r11;
  y_end.z += kAxisLength * r21;
  z_end.x += kAxisLength * r02;
  z_end.y += kAxisLength * r12;
  z_end.z += kAxisLength * r22;
  axes.points = {origin, x_end, origin, y_end, origin, z_end};
  std_msgs::ColorRGBA red, green, blue;
  red.r = 1.0; red.a = 1.0;
  green.g = 1.0; green.a = 1.0;
  blue.b = 1.0; blue.a = 1.0;
  axes.colors = {red, red, green, green, blue, blue};
  corrected_axes_pub.publish(axes);
}

void CommandCallback(const quadrotor_msgs::PositionCommandConstPtr &message)
{
  latest.vx = message->velocity.x;
  latest.vy = message->velocity.y;
  latest.vz = message->velocity.z;
  latest.yaw_rad = message->yaw;
  latest.yaw_dot_rad_s = message->yaw_dot;
  latest.stamp_s = message->header.stamp.toSec();
  if (latest.stamp_s <= 0.0) {
    latest.stamp_s = ros::Time::now().toSec();
  }
  have_command = true;
}

void PublishCallback(const ros::TimerEvent &event)
{
  PublishCorrectedOdom(event.current_real);
  geometry_msgs::TwistStamped output;
  output.header.stamp = event.current_real;
  output.header.frame_id = output_frame;
  DjiVelocityCommand converted;
  OdomState control_odom = odom;
  control_odom.valid = control_odom.valid && have_odom &&
      (ros::WallTime::now() - last_odom_receive).toSec() <= odom_timeout_s;
  if (have_command) {
    converted = Convert(latest, control_odom, event.current_real.toSec(), limits,
                        &yaw_state);
    if (converted.valid) {
      output.twist.linear.x = converted.x;
      output.twist.linear.y = converted.y;
      output.twist.linear.z = converted.z;
      output.twist.angular.z = converted.yaw_deg_s * M_PI / 180.0;
    }
  }
  command_pub.publish(output);

  // Explicit DJI tuple: data = [x_mps, y_mps, z_mps, yaw_deg_s]. Keep this
  // separate from TwistStamped, whose angular.z is required to be rad/s.
  std_msgs::Float64MultiArray dji_tuple;
  dji_tuple.layout.dim.resize(1);
  dji_tuple.layout.dim[0].label = "x_mps,y_mps,z_mps,yaw_deg_s";
  dji_tuple.layout.dim[0].size = 4;
  dji_tuple.layout.dim[0].stride = 4;
  dji_tuple.data = {converted.valid ? converted.x : 0.0,
                    converted.valid ? converted.y : 0.0,
                    converted.valid ? converted.z : 0.0,
                    converted.valid ? converted.yaw_deg_s : 0.0};
  dji_tuple_pub.publish(dji_tuple);

  std_msgs::Float64MultiArray yaw_debug;
  yaw_debug.layout.dim.resize(1);
  yaw_debug.layout.dim[0].label =
      "target_deg,actual_deg,error_deg,planner_rate_deg_s,ros_rate_deg_s,dji_rate_deg_s";
  yaw_debug.layout.dim[0].size = 6;
  yaw_debug.layout.dim[0].stride = 6;
  const double target_deg = latest.yaw_rad * 180.0 / M_PI;
  const double actual_deg = control_odom.body_yaw_rad * 180.0 / M_PI;
  const double error_deg = psdk_velocity_adapter::WrapRadians(
      latest.yaw_rad - control_odom.body_yaw_rad) * 180.0 / M_PI;
  yaw_debug.data = {target_deg,
                    actual_deg,
                    have_command && control_odom.valid ? error_deg : 0.0,
                    latest.yaw_dot_rad_s * 180.0 / M_PI,
                    converted.valid ? yaw_state.rate_deg_s : 0.0,
                    converted.valid ? converted.yaw_deg_s : 0.0};
  yaw_debug_pub.publish(yaw_debug);
  SendUdpCommand(converted, event.current_real);

  // Keep visualization in the planner's world frame so it can be compared
  // directly with camera_init point clouds and the B-spline trajectory.
  visualization_msgs::Marker marker;
  marker.header.stamp = event.current_real;
  marker.header.frame_id = "camera_init";
  marker.ns = "psdk_velocity_direction";
  marker.id = 0;
  marker.type = visualization_msgs::Marker::ARROW;
  marker.action = visualization_msgs::Marker::ADD;
  marker.pose.orientation.w = 1.0;
  marker.scale.x = 0.08;
  marker.scale.y = 0.16;
  marker.scale.z = 0.16;
  marker.color.r = 1.0;
  marker.color.g = 0.15;
  marker.color.b = 0.05;
  marker.color.a = 1.0;
  geometry_msgs::Point start;
  start.x = odom_x;
  start.y = odom_y;
  start.z = odom_z;
  geometry_msgs::Point end = start;
  if (have_command && odom.valid) {
    if (converted.valid) {
      constexpr double kArrowSeconds = 2.0;
      end.x += latest.vx * kArrowSeconds;
      end.y += latest.vy * kArrowSeconds;
      end.z += latest.vz * kArrowSeconds;
    }
  }
  marker.points.push_back(start);
  marker.points.push_back(end);
  direction_pub.publish(marker);

  // Visualize the post-conversion DJI-style command in the world frame. The
  // command itself is body-frame when output_body_frame is enabled, so rotate
  // it back only for visualization and keep the actual ROS output unchanged.
  visualization_msgs::Marker dji_marker = marker;
  dji_marker.ns = "psdk_velocity_direction_dji";
  dji_marker.color.r = 0.05;
  dji_marker.color.g = 0.85;
  dji_marker.color.b = 1.0;
  geometry_msgs::Point dji_end = start;
  if (converted.valid && odom.valid) {
    double world_x = converted.x;
    double world_y = converted.y;
    if (limits.output_body_frame && limits.odom_child_optical) {
      // Inverse of optical -> FRU and the fixed yaw alignment. First recover
      // the aligned FRU vector, then map it back to optical axes.
      const double c = std::cos(limits.body_yaw_offset_rad);
      const double s = std::sin(limits.body_yaw_offset_rad);
      const double body_y = limits.dji_y_sign != 0.0
                                ? converted.y / limits.dji_y_sign
                                : converted.y;
      const double fru_x = c * converted.x - s * body_y;
      const double fru_y = s * converted.x + c * body_y;
      const double child_x = fru_y;
      const double child_y = 0.0;
      const double child_z = fru_x;
      const double x = odom.qx, y = odom.qy, z = odom.qz, w = odom.qw;
      const double r00 = 1.0 - 2.0 * (y * y + z * z);
      const double r01 = 2.0 * (x * y - w * z);
      const double r02 = 2.0 * (x * z + w * y);
      const double r10 = 2.0 * (x * y + w * z);
      const double r11 = 1.0 - 2.0 * (x * x + z * z);
      const double r12 = 2.0 * (y * z - w * x);
      world_x = r00 * child_x + r01 * child_y + r02 * child_z;
      world_y = r10 * child_x + r11 * child_y + r12 * child_z;
    } else if (limits.output_body_frame) {
      double body_y = limits.dji_y_sign * converted.y;
      const double yaw = odom.yaw_rad + limits.body_yaw_offset_rad;
      const double c = std::cos(yaw);
      const double s = std::sin(yaw);
      world_x = c * converted.x - s * body_y;
      world_y = s * converted.x + c * body_y;
    }
    constexpr double kArrowSeconds = 2.0;
    dji_end.x += world_x * kArrowSeconds;
    dji_end.y += world_y * kArrowSeconds;
    dji_end.z += converted.z * kArrowSeconds;
  }
  dji_marker.points.clear();
  dji_marker.points.push_back(start);
  dji_marker.points.push_back(dji_end);
  dji_direction_pub.publish(dji_marker);
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
  private_nh.param<std::string>("command_topic", command_topic, "/daib_ego/position_cmd");
  private_nh.param<std::string>("odom_topic", odom_topic, "/daib_slam/odom");
  private_nh.param<std::string>("output_topic", output_topic, "/psdk/velocity_command");
  private_nh.param<std::string>("output_frame", output_frame, "body");
  private_nh.param("horizontal_limit_m_s", limits.horizontal_m_s, limits.horizontal_m_s);
  private_nh.param("vertical_limit_m_s", limits.vertical_m_s, limits.vertical_m_s);
  private_nh.param("yaw_limit_deg_s", limits.yaw_deg_s, limits.yaw_deg_s);
  private_nh.param("yaw_accel_deg_s2", limits.yaw_accel_deg_s2,
                   limits.yaw_accel_deg_s2);
  private_nh.param("yaw_kp", limits.yaw_kp, limits.yaw_kp);
  private_nh.param("yaw_deadband_deg", limits.yaw_deadband_deg,
                   limits.yaw_deadband_deg);
  private_nh.param("stale_timeout_s", limits.stale_timeout_s, limits.stale_timeout_s);
  private_nh.param("odom_timeout_s", odom_timeout_s, odom_timeout_s);
  odom_timeout_s = std::max(0.05, odom_timeout_s);
  private_nh.param("output_body_frame", limits.output_body_frame, limits.output_body_frame);
  private_nh.param("odom_child_optical", limits.odom_child_optical, limits.odom_child_optical);
  double body_yaw_offset_deg = 0.0;
  private_nh.param("body_yaw_offset_deg", body_yaw_offset_deg, body_yaw_offset_deg);
  limits.body_yaw_offset_rad = body_yaw_offset_deg * M_PI / 180.0;
  private_nh.param("dji_y_sign", limits.dji_y_sign, limits.dji_y_sign);
  private_nh.param("dji_yaw_sign", limits.dji_yaw_sign, limits.dji_yaw_sign);
  std::string udp_host;
  int udp_port = 19090;
  private_nh.param("udp_enabled", udp_enabled, false);
  private_nh.param("udp_host", udp_host, std::string("127.0.0.1"));
  private_nh.param("udp_port", udp_port, udp_port);
  if (udp_enabled) {
    udp_socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (udp_socket_fd < 0 || inet_pton(AF_INET, udp_host.c_str(),
                                       &udp_destination.sin_addr) != 1 ||
        udp_port < 1 || udp_port > 65535) {
      ROS_FATAL("Invalid PSDK UDP destination %s:%d", udp_host.c_str(), udp_port);
      return 2;
    }
    udp_destination.sin_family = AF_INET;
    udp_destination.sin_port = htons(static_cast<uint16_t>(udp_port));
    ROS_WARN("PSDK UDP output ENABLED to %s:%d; receiver must remain dry-run",
             udp_host.c_str(), udp_port);
  }

  command_pub = nh.advertise<geometry_msgs::TwistStamped>(output_topic, 20);
  dji_tuple_pub = nh.advertise<std_msgs::Float64MultiArray>(
      "/psdk/dji_command_xyz_yaw", 20);
  yaw_debug_pub = nh.advertise<std_msgs::Float64MultiArray>(
      "/psdk/yaw_control_debug", 20);
  direction_pub = nh.advertise<visualization_msgs::Marker>(
      "/psdk/velocity_direction_world", 1, true);
  dji_direction_pub = nh.advertise<visualization_msgs::Marker>(
      "/psdk/velocity_direction_dji_world", 1, true);
  corrected_odom_pub = nh.advertise<nav_msgs::Odometry>(
      "/psdk/odom_corrected", 10, true);
  corrected_axes_pub = nh.advertise<visualization_msgs::Marker>(
      "/psdk/odom_corrected_axes", 1, true);
  ros::Subscriber command_sub = nh.subscribe(command_topic, 20, CommandCallback);
  ros::Subscriber odom_sub = nh.subscribe(odom_topic, 20, OdomCallback);
  ros::Timer timer = nh.createTimer(ros::Duration(0.05), PublishCallback);
  ros::spin();
  if (udp_socket_fd >= 0) {
    close(udp_socket_fd);
  }
  return 0;
}
