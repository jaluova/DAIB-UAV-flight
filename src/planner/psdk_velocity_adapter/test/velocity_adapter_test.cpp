#include <cassert>
#include <cmath>

#include "psdk_velocity_adapter/velocity_adapter.hpp"

using namespace psdk_velocity_adapter;

int main()
{
  Limits limits;
  limits.horizontal_m_s = 0.5;
  limits.vertical_m_s = 0.2;
  limits.yaw_deg_s = 10.0;

  PlannerCommand command;
  command.vx = 1.0;
  command.vy = 0.0;
  command.vz = 0.5;
  command.yaw_dot_rad_s = M_PI;
  command.yaw_rad = 0.0;
  command.stamp_s = 1.0;
  OdomState odom;
  odom.valid = true;

  DjiVelocityCommand output = Convert(command, odom, 1.05, limits);
  assert(output.valid);
  assert(std::abs(output.x - 0.5) < 1e-9);
  assert(std::abs(output.y) < 1e-9);
  assert(std::abs(output.z - 0.2) < 1e-9);
  assert(std::abs(output.yaw_deg_s + 10.0) < 1e-9);

  command.vx = 1.0;
  command.vy = 0.0;
  odom.yaw_rad = M_PI / 2.0;
  output = Convert(command, odom, 1.05, limits);
  assert(output.valid);
  assert(std::abs(output.x) < 1e-9);
  assert(std::abs(output.y - 0.5) < 1e-9);

  command.stamp_s = 0.0;
  output = Convert(command, odom, 1.0, limits);
  assert(!output.valid);

  // With an identity optical child orientation, world +X is optical +X,
  // which maps to FRU +Y. A +90 degree mounting correction maps it to +X.
  limits.odom_child_optical = true;
  limits.body_yaw_offset_rad = M_PI / 2.0;
  command.vx = 1.0;
  command.vy = 0.0;
  command.vz = 0.0;
  command.yaw_dot_rad_s = 0.0;
  command.stamp_s = 1.0;
  odom.qx = 0.0;
  odom.qy = 0.0;
  odom.qz = 0.0;
  odom.qw = 1.0;
  output = Convert(command, odom, 1.05, limits);
  assert(output.valid);
  assert(std::abs(output.x - 0.5) < 1e-9);
  assert(std::abs(output.y) < 1e-9);

  // Closed-loop yaw uses the shortest angular error, not planner yaw_dot.
  limits.yaw_deg_s = 3.0;
  limits.yaw_accel_deg_s2 = 3.0;
  limits.yaw_kp = 0.5;
  limits.yaw_deadband_deg = 1.0;
  command.yaw_rad = 170.0 * M_PI / 180.0;
  command.yaw_dot_rad_s = -M_PI;
  command.stamp_s = 2.0;
  odom.yaw_rad = -170.0 * M_PI / 180.0;
  odom.body_yaw_rad = odom.yaw_rad;
  YawControllerState yaw_state;
  output = Convert(command, odom, 2.05, limits, &yaw_state);
  assert(output.valid);
  assert(std::abs(output.yaw_deg_s - 0.15) < 1e-9);
  output = Convert(command, odom, 2.10, limits, &yaw_state);
  assert(std::abs(output.yaw_deg_s - 0.30) < 1e-9);

  // Once the measured yaw reaches the target, command zero regardless of
  // the planner's feed-forward yaw_dot.
  odom.yaw_rad = command.yaw_rad;
  odom.body_yaw_rad = command.yaw_rad;
  output = Convert(command, odom, 2.15, limits, &yaw_state);
  assert(std::abs(output.yaw_deg_s - 0.15) < 1e-9);
  output = Convert(command, odom, 2.20, limits, &yaw_state);
  assert(std::abs(output.yaw_deg_s) < 1e-9);

  // A stale command must stop output and reset the slew-rate state.
  command.yaw_rad = -170.0 * M_PI / 180.0;
  command.stamp_s = 2.0;
  output = Convert(command, odom, 2.50, limits, &yaw_state);
  assert(!output.valid);
  assert(!yaw_state.initialized);
  assert(std::abs(yaw_state.rate_deg_s) < 1e-9);
  return 0;
}
