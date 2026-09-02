#include <fuel_active_perception/frontier_finder.h>
#include <fuel_active_perception/graph_node.h>
#include <fuel_plan_env/edt_environment.h>
#include <fuel_plan_env/raycast.h>
#include <fuel_plan_env/sdf_map.h>
#include <fuel_path_searching/astar2.h>

#include <geometry_msgs/PoseStamped.h>
#include <nav_msgs/Odometry.h>
#include <pcl/point_cloud.h>
#include <pcl/point_types.h>
#include <pcl_conversions/pcl_conversions.h>
#include <ros/ros.h>
#include <sensor_msgs/PointCloud2.h>
#include <std_msgs/Bool.h>
#include <std_msgs/Header.h>
#include <std_msgs/String.h>
#include <std_msgs/UInt64.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

namespace
{
using Eigen::Vector3d;
using fuel_planner::EDTEnvironment;
using fuel_planner::FrontierFinder;
using fuel_planner::SDFMap;

struct FrontierKey
{
  int x = 0;
  int y = 0;
  int z = 0;
  bool operator==(const FrontierKey &other) const
  {
    return x == other.x && y == other.y && z == other.z;
  }
};

struct FrontierKeyHash
{
  std::size_t operator()(const FrontierKey &key) const
  {
    std::size_t seed = std::hash<int>{}(key.x);
    seed ^= std::hash<int>{}(key.y) + 0x9e3779b9U + (seed << 6U) + (seed >> 2U);
    seed ^= std::hash<int>{}(key.z) + 0x9e3779b9U + (seed << 6U) + (seed >> 2U);
    return seed;
  }
};

class FuelGoalBridge
{
public:
  FuelGoalBridge() : nh_(), pnh_("~")
  {
    pnh_.param("odom_topic", odom_topic_, std::string("/daib_slam/odom"));
    pnh_.param("cloud_topic", cloud_topic_, std::string("/daib_slam/planning_cloud"));
    pnh_.param("goal_topic", goal_topic_, std::string("/daib_explorer/goal"));
    pnh_.param("planning_cloud_topic", planning_cloud_topic_,
               std::string("/daib_explorer/planning_cloud"));
    pnh_.param("frontiers_topic", frontiers_topic_,
               std::string("/daib_explorer/frontiers"));
    pnh_.param("state_topic", state_topic_, std::string("/daib_explorer/state"));
    pnh_.param("generation_topic", generation_topic_,
               std::string("/daib_explorer/generation"));
    pnh_.param("ready_topic", ready_topic_, std::string("/daib_explorer/ready"));
    pnh_.param("map_update_rate_hz", update_rate_hz_, 10.0);
    pnh_.param("max_cloud_points", max_cloud_points_, 6000);
    pnh_.param("min_candidate_distance_m", min_candidate_distance_m_, 1.5);
    pnh_.param("max_candidate_distance_m", max_candidate_distance_m_, 8.0);
    pnh_.param("goal_vertical_limit_m", goal_vertical_limit_m_, 0.5);
    pnh_.param("goal_reached_distance_m", goal_reached_distance_m_, 0.8);
    pnh_.param("obstacles_inflation_m", obstacles_inflation_m_, 1.0);
    pnh_.param("map_resolution_m", map_resolution_m_, 0.5);
    pnh_.param("map_size_x_m", map_size_x_m_, 80.0);
    pnh_.param("map_size_y_m", map_size_y_m_, 80.0);
    pnh_.param("map_size_z_m", map_size_z_m_, 30.0);
    pnh_.param("map_ground_height_m", map_ground_height_m_, -10.0);
    pnh_.param("max_viewpoints_per_frontier", max_viewpoints_per_frontier_, 8);
    pnh_.param("explored_frontier_voxel_size_m",
               explored_frontier_voxel_size_m_, 2.0);
    pnh_.param("exploration_memory_restore", exploration_memory_restore_, false);
    pnh_.param("exploration_memory_file", exploration_memory_file_,
               std::string("/tmp/daib-fuel-explored-frontiers.txt"));
    if (exploration_memory_restore_)
      loadExploredFrontiers();
    else if (!exploration_memory_file_.empty())
      std::remove(exploration_memory_file_.c_str());

    pnh_.setParam("sdf_map/resolution", map_resolution_m_);
    pnh_.setParam("sdf_map/map_size_x", map_size_x_m_);
    pnh_.setParam("sdf_map/map_size_y", map_size_y_m_);
    pnh_.setParam("sdf_map/map_size_z", map_size_z_m_);
    pnh_.setParam("sdf_map/ground_height", map_ground_height_m_);
    pnh_.setParam("sdf_map/obstacles_inflation", obstacles_inflation_m_);
    // SDFMap's upstream defaults are sentinel values (-1). Set the
    // occupancy model explicitly because this bridge feeds world-frame
    // point clouds directly instead of using FUEL's original map node.
    pnh_.setParam("sdf_map/p_hit", 0.70);
    pnh_.setParam("sdf_map/p_miss", 0.35);
    pnh_.setParam("sdf_map/p_min", 0.12);
    pnh_.setParam("sdf_map/p_max", 0.97);
    pnh_.setParam("sdf_map/p_occ", 0.80);
    pnh_.setParam("sdf_map/max_ray_length", 20.0);
    pnh_.setParam("sdf_map/local_bound_inflate", 1.0);
    pnh_.setParam("sdf_map/optimistic", false);
    pnh_.setParam("sdf_map/virtual_ceil_height", 15.0);
    pnh_.setParam("astar/resolution_astar", 0.5);
    pnh_.setParam("astar/lambda_heu", 1.0);
    pnh_.setParam("astar/max_search_time", 0.05);
    pnh_.setParam("astar/allocate_num", 20000);
    pnh_.setParam("frontier/cluster_min", 10);
    pnh_.setParam("frontier/cluster_size_xy", 5.0);
    pnh_.setParam("frontier/cluster_size_z", 2.0);
    pnh_.setParam("frontier/min_candidate_dist", min_candidate_distance_m_);
    pnh_.setParam("frontier/min_candidate_clearance", obstacles_inflation_m_);
    pnh_.setParam("frontier/candidate_dphi", M_PI / 6.0);
    pnh_.setParam("frontier/candidate_rmax", 4.0);
    pnh_.setParam("frontier/candidate_rmin", 1.0);
    pnh_.setParam("frontier/candidate_rnum", max_viewpoints_per_frontier_);
    pnh_.setParam("frontier/down_sample", 2);
    pnh_.setParam("frontier/min_visib_num", 5);
    pnh_.setParam("frontier/min_view_finish_fraction", 0.2);
    pnh_.setParam("perception_utils/top_angle", 0.5);
    pnh_.setParam("perception_utils/left_angle", 0.7);
    pnh_.setParam("perception_utils/right_angle", 0.7);
    pnh_.setParam("perception_utils/max_dist", 20.0);
    pnh_.setParam("perception_utils/vis_dist", 5.0);
    pnh_.setParam("map_ros/frame_id", "camera_init");

    map_.reset(new SDFMap);
    map_->initMap(pnh_);
    edt_.reset(new EDTEnvironment);
    edt_->setMap(map_);
    fuel_planner::ViewNode::astar_.reset(new fuel_planner::Astar);
    fuel_planner::ViewNode::astar_->init(pnh_, edt_);
    fuel_planner::ViewNode::map_ = map_;
    fuel_planner::ViewNode::caster_.reset(new RayCaster);
    Vector3d map_origin, map_size;
    map_->getRegion(map_origin, map_size);
    fuel_planner::ViewNode::caster_->setParams(map_->getResolution(), map_origin);
    fuel_planner::ViewNode::vm_ = 1.0;
    fuel_planner::ViewNode::am_ = 1.0;
    fuel_planner::ViewNode::yd_ = 0.35;
    fuel_planner::ViewNode::ydd_ = 0.5;
    fuel_planner::ViewNode::w_dir_ = 0.5;
    finder_.reset(new FrontierFinder(edt_, pnh_));

    odom_sub_ = nh_.subscribe(odom_topic_, 5, &FuelGoalBridge::odomCallback, this);
    cloud_sub_ = nh_.subscribe(cloud_topic_, 1, &FuelGoalBridge::cloudCallback, this);
    goal_pub_ = nh_.advertise<geometry_msgs::PoseStamped>(goal_topic_, 1, true);
    cloud_pub_ = nh_.advertise<sensor_msgs::PointCloud2>(planning_cloud_topic_, 1);
    frontier_pub_ = nh_.advertise<sensor_msgs::PointCloud2>(frontiers_topic_, 1, true);
    state_pub_ = nh_.advertise<std_msgs::String>(state_topic_, 1, true);
    generation_pub_ = nh_.advertise<std_msgs::UInt64>(generation_topic_, 1, true);
    ready_pub_ = nh_.advertise<std_msgs::Bool>(ready_topic_, 1, true);
    timer_ = nh_.createTimer(ros::Duration(1.0 / std::max(0.2, update_rate_hz_)),
                             &FuelGoalBridge::updateCallback, this);
    publishReady(false);
    publishState("WAIT_FOR_MAP");
    ROS_INFO("[FUEL bridge] ready; goal=%s, inflation=%.2f m", goal_topic_.c_str(),
             obstacles_inflation_m_);
  }

  ~FuelGoalBridge()
  {
    saveExploredFrontiers();
  }

private:
  ros::NodeHandle nh_, pnh_;
  ros::Subscriber odom_sub_, cloud_sub_;
  ros::Publisher goal_pub_, cloud_pub_, frontier_pub_, state_pub_, generation_pub_, ready_pub_;
  ros::Timer timer_;
  std::mutex mutex_;
  nav_msgs::OdometryConstPtr odom_;
  sensor_msgs::PointCloud2ConstPtr cloud_;
  uint64_t cloud_sequence_ = 0;
  uint64_t processed_cloud_sequence_ = 0;
  std::shared_ptr<SDFMap> map_;
  std::shared_ptr<EDTEnvironment> edt_;
  std::shared_ptr<FrontierFinder> finder_;
  std::string odom_topic_, cloud_topic_, goal_topic_, planning_cloud_topic_, frontiers_topic_;
  std::string state_topic_, generation_topic_, ready_topic_;
  double update_rate_hz_ = 10.0;
  int max_cloud_points_ = 6000;
  double min_candidate_distance_m_ = 1.5;
  double max_candidate_distance_m_ = 8.0;
  double goal_vertical_limit_m_ = 0.5;
  double goal_reached_distance_m_ = 0.8;
  double obstacles_inflation_m_ = 1.0;
  double map_resolution_m_ = 0.5;
  double map_size_x_m_ = 80.0, map_size_y_m_ = 80.0, map_size_z_m_ = 30.0;
  double map_ground_height_m_ = -10.0;
  int max_viewpoints_per_frontier_ = 8;
  uint64_t generation_ = 0;
  bool ready_ = false;
  bool active_goal_ = false;
  Vector3d active_goal_position_ = Vector3d::Zero();
  double explored_frontier_voxel_size_m_ = 2.0;
  std::unordered_set<FrontierKey, FrontierKeyHash> explored_frontiers_;
  FrontierKey active_goal_frontier_key_;
  bool exploration_memory_restore_ = false;
  std::string exploration_memory_file_ =
      "/tmp/daib-fuel-explored-frontiers.txt";

