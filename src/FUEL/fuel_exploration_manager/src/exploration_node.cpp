#include <ros/ros.h>
#include <fuel_exploration_manager/fast_exploration_fsm.h>

#include <fuel_plan_manage/backward.hpp>
namespace backward {
backward::SignalHandling sh;
}

using namespace fuel_planner;

int main(int argc, char** argv) {
  ros::init(argc, argv, "exploration_node");
  ros::NodeHandle nh("~");

  FastExplorationFSM expl_fsm;
  expl_fsm.init(nh);

  ros::Duration(1.0).sleep();
  ros::spin();

  return 0;
}
