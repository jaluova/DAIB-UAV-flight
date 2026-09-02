#include "bspline_opt/uniform_bspline.h"
#include "nav_msgs/Odometry.h"
#include "traj_utils/Bspline.h"
#include "quadrotor_msgs/PositionCommand.h"
#include "std_msgs/Empty.h"
#include "visualization_msgs/Marker.h"
#include <algorithm>
#include <cmath>
#include <ros/ros.h>
#include <string>
#include <utility>

ros::Publisher pos_cmd_pub;

quadrotor_msgs::PositionCommand cmd;
double pos_gain[3] = {0, 0, 0};
double vel_gain[3] = {0, 0, 0};

using ego_planner::UniformBspline;

bool receive_traj_ = false;
vector<UniformBspline> traj_;
double traj_duration_;
ros::Time start_time_;
int traj_id_;

// yaw control
double last_yaw_, last_yaw_dot_;
double time_forward_;
std::string command_frame_id_;
double max_yaw_rate_ = 3.0 * M_PI / 180.0;
bool yaw_command_initialized_ = false;
bool have_odom_yaw_ = false;

double wrapYaw(double angle)
{
  while (angle > M_PI) angle -= 2.0 * M_PI;
  while (angle <= -M_PI) angle += 2.0 * M_PI;
  return angle;
}

void odomCallback(const nav_msgs::OdometryConstPtr &msg)
{
  const auto &q = msg->pose.pose.orientation;
  const double norm = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  if (!std::isfinite(norm) || norm < 1e-6) return;
  const double x = q.x / norm, y = q.y / norm;
  const double z = q.z / norm, w = q.w / norm;
  const double sin_yaw = 2.0 * (w * z + x * y);
  const double cos_yaw = 1.0 - 2.0 * (y * y + z * z);
  const double yaw = std::atan2(sin_yaw, cos_yaw);
  if (!have_odom_yaw_) {
    last_yaw_ = yaw;
    last_yaw_dot_ = 0.0;
    yaw_command_initialized_ = true;
    have_odom_yaw_ = true;
  }
}

void bsplineCallback(traj_utils::BsplineConstPtr msg)
{
  // parse pos traj

  Eigen::MatrixXd pos_pts(3, msg->pos_pts.size());

  Eigen::VectorXd knots(msg->knots.size());
  for (size_t i = 0; i < msg->knots.size(); ++i)
  {
    knots(i) = msg->knots[i];
  }

  for (size_t i = 0; i < msg->pos_pts.size(); ++i)
  {
    pos_pts(0, i) = msg->pos_pts[i].x;
    pos_pts(1, i) = msg->pos_pts[i].y;
    pos_pts(2, i) = msg->pos_pts[i].z;
  }

  UniformBspline pos_traj(pos_pts, msg->order, 0.1);
  pos_traj.setKnot(knots);

  // parse yaw traj

  // Eigen::MatrixXd yaw_pts(msg->yaw_pts.size(), 1);
  // for (int i = 0; i < msg->yaw_pts.size(); ++i) {
  //   yaw_pts(i, 0) = msg->yaw_pts[i];
  // }

  //UniformBspline yaw_traj(yaw_pts, msg->order, msg->yaw_dt);

  start_time_ = msg->start_time;
  traj_id_ = msg->traj_id;

  traj_.clear();
  traj_.push_back(pos_traj);
  traj_.push_back(traj_[0].getDerivative());
  traj_.push_back(traj_[1].getDerivative());

  traj_duration_ = traj_[0].getTimeSum();

  receive_traj_ = true;
}

std::pair<double, double> calculate_yaw(double t_cur, Eigen::Vector3d &pos, ros::Time &time_now, ros::Time &time_last)
{
  const double dt_raw = (time_now - time_last).toSec();
  const double dt = std::isfinite(dt_raw) && dt_raw > 1e-4 && dt_raw <= 0.5
                        ? dt_raw
                        : 0.01;
  const Eigen::Vector3d future =
      t_cur + time_forward_ <= traj_duration_
          ? traj_[0].evaluateDeBoorT(t_cur + time_forward_)
          : traj_[0].evaluateDeBoorT(traj_duration_);
  const Eigen::Vector3d dir = future - pos;
  const double target = dir.norm() > 0.1
                            ? std::atan2(dir(1), dir(0))
                            : last_yaw_;
  if (!yaw_command_initialized_) {
    last_yaw_ = target;
    last_yaw_dot_ = 0.0;
    yaw_command_initialized_ = true;
  }
  // Publish the actual desired heading. The downstream adapter closes the
  // loop against measured odometry and applies the aircraft's safe rate and
  // acceleration limits. Keep yaw_dot bounded as diagnostic/feed-forward data.
  const double error = wrapYaw(target - last_yaw_);
  const double yaw = target;
  const double yawdot = std::max(-std::abs(max_yaw_rate_),
                                 std::min(error / dt, std::abs(max_yaw_rate_)));
  last_yaw_ = yaw;
  last_yaw_dot_ = yawdot;
  return std::make_pair(yaw, yawdot);
}