  FrontierKey frontierKey(const Vector3d &point) const
  {
    const double size = std::max(0.5, explored_frontier_voxel_size_m_);
    return {static_cast<int>(std::floor(point.x() / size)),
            static_cast<int>(std::floor(point.y() / size)),
            static_cast<int>(std::floor(point.z() / size))};
  }

  void loadExploredFrontiers()
  {
    std::ifstream input(exploration_memory_file_);
    FrontierKey key;
    while (input >> key.x >> key.y >> key.z)
      explored_frontiers_.insert(key);
    ROS_INFO("[FUEL bridge] restored %zu explored frontiers",
             explored_frontiers_.size());
  }

  void saveExploredFrontiers() const
  {
    if (exploration_memory_file_.empty()) return;
    const std::string temporary_file = exploration_memory_file_ + ".tmp";
    std::ofstream output(temporary_file, std::ios::trunc);
    if (!output) return;
    for (const FrontierKey &key : explored_frontiers_)
      output << key.x << ' ' << key.y << ' ' << key.z << '\n';
    output.close();
    if (!output)
    {
      std::remove(temporary_file.c_str());
      return;
    }
    if (std::rename(temporary_file.c_str(), exploration_memory_file_.c_str()) !=
        0)
      std::remove(temporary_file.c_str());
  }

