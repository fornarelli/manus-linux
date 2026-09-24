# MANUS gloves on Linux - see README.md
#
# Typical session:   make vm-up  ->  start MANUS Core in Windows  ->  make run
#
SHELL      := /bin/bash
IMAGE      ?= manus-linux
ROS_IMAGE  ?= manus-ros2
ROS_DISTRO ?= jazzy
# Windows guest address, recorded by vm/setup.sh; empty means autodiscover
CORE_IP    ?= $(shell cat vm/.guest-ip 2>/dev/null)
UIDGID      = $(shell id -u):$(shell id -g)

# --user keeps build output owned by you; without it the container writes as
# root and `make clean` cannot remove it.
DOCKER_SDK  = docker run --rm --user $(UIDGID) \
              -v "$(CURDIR)/sdkclient":/work -w /work --entrypoint bash $(IMAGE) -c
# --network host so the node reaches Core through the host's routes, and its
# topics land on the host's DDS domain where normal ROS2 tooling can see them.
DOCKER_ROS  = docker run --rm --network host --ipc=host --user $(UIDGID) \
              -v "$(CURDIR)/ros2":/ws -w /ws $(ROS_IMAGE) bash -lc
SOURCE_ROS  = source /opt/ros/$(ROS_DISTRO)/setup.bash

.DEFAULT_GOAL := help
.PHONY: help udev image client client-native ros2-image ros2 ros2-native \
        vm-up vm-down down run ros2-run ros2-shell clean

help:
	@echo "setup (once per machine)"
	@echo "  make udev            install the dongle permission rule       [sudo]"
	@echo "  make image           build the gRPC 1.28.1 image              (slow)"
	@echo "  make client          build the SDK client (remote-capable)"
	@echo "  make ros2-image      build the ROS2 image"
	@echo "  make ros2            build the ROS2 workspace in that image"
	@echo ""
	@echo "every session"
	@echo "  make vm-up           start the Windows VM + networking        [sudo]"
	@echo "                       then start MANUS Core inside Windows"
	@echo "  make run             SDK client, remote mode"
	@echo "  make ros2-run        ROS2 publisher, remote mode$(if $(CORE_IP), (core $(CORE_IP)),)"
	@echo "  make ros2-shell      shell with ROS2 + workspace sourced, for topic echo/hz"
	@echo "  make vm-down         stop the VM, release the dongle"
	@echo "  make down            stop everything: clients, VM, network"
	@echo ""
	@echo "  make client-native   integrated-only build, no container"
	@echo "  make ros2-native     build the workspace against a host ROS2 install"
	@echo "  make clean           remove build output"

## --- setup -----------------------------------------------------------------
udev:
	sudo cp udev/99-manus.rules /etc/udev/rules.d/
	sudo udevadm control --reload-rules && sudo udevadm trigger
	@echo "replug the dongle for this to take effect"

image:
	docker build -f sdkclient/Dockerfile -t $(IMAGE) sdkclient

ros2-image:
	docker build -f ros2/Dockerfile --build-arg ROS_DISTRO=$(ROS_DISTRO) -t $(ROS_IMAGE) ros2

# Remote mode needs the full libManusSDK.so, which links gRPC 1.28.1 - hence
# the container. Integrated-only builds fine on the host: see client-native.
client:
	$(DOCKER_SDK) 'make BUILD=/work/build-remote MANUS_LIB=ManusSDK'

client-native:
	$(MAKE) -C sdkclient

ros2:
	$(DOCKER_ROS) '$(SOURCE_ROS) && colcon build'

ros2-native:
	$(SOURCE_ROS) && cd ros2 && colcon build

## --- run -------------------------------------------------------------------
vm-up:
	sudo ./vm/setup.sh

vm-down:
	cd vm && docker compose down

# Everything this repo starts. Matches on our images, so unrelated containers
# are left alone. Only asks for sudo if the shim interface is actually present.
down:
	@docker ps -q --filter ancestor=$(ROS_IMAGE) --filter ancestor=$(IMAGE) \
	  | xargs -r docker rm -f >/dev/null 2>&1 || true
	@cd vm && docker compose down >/dev/null 2>&1 || true
	@docker network rm manus-lan >/dev/null 2>&1 || true
	@if ip link show manus-shim >/dev/null 2>&1; then \
	   sudo ip link del manus-shim 2>/dev/null && echo "removed manus-shim" \
	   || echo "left manus-shim in place (needs sudo) - harmless, goes at reboot"; \
	 fi
	@echo "stopped - dongle released. 'make vm-up' to start again."

# Runs inside the container on manus-lan: it and the Windows guest are then
# macvlan siblings, which can reach each other directly.
run:
	docker run --rm -it -e TERM=$${TERM:-xterm} --network manus-lan \
	  -v "$(CURDIR)/sdkclient":/work -w /work --entrypoint bash $(IMAGE) \
	  -c './build-remote/SDKClient_Linux.out'

ros2-run:
	$(DOCKER_ROS) '$(SOURCE_ROS) && source install/setup.bash && \
	  ros2 run manus_ros2 manus_data_publisher --ros-args \
	    -p connection_mode:=remote $(if $(CORE_IP),-p core_ip:=$(CORE_IP),)'

ros2-shell:
	docker run --rm -it --network host --ipc=host --user $(UIDGID) \
	  -v "$(CURDIR)/ros2":/ws -w /ws $(ROS_IMAGE) \
	  bash -lc '$(SOURCE_ROS) && source install/setup.bash && exec bash'

clean:
	-$(MAKE) -C sdkclient clean
	@# older build output may be root-owned; let the container remove it
	-@[ -d sdkclient/build-remote ] && ! rm -rf sdkclient/build-remote 2>/dev/null && \
	  docker run --rm -v "$(CURDIR)/sdkclient":/work --entrypoint bash $(IMAGE) \
	    -c 'rm -rf /work/build-remote' || true
	rm -rf ros2/build ros2/install ros2/log
