#ifndef PSDK_VELOCITY_ADAPTER_VELOCITY_ADAPTER_HPP
#define PSDK_VELOCITY_ADAPTER_VELOCITY_ADAPTER_HPP

#include <algorithm>
#include <cmath>

namespace psdk_velocity_adapter {

struct PlannerCommand {
  double vx = 0.0;
  double vy = 0.0;
  double vz = 0.0;
  double yaw_dot_rad_s = 0.0;
  double stamp_s = 0.0;
};

struct OdomState {
  double yaw_rad = 0.0;
  bool valid = false;
};

struct DjiVelocityCommand {
  double x = 0.0;
  double y = 0.0;
  double z = 0.0;
  double yaw_deg_s = 0.0;
  bool valid = false;
};

struct Limits {
  double horizontal_m_s = 0.5;
  double vertical_m_s = 0.2;
  double yaw_deg_s = 10.0;
  double stale_timeout_s = 0.2;
  bool output_body_frame = true;
  bool planner_z_positive_up = true;
};

inline double Clamp(double value, double low, double high)
{
  return std::max(low, std::min(value, high));
}

inline bool Finite(double value)
{
  return std::isfinite(value);
}

inline DjiVelocityCommand Convert(const PlannerCommand &planner,
                                  const OdomState &odom,
                                  double now_s,
                                  const Limits &limits)
{
  DjiVelocityCommand output;
  if (!Finite(planner.vx) || !Finite(planner.vy) || !Finite(planner.vz) ||
      !Finite(planner.yaw_dot_rad_s) || !Finite(planner.stamp_s) ||
      now_s - planner.stamp_s > limits.stale_timeout_s ||
      now_s < planner.stamp_s) {
    return output;
  }
  if (limits.output_body_frame && !odom.valid) {
    return output;
  }

  double vx = planner.vx;
  double vy = planner.vy;
  if (limits.output_body_frame) {
    const double c = std::cos(odom.yaw_rad);
    const double s = std::sin(odom.yaw_rad);
    const double body_x = c * vx + s * vy;
    const double body_y = -s * vx + c * vy;
    vx = body_x;
    vy = body_y;
  }

  const double horizontal = std::hypot(vx, vy);
  if (horizontal > limits.horizontal_m_s && horizontal > 0.0) {
    const double scale = limits.horizontal_m_s / horizontal;
    vx *= scale;
    vy *= scale;
  }

  output.x = vx;
  output.y = vy;
  output.z = Clamp(limits.planner_z_positive_up ? planner.vz : -planner.vz,
                   -limits.vertical_m_s, limits.vertical_m_s);
  output.yaw_deg_s = Clamp(planner.yaw_dot_rad_s * 180.0 / M_PI,
                           -limits.yaw_deg_s, limits.yaw_deg_s);
  output.valid = true;
  return output;
}

}  // namespace psdk_velocity_adapter

#endif  // PSDK_VELOCITY_ADAPTER_VELOCITY_ADAPTER_HPP
