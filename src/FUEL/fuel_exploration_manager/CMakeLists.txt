cmake_minimum_required(VERSION 2.8.3)
project(fuel_exploration_manager)

set(CMAKE_BUILD_TYPE "Release")
set(CMAKE_CXX_FLAGS "-std=c++11")
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -Wall")

find_package(Eigen3 REQUIRED)
find_package(PCL 1.7 REQUIRED)

find_package(catkin REQUIRED COMPONENTS
  roscpp
  std_msgs
  geometry_msgs
  quadrotor_msgs
  fuel_plan_env
  fuel_path_searching
  bspline
  bspline_opt
  fuel_traj_utils
  fuel_active_perception
  fuel_lkh_tsp_solver
  fuel_plan_manage
  cv_bridge
)

catkin_package(
 INCLUDE_DIRS include
 LIBRARIES fuel_exploration_manager
 CATKIN_DEPENDS fuel_plan_env fuel_path_searching bspline bspline_opt fuel_active_perception fuel_traj_utils fuel_lkh_tsp_solver fuel_plan_manage
#  DEPENDS system_lib
)

include_directories(
  include
  SYSTEM
  ${catkin_INCLUDE_DIRS} ${PROJECT_SOURCE_DIR}/include
  ${EIGEN3_INCLUDE_DIR}
  ${PCL_INCLUDE_DIRS}
)


add_executable(fuel_exploration_node
  src/exploration_node.cpp 
  src/fast_exploration_fsm.cpp
  src/fast_exploration_manager.cpp
  )
target_link_libraries(fuel_exploration_node 
  ${catkin_LIBRARIES}
  )

# add_library(fuel_exploration_manager
#   src/fast_exploration_manager.cpp
# )
# target_link_libraries(fuel_exploration_manager
#   ${catkin_LIBRARIES}
# )

add_executable(fuel_write_tsp test/write_tsp.cpp)
target_link_libraries(fuel_write_tsp
  ${catkin_LIBRARIES} 
)


add_executable(fuel_load_obj test/load_obj.cpp)
target_link_libraries(fuel_load_obj
  ${catkin_LIBRARIES} ${PCL_LIBRARIES}
)