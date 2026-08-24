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
  command.stamp_s = 1.0;
  OdomState odom;
  odom.valid = true;

  DjiVelocityCommand output = Convert(command, odom, 1.05, limits);
  assert(output.valid);
  assert(std::abs(output.x - 0.5) < 1e-9);
  assert(std::abs(output.y) < 1e-9);
  assert(std::abs(output.z - 0.2) < 1e-9);
  assert(std::abs(output.yaw_deg_s - 10.0) < 1e-9);

  command.vx = 1.0;
  command.vy = 0.0;
  odom.yaw_rad = M_PI / 2.0;
  output = Convert(command, odom, 1.05, limits);
  assert(output.valid);
  assert(std::abs(output.x) < 1e-9);
  assert(std::abs(output.y + 0.5) < 1e-9);

  command.stamp_s = 0.0;
  output = Convert(command, odom, 1.0, limits);
  assert(!output.valid);
  return 0;
}
