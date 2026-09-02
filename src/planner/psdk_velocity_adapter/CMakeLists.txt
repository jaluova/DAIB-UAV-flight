cmake_minimum_required(VERSION 3.0.2)
project(psdk_velocity_adapter)

add_compile_options(-std=c++14 -Wall -Wextra -Wpedantic)

find_package(catkin REQUIRED COMPONENTS
  geometry_msgs
  nav_msgs
  quadrotor_msgs
  roscpp
  std_msgs
  visualization_msgs
)

catkin_package(CATKIN_DEPENDS geometry_msgs nav_msgs quadrotor_msgs roscpp std_msgs visualization_msgs)
include_directories(include ${catkin_INCLUDE_DIRS})

add_executable(psdk_velocity_adapter_node src/psdk_velocity_adapter_node.cpp)
target_link_libraries(psdk_velocity_adapter_node ${catkin_LIBRARIES})

if(CATKIN_ENABLE_TESTING)
  add_executable(velocity_adapter_test test/velocity_adapter_test.cpp)
  target_link_libraries(velocity_adapter_test ${catkin_LIBRARIES})
  add_test(NAME velocity_adapter_test COMMAND velocity_adapter_test)
endif()
