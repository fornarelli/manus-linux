cmake_minimum_required(VERSION 3.11)
project(manus_ros2)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# Ported to the MANUS SDK 2.5.1 layout: a flat lib/ holding libManusSDK.so,
# rather than 3.2.x's lib/<arch>/libManusSDK-<arch>.so.
# Remote mode needs the FULL library, which links gRPC 1.28.1 - a version no
# distro packages, so a matched set is vendored in lib/thirdparty.
set(MANUS_SDK_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../ManusSDK)
set(MANUS_LIB_DIR ${MANUS_SDK_DIR}/lib)
set(MANUS_TP_DIR  ${MANUS_LIB_DIR}/thirdparty)

# find dependencies
find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(manus_ros2_msgs REQUIRED)

add_executable(manus_data_publisher 
  src/manus_data_publisher.cpp
  src/ClientPlatformSpecific.cpp
  src/ManusDataPublisher.cpp)
target_include_directories(manus_data_publisher PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>
  ${MANUS_SDK_DIR}/include)
target_link_directories(manus_data_publisher PRIVATE ${MANUS_LIB_DIR} ${MANUS_TP_DIR})

target_link_libraries(manus_data_publisher ManusSDK ncurses)

target_compile_features(manus_data_publisher PUBLIC c_std_99 cxx_std_17)  # Require C99 and C++17

install(TARGETS manus_data_publisher
  DESTINATION lib/${PROJECT_NAME})

file(GLOB MANUS_RUNTIME_LIBS ${MANUS_LIB_DIR}/libManusSDK.so ${MANUS_TP_DIR}/*.so*)
install(FILES ${MANUS_RUNTIME_LIBS} DESTINATION lib/${PROJECT_NAME})

# $ORIGIN must reach libManusSDK.so's OWN dependencies (libgrpc.so.9 etc).
# DT_RUNPATH (the modern default) is not inherited by transitive deps, so force
# the old DT_RPATH, which is.
set_target_properties(manus_data_publisher PROPERTIES INSTALL_RPATH "$ORIGIN")
target_link_options(manus_data_publisher PRIVATE "-Wl,--disable-new-dtags")

ament_target_dependencies(manus_data_publisher rclcpp std_msgs geometry_msgs manus_ros2_msgs)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  # the following line skips the linter which checks for copyrights
  # comment the line when a copyright and license is added to all source files
  set(ament_cmake_copyright_FOUND TRUE)
  # the following line skips cpplint (only works in a git repo)
  # comment the line when this package is in a git repo and when
  # a copyright and license is added to all source files
  set(ament_cmake_cpplint_FOUND TRUE)
  ament_lint_auto_find_test_dependencies()
endif()

ament_package()
