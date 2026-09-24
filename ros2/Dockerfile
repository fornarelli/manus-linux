# Build/run environment for the MANUS ROS2 publisher, so a ROS2 installation on
# the host is not required. The workspace itself is bind-mounted, not copied,
# so source stays in the repo and rebuilds are incremental.
#
# Run with --network host: the node reaches MANUS Core through the host's routes,
# and its topics land on the host's DDS domain where normal ROS2 tooling sees them.
ARG ROS_DISTRO=jazzy
FROM ros:${ROS_DISTRO}-ros-base

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      python3-colcon-common-extensions \
      libncurses-dev \
      libusb-1.0-0-dev \
      libudev-dev \
      libzmq3-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /ws