  void odomCallback(const nav_msgs::OdometryConstPtr& msg)
  {
    std::lock_guard<std::mutex> lock(mutex_);
    odom_ = msg;
  }

  void cloudCallback(const sensor_msgs::PointCloud2ConstPtr& msg)
  {
    std::lock_guard<std::mutex> lock(mutex_);
    cloud_ = msg;
    ++cloud_sequence_;
  }

  void publishReady(bool value)
  {
    std_msgs::Bool msg;
    msg.data = value;
    ready_pub_.publish(msg);
  }

  void publishState(const std::string& value)
  {
    std_msgs::String msg;
    msg.data = value;
    state_pub_.publish(msg);
  }

  void updateCallback(const ros::TimerEvent&)
  {
    nav_msgs::OdometryConstPtr odom;
    sensor_msgs::PointCloud2ConstPtr cloud;
    uint64_t cloud_sequence = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      odom = odom_;
      cloud = cloud_;
      cloud_sequence = cloud_sequence_;
    }
    if (!odom || !cloud)
    {
      publishReady(false);
      publishState("WAIT_FOR_MAP");
      return;
    }
    if (cloud_sequence == processed_cloud_sequence_) return;

    pcl::PointCloud<pcl::PointXYZ> pcl_cloud;
    try
    {
      pcl::fromROSMsg(*cloud, pcl_cloud);
    }
    catch (const std::exception& error)
    {
      ROS_WARN_THROTTLE(2.0, "[FUEL bridge] invalid cloud: %s", error.what());
      return;
    }
    if (pcl_cloud.empty()) return;
    if (static_cast<int>(pcl_cloud.size()) > max_cloud_points_)
      pcl_cloud.points.resize(static_cast<std::size_t>(max_cloud_points_));

    const Vector3d pos(odom->pose.pose.position.x, odom->pose.pose.position.y,
                       odom->pose.pose.position.z);
    const bool goal_reached =
        active_goal_ &&
        (pos - active_goal_position_).norm() <= goal_reached_distance_m_;
    if (goal_reached)
    {
      explored_frontiers_.insert(active_goal_frontier_key_);
      saveExploredFrontiers();
      active_goal_ = false;
    }
    map_->inputPointCloud(pcl_cloud, static_cast<int>(pcl_cloud.size()), pos);
    processed_cloud_sequence_ = cloud_sequence;
    map_->clearAndInflateLocalMap();
    map_->updateESDF3d();

    // Keep the first field-debug signal close to the map input. This makes it
    // possible to distinguish an empty occupancy boundary from a viewpoint
    // filter that rejects otherwise valid frontiers.
    Eigen::Vector3d update_min, update_max;
    Eigen::Vector3i min_id, max_id;
    map_->getUpdatedBox(update_min, update_max, false);
    map_->posToIndex(update_min, min_id);
    map_->posToIndex(update_max, max_id);
    map_->boundIndex(min_id);
    map_->boundIndex(max_id);
    ROS_INFO_STREAM_THROTTLE(
        2.0, "[FUEL debug] cloud_points=" << pcl_cloud.size()
            << ", frame=" << cloud->header.frame_id
            << ", odom=(" << pos.x() << "," << pos.y() << "," << pos.z()
            << "), update_box_min=(" << update_min.x() << "," << update_min.y()
            << "," << update_min.z() << "), update_box_max=(" << update_max.x()
            << "," << update_max.y() << "," << update_max.z() << ")");

    sensor_msgs::PointCloud2 planning_cloud = *cloud;
    planning_cloud.header.stamp = odom->header.stamp;
    cloud_pub_.publish(planning_cloud);
    finder_->searchFrontiers();
    finder_->computeFrontiersToVisit();

    std::vector<Vector3d> points, averages;
    std::vector<double> yaws;
    finder_->getTopViewpointsInfo(pos, points, yaws, averages);
    publishFrontiers(odom->header, points);
    ROS_INFO_STREAM_THROTTLE(
        1.0, "[ DAIB Explorer ] map=1 frontier=" << points.size()
            << " update_rate=" << update_rate_hz_ << " Hz, backend=FUEL");
    // Keep refreshing the rolling map and frontier set while the active goal
    // is in flight, but do not replace a healthy goal on every update.
    if (active_goal_)
    {
      publishReady(true);
      publishState("EXPLORE_HOLD_GOAL");
      return;
    }
    if (points.empty())
    {
      publishReady(ready_);
      publishState("WAIT_FOR_FRONTIER");
      return;
    }

