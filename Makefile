# MANUS gloves on Linux - see README.md
#
# Typical session:   make vm-up  ->  start MANUS Core in Windows  ->  make run
#
SHELL      := /bin/bash
IMAGE      ?= manus-linux
ROS_DISTRO ?= jazzy
# Windows guest address, recorded by vm/setup.sh; empty means autodiscover
CORE_IP    ?= $(shell cat vm/.guest-ip 2>/dev/null)
# --user keeps build output owned by you; without it the container writes as
# root and `make clean` cannot remove it.
DOCKER_SDK  = docker run --rm --user $(shell id -u):$(shell id -g) \
              -v "$(CURDIR)/sdkclient":/work -w /work --entrypoint bash $(IMAGE)

.DEFAULT_GOAL := help
.PHONY: help udev image client client-native vm-up vm-down run ros2 ros2-run clean

help:
	@echo "setup (once per machine)"
	@echo "  make udev            install the dongle permission rule       [sudo]"
	@echo "  make image           build the gRPC 1.28.1 container image    (slow)"
	@echo "  make client          build the SDK client (remote-capable)"
	@echo "  make ros2            build the ROS2 workspace"
	@echo ""
	@echo "every session"
	@echo "  make vm-up           start the Windows VM + networking        [sudo]"
	@echo "                       then start MANUS Core inside Windows"
	@echo "  make run             SDK client, remote mode"
	@echo "  make ros2-run        ROS2 publisher, remote mode$(if $(CORE_IP), (core $(CORE_IP)),)"
	@echo "  make vm-down         stop the VM, release the dongle"
	@echo ""
	@echo "  make client-native   integrated-only build, no container"
	@echo "  make clean           remove build output"

## --- setup -----------------------------------------------------------------
udev:
	sudo cp udev/99-manus.rules /etc/udev/rules.d/
	sudo udevadm control --reload-rules && sudo udevadm trigger
	@echo "replug the dongle for this to take effect"

image:
	docker build -f sdkclient/Dockerfile -t $(IMAGE) sdkclient

# Remote mode needs the full libManusSDK.so, which links gRPC 1.28.1 - hence
# the container. Integrated-only builds fine on the host: see client-native.
client:
	$(DOCKER_SDK) -c 'make BUILD=/work/build-remote MANUS_LIB=ManusSDK'

client-native:
	$(MAKE) -C sdkclient

ros2:
	source /opt/ros/$(ROS_DISTRO)/setup.bash && cd ros2 && colcon build

## --- run -------------------------------------------------------------------
vm-up:
	sudo ./vm/setup.sh

vm-down:
	cd vm && docker compose down

# Runs inside the container on manus-lan: it and the Windows guest are then
# macvlan siblings, which can reach each other directly.
run:
	docker run --rm -it -e TERM=$${TERM:-xterm} --network manus-lan \
	  -v "$(CURDIR)/sdkclient":/work -w /work --entrypoint bash $(IMAGE) \
	  -c './build-remote/SDKClient_Linux.out'

ros2-run:
	source /opt/ros/$(ROS_DISTRO)/setup.bash && cd ros2 && source install/setup.bash && \
	ros2 run manus_ros2 manus_data_publisher --ros-args \
	  -p connection_mode:=remote $(if $(CORE_IP),-p core_ip:=$(CORE_IP),)

clean:
	-$(MAKE) -C sdkclient clean
	@# older build output may be root-owned; let the container remove it
	-@[ -d sdkclient/build-remote ] && ! rm -rf sdkclient/build-remote 2>/dev/null && \
	  docker run --rm -v "$(CURDIR)/sdkclient":/work --entrypoint bash $(IMAGE) \
	    -c 'rm -rf /work/build-remote' || true
	rm -rf ros2/build ros2/install ros2/log
