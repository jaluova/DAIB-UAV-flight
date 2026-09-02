cmake_minimum_required(VERSION 3.0.2)
project(fuel_goal_bridge)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(catkin REQUIRED COMPONENTS
  geometry_msgs
  nav_msgs
  pcl_conversions
  pcl_ros
  roscpp
  sensor_msgs
  std_msgs
  fuel_plan_env
  fuel_path_searching
  fuel_active_perception
  bspline
)
find_package(Eigen3 REQUIRED)
find_package(PCL REQUIRED COMPONENTS common)

catkin_package(CATKIN_DEPENDS
  geometry_msgs nav_msgs pcl_conversions pcl_ros roscpp sensor_msgs std_msgs
  fuel_plan_env fuel_path_searching fuel_active_perception bspline)

include_directories(${catkin_INCLUDE_DIRS} ${EIGEN3_INCLUDE_DIRS} ${PCL_INCLUDE_DIRS})

add_executable(fuel_goal_bridge_node src/fuel_goal_bridge_node.cpp)
target_link_libraries(fuel_goal_bridge_node
  ${catkin_LIBRARIES} ${PCL_LIBRARIES})

install(TARGETS fuel_goal_bridge_node
  RUNTIME DESTINATION ${CATKIN_PACKAGE_BIN_DESTINATION})
install(DIRECTORY launch
  DESTINATION ${CATKIN_PACKAGE_SHARE_DESTINATION})