    const double current_yaw = std::atan2(
        2.0 * (odom->pose.pose.orientation.w * odom->pose.pose.orientation.z +
               odom->pose.pose.orientation.x * odom->pose.pose.orientation.y),
        1.0 - 2.0 * (odom->pose.pose.orientation.y * odom->pose.pose.orientation.y +
                     odom->pose.pose.orientation.z * odom->pose.pose.orientation.z));
    std::vector<std::size_t> candidates;
    for (std::size_t i = 0; i < points.size(); ++i)
    {
      const double d = (points[i] - pos).norm();
      if (d >= min_candidate_distance_m_ && d <= max_candidate_distance_m_ &&
          std::fabs(points[i].z() - pos.z()) <= goal_vertical_limit_m_ &&
          explored_frontiers_.find(frontierKey(
              i < averages.size() ? averages[i] : points[i])) ==
              explored_frontiers_.end())
        candidates.push_back(i);
    }
    if (candidates.empty())
    {
      publishReady(ready_);
      publishState("WAIT_FOR_SAFE_VIEWPOINT");
      return;
    }

    // Select the first FUEL viewpoint from its path/yaw cost matrix. EGO
    // remains the only trajectory publisher; the external LKH process is
    // intentionally not started here.
    std::size_t best = candidates.front();
    double best_cost = std::numeric_limits<double>::infinity();
    Eigen::MatrixXd cost_matrix;
    const Vector3d yaw_state(current_yaw, 0.0, 0.0);
    finder_->updateFrontierCostMatrix();
    finder_->getFullCostMatrix(pos, Vector3d::Zero(), yaw_state, cost_matrix);
    for (const std::size_t index : candidates)
    {
      const double distance = (points[index] - pos).norm();
      double dyaw = std::fabs(yaws[index] - current_yaw);
      dyaw = std::min(dyaw, 2.0 * M_PI - dyaw);
      const bool has_fuel_cost =
          cost_matrix.rows() > static_cast<int>(index + 1) &&
          cost_matrix.cols() > static_cast<int>(index + 1) &&
          std::isfinite(cost_matrix(0, static_cast<int>(index + 1)));
      const double cost = has_fuel_cost
                              ? cost_matrix(0, static_cast<int>(index + 1))
                              : distance + 2.0 * dyaw;
      if (cost < best_cost)
      {
        best_cost = cost;
        best = index;
      }
    }

    geometry_msgs::PoseStamped goal;
    goal.header.stamp = ros::Time::now();
    goal.header.frame_id = cloud->header.frame_id.empty() ? "camera_init" : cloud->header.frame_id;
    goal.pose.position.x = points[best].x();
    goal.pose.position.y = points[best].y();
    goal.pose.position.z = points[best].z();
    goal.pose.orientation.z = std::sin(yaws[best] * 0.5);
    goal.pose.orientation.w = std::cos(yaws[best] * 0.5);
    goal_pub_.publish(goal);
    active_goal_ = true;
    active_goal_position_ = points[best];
    active_goal_frontier_key_ =
        frontierKey(best < averages.size() ? averages[best] : points[best]);
    ++generation_;
    std_msgs::UInt64 generation;
    generation.data = generation_;
    generation_pub_.publish(generation);
    ready_ = true;
    publishReady(true);
    publishState("EXPLORE");
  }

  void publishFrontiers(const std_msgs::Header& header, const std::vector<Vector3d>& points)
  {
    pcl::PointCloud<pcl::PointXYZ> frontier_cloud;
    frontier_cloud.points.reserve(points.size());
    for (const Vector3d& point : points)
      frontier_cloud.push_back(pcl::PointXYZ(point.x(), point.y(), point.z()));
    frontier_cloud.width = frontier_cloud.size();
    frontier_cloud.height = 1;
    sensor_msgs::PointCloud2 msg;
    pcl::toROSMsg(frontier_cloud, msg);
    msg.header = header;
    frontier_pub_.publish(msg);
  }
};
}  // namespace

int main(int argc, char** argv)
{
  ros::init(argc, argv, "fuel_goal_bridge");
  FuelGoalBridge bridge;
  ros::spin();
  return 0;
}