void cmdCallback(const ros::TimerEvent &e)
{
  /* no publishing before receive traj_ */
  if (!receive_traj_)
    return;

  ros::Time time_now = ros::Time::now();
  double t_cur = (time_now - start_time_).toSec();

  Eigen::Vector3d pos(Eigen::Vector3d::Zero()), vel(Eigen::Vector3d::Zero()), acc(Eigen::Vector3d::Zero()), pos_f;
  std::pair<double, double> yaw_yawdot(0, 0);

  static ros::Time time_last = ros::Time::now();
  if (t_cur < traj_duration_ && t_cur >= 0.0)
  {
    pos = traj_[0].evaluateDeBoorT(t_cur);
    vel = traj_[1].evaluateDeBoorT(t_cur);
    acc = traj_[2].evaluateDeBoorT(t_cur);

    /*** calculate yaw ***/
    yaw_yawdot = calculate_yaw(t_cur, pos, time_now, time_last);
    /*** calculate yaw ***/

    double tf = min(traj_duration_, t_cur + 2.0);
    pos_f = traj_[0].evaluateDeBoorT(tf);
  }
  else if (t_cur >= traj_duration_)
  {
    /* hover when finish traj_ */
    pos = traj_[0].evaluateDeBoorT(traj_duration_);
    vel.setZero();
    acc.setZero();

    yaw_yawdot.first = last_yaw_;
    yaw_yawdot.second = 0;

    pos_f = pos;
  }
  else
  {
    cout << "[Traj server]: invalid time." << endl;
  }
  time_last = time_now;

  cmd.header.stamp = time_now;
  cmd.header.frame_id = command_frame_id_;
  cmd.trajectory_flag = quadrotor_msgs::PositionCommand::TRAJECTORY_STATUS_READY;
  cmd.trajectory_id = traj_id_;

  cmd.position.x = pos(0);
  cmd.position.y = pos(1);
  cmd.position.z = pos(2);

  cmd.velocity.x = vel(0);
  cmd.velocity.y = vel(1);
  cmd.velocity.z = vel(2);

  cmd.acceleration.x = acc(0);
  cmd.acceleration.y = acc(1);
  cmd.acceleration.z = acc(2);

  cmd.yaw = yaw_yawdot.first;
  cmd.yaw_dot = yaw_yawdot.second;

  last_yaw_ = cmd.yaw;

  pos_cmd_pub.publish(cmd);
}

int main(int argc, char **argv)
{
  ros::init(argc, argv, "traj_server");
  // ros::NodeHandle node;
  ros::NodeHandle nh("~");

  ros::Subscriber bspline_sub = nh.subscribe("planning/bspline", 10, bsplineCallback);
  std::string odom_topic;
  nh.param<std::string>("traj_server/odom_topic", odom_topic,
                        "/daib_slam/odom");
  ros::Subscriber odom_sub = nh.subscribe(odom_topic, 10, odomCallback);

  pos_cmd_pub = nh.advertise<quadrotor_msgs::PositionCommand>("/position_cmd", 50);

  ros::Timer cmd_timer = nh.createTimer(ros::Duration(0.01), cmdCallback);

  /* control parameter */
  cmd.kx[0] = pos_gain[0];
  cmd.kx[1] = pos_gain[1];
  cmd.kx[2] = pos_gain[2];

  cmd.kv[0] = vel_gain[0];
  cmd.kv[1] = vel_gain[1];
  cmd.kv[2] = vel_gain[2];

  nh.param("traj_server/time_forward", time_forward_, -1.0);
  double max_yaw_rate_deg_s = 3.0;
  nh.param("traj_server/max_yaw_rate_deg_s", max_yaw_rate_deg_s, max_yaw_rate_deg_s);
  if (!std::isfinite(max_yaw_rate_deg_s) || max_yaw_rate_deg_s <= 0.0)
    max_yaw_rate_deg_s = 3.0;
  max_yaw_rate_ = max_yaw_rate_deg_s * M_PI / 180.0;
  nh.param<std::string>("traj_server/frame_id", command_frame_id_, "world");
  last_yaw_ = 0.0;
  last_yaw_dot_ = 0.0;

  ros::Duration(1.0).sleep();

  ROS_WARN("[Traj server]: ready.");

  ros::spin();

  return 0;
}
