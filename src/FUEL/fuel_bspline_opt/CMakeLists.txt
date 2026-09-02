cmake_minimum_required(VERSION 2.8.3)
project(fuel_bspline_opt)

set(CMAKE_BUILD_TYPE "Release")
set(CMAKE_CXX_FLAGS "-std=c++11")
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -Wall")

find_package(Eigen3 REQUIRED)
find_package(PCL 1.7 REQUIRED)

set(NLOPT_INCLUDE_DIR "/usr/local/include")  
set(NLOPT_LIBRARY "/usr/local/lib/libnlopt.so")  

find_package(catkin REQUIRED COMPONENTS
  roscpp
  rospy
  std_msgs
  visualization_msgs
  fuel_plan_env
  fuel_active_perception
  cv_bridge
)

catkin_package(
 INCLUDE_DIRS include
 LIBRARIES fuel_bspline_opt
 CATKIN_DEPENDS fuel_plan_env fuel_active_perception
)


include_directories( 
    SYSTEM 
    include 
    ${catkin_INCLUDE_DIRS}
    ${Eigen3_INCLUDE_DIRS} 
    ${PCL_INCLUDE_DIRS}
    ${NLOPT_INCLUDE_DIR}  
)

add_library(fuel_bspline_opt 
    src/bspline_optimizer.cpp 
    )
target_link_libraries(fuel_bspline_opt
    ${catkin_LIBRARIES} 
    ${NLOPT_LIBRARY}   
    )
