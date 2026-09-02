#ifndef PSDK_VELOCITY_ADAPTER_VELOCITY_ADAPTER_HPP
#define PSDK_VELOCITY_ADAPTER_VELOCITY_ADAPTER_HPP

#include <algorithm>
#include <cmath>

namespace psdk_velocity_adapter {

struct PlannerCommand {
  double vx = 0.0;
  double vy = 0.0;
  double vz = 0.0;
  double yaw_rad = 0.0;
  double yaw_dot_rad_s = 0.0;
  double stamp_s = 0.0;
};

struct OdomState {
  double yaw_rad = 0.0;
  double body_yaw_rad = 0.0;
  double qx = 0.0;
  double qy = 0.0;
  double qz = 0.0;
  double qw = 1.0;
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
  double yaw_deg_s = 3.0;
  double yaw_accel_deg_s2 = 3.0;
  double yaw_kp = 0.5;
  double yaw_deadband_deg = 1.0;
  double stale_timeout_s = 0.2;
  bool output_body_frame = true;
  bool planner_z_positive_up = true;
  // FAST-LIVO's current child frame is the D435 IMU optical frame. In that
  // frame +Z points forward, +X right, +Y down; DJI FRU is +X forward,
  // +Y right, +Z up. Enable this only when odom child_frame_id is optical.
  bool odom_child_optical = false;
  // Fixed yaw alignment from the odometry child frame to the aircraft FRU
  // body frame. Keep zero unless the sensor/airframe mounting is calibrated.
  double body_yaw_offset_rad = 0.0;
  // DJI body convention: +Y is right and +yaw is right. Planner/ROS uses
  // the opposite signs for these two axes.
  double dji_y_sign = -1.0;
  double dji_yaw_sign = -1.0;
};

struct YawControllerState {
  double rate_deg_s = 0.0;
  double last_time_s = 0.0;
  bool initialized = false;
};

inline double Clamp(double value, double low, double high)
{
  return std::max(low, std::min(value, high));
}

inline bool Finite(double value)
{
  return std::isfinite(value);
}

inline double WrapRadians(double angle)
{
  while (angle > M_PI) angle -= 2.0 * M_PI;
  while (angle <= -M_PI) angle += 2.0 * M_PI;
  return angle;
}

inline void ResetYawController(YawControllerState &state)
{
  state.rate_deg_s = 0.0;
  state.last_time_s = 0.0;
  state.initialized = false;
}

inline double ClosedLoopYawRate(const PlannerCommand &planner,
                                const OdomState &odom,
                                double now_s,
                                const Limits &limits,
                                YawControllerState &state)
{
  if (!odom.valid || !Finite(planner.yaw_rad) || !Finite(now_s)) {
    state.rate_deg_s = 0.0;
    state.last_time_s = now_s;
    state.initialized = false;
    return 0.0;
  }

  double dt = 0.05;
  if (state.initialized) {
    const double measured_dt = now_s - state.last_time_s;
    if (Finite(measured_dt) && measured_dt > 1e-4 && measured_dt <= 0.5)
      dt = measured_dt;
  }
  state.last_time_s = now_s;
  state.initialized = true;

  const double error_rad = WrapRadians(planner.yaw_rad - odom.body_yaw_rad);
  const double error_deg = error_rad * 180.0 / M_PI;
  double target_rate = 0.0;
  if (std::abs(error_deg) > std::max(0.0, limits.yaw_deadband_deg)) {
    target_rate = Clamp(limits.yaw_kp * error_deg,
                        -std::abs(limits.yaw_deg_s),
                        std::abs(limits.yaw_deg_s));
  }

  const double max_step = std::abs(limits.yaw_accel_deg_s2) * dt;
  if (max_step > 0.0) {
    target_rate = Clamp(target_rate, state.rate_deg_s - max_step,
                        state.rate_deg_s + max_step);
  }
  state.rate_deg_s = target_rate;
  return target_rate;
}

inline void WorldToChild(const OdomState &odom, double wx, double wy, double wz,
                         double &cx, double &cy, double &cz)
{
  const double x = odom.qx, y = odom.qy, z = odom.qz, w = odom.qw;
  const double r00 = 1.0 - 2.0 * (y * y + z * z);
  const double r01 = 2.0 * (x * y - w * z);
  const double r02 = 2.0 * (x * z + w * y);
  const double r10 = 2.0 * (x * y + w * z);
  const double r11 = 1.0 - 2.0 * (x * x + z * z);
  const double r12 = 2.0 * (y * z - w * x);
  const double r20 = 2.0 * (x * z - w * y);
  const double r21 = 2.0 * (y * z + w * x);
  const double r22 = 1.0 - 2.0 * (x * x + y * y);
  // The odometry quaternion is child -> world, so transpose it here.
  cx = r00 * wx + r10 * wy + r20 * wz;
  cy = r01 * wx + r11 * wy + r21 * wz;
  cz = r02 * wx + r12 * wy + r22 * wz;
}

inline DjiVelocityCommand Convert(const PlannerCommand &planner,
                                  const OdomState &odom,
                                  double now_s,
                                  const Limits &limits,
                                  YawControllerState *yaw_state = nullptr)
{
  DjiVelocityCommand output;
  if (!Finite(planner.vx) || !Finite(planner.vy) || !Finite(planner.vz) ||
      !Finite(planner.yaw_rad) ||
      !Finite(planner.yaw_dot_rad_s) || !Finite(planner.stamp_s) ||
      now_s - planner.stamp_s > limits.stale_timeout_s ||
      now_s < planner.stamp_s) {
    if (yaw_state != nullptr) ResetYawController(*yaw_state);
    return output;
  }
  if ((limits.output_body_frame || yaw_state != nullptr) && !odom.valid) {
    if (yaw_state != nullptr) ResetYawController(*yaw_state);
    return output;
  }

  double vx = planner.vx;
  double vy = planner.vy;
  const double vz = limits.planner_z_positive_up ? planner.vz : -planner.vz;
  if (limits.output_body_frame && limits.odom_child_optical) {
    double child_x = 0.0, child_y = 0.0, child_z = 0.0;
    // Horizontal BODY mode follows aircraft heading, while DJI vertical
    // velocity remains ground-up. Do not rotate planner vz into the body.
    WorldToChild(odom, vx, vy, 0.0, child_x, child_y, child_z);
    // D435 optical -> DJI FRU horizontal axes: x_f=+z_o, y_f=+x_o.
    // Apply any fixed camera-to-airframe yaw alignment after this axis map.
    // The same sign convention as the non-optical path is used: a positive
    // offset rotates world velocity into the corrected body frame.
    const double c = std::cos(limits.body_yaw_offset_rad);
    const double s = std::sin(limits.body_yaw_offset_rad);
    const double fru_x = child_z;
    const double fru_y = child_x;
    vx = c * fru_x + s * fru_y;
    vy = -s * fru_x + c * fru_y;
  } else if (limits.output_body_frame) {
    const double yaw = odom.yaw_rad + limits.body_yaw_offset_rad;
    const double c = std::cos(yaw);
    const double s = std::sin(yaw);
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
  // Apply the DJI lateral sign convention in both optical and regular body
  // paths. The default -1 maps the planner/ROS lateral sign to DJI +right.
  output.y = limits.dji_y_sign * vy;
  output.z = Clamp(vz,
                   -limits.vertical_m_s, limits.vertical_m_s);
  const double yaw_rate_deg_s =
      yaw_state != nullptr
          ? ClosedLoopYawRate(planner, odom, now_s, limits, *yaw_state)
          : Clamp(planner.yaw_dot_rad_s * 180.0 / M_PI,
                  -std::abs(limits.yaw_deg_s), std::abs(limits.yaw_deg_s));
  output.yaw_deg_s = limits.dji_yaw_sign * yaw_rate_deg_s;
  output.valid = true;
  return output;
}

}  // namespace psdk_velocity_adapter

#endif  // PSDK_VELOCITY_ADAPTER_VELOCITY_ADAPTER_HPP
