cmake_minimum_required(VERSION 2.8.3)
project(fuel_plan_manage)

set(CMAKE_BUILD_TYPE "Release")
set(CMAKE_CXX_FLAGS "-std=c++11")
# set(CMAKE_CXX_FLAGS_RELEASE "-O3 -Wall -g")
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -Wall")

find_package(Eigen3 REQUIRED)
find_package(PCL 1.7 REQUIRED)

find_package(catkin REQUIRED COMPONENTS
  roscpp
  std_msgs
  geometry_msgs
  quadrotor_msgs
  fuel_poly_traj
  fuel_plan_env
  fuel_path_searching
  bspline
  bspline_opt
  fuel_traj_utils
  fuel_active_perception
  cv_bridge
)


catkin_package(
 INCLUDE_DIRS include
 LIBRARIES fuel_plan_manage
 CATKIN_DEPENDS fuel_plan_env fuel_path_searching bspline bspline_opt fuel_active_perception fuel_traj_utils)

include_directories(
  include
  SYSTEM
  ${catkin_INCLUDE_DIRS} ${PROJECT_SOURCE_DIR}/include
  ${EIGEN3_INCLUDE_DIR}
  ${PCL_INCLUDE_DIRS}
)


add_executable(fuel_fast_planner_node
  src/fast_planner_node.cpp 
  src/kino_replan_fsm.cpp
  src/topo_replan_fsm.cpp
  test/local_explore_fsm.cpp
  src/planner_manager.cpp
  src/planner_manager_dev.cpp
  )
target_link_libraries(fuel_fast_planner_node 
  ${catkin_LIBRARIES}
  )

add_library(fuel_plan_manage 
  src/planner_manager.cpp
  src/planner_manager_dev.cpp
  )
target_link_libraries(fuel_plan_manage ${catkin_LIBRARIES})

add_executable(fuel_traj_server src/traj_server.cpp)
target_link_libraries(fuel_traj_server ${catkin_LIBRARIES})
# add_dependencies(traj_server ${${PROJECT_NAME}_EXPORTED_TARGETS})

# benchmark node
# add_executable(fuel_compare_topo
#   src/compare_topo.cpp 
#   src/planner_manager.cpp
#   )
# target_link_libraries(fuel_compare_topo 
#   ${catkin_LIBRARIES}
#   )

# add_executable(fuel_rotation test/rotation.cpp)
# target_link_libraries(fuel_rotation ${catkin_LIBRARIES})

add_executable(fuel_proc_msg 
    test/process_msg.cpp
)
target_link_libraries(fuel_proc_msg
    ${catkin_LIBRARIES} 
    ${PCL_LIBRARIES}
    )  

add_executable(fuel_proc_msg2 
    test/process_msg2.cpp
)
target_link_libraries(fuel_proc_msg2
    ${catkin_LIBRARIES} 
    ${PCL_LIBRARIES}
    )  