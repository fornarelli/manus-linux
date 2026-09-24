# MANUS gloves on Linux

Streams MANUS glove data on Linux using **MANUS Core 2.5.1**, with a C++ SDK
client and a ROS2 publisher.

MANUS Core is Windows-only at 2.5.x, so it runs in a container-hosted Windows VM
with the dongle passed through, and the Linux side connects to it in **remote**
mode. Developed against Ubuntu 24.04 (gcc 13) and ROS2 Jazzy.

## Why 2.5.1 and not 3.x

- Core **3.x rejects legacy licenses**. They are issued against dongle `00000000`,
  a wildcard the current scheme refuses; it wants licenses bound to a serial.
- SDK **3.1+ adds a `linuxTarget` license flag**. Without it the client refuses
  with *"the current license does not allow receiving data on Linux"*.
- 2.5.1 predates both, and MANUS's 2.5 documentation lists legacy tiers
  (Core Pro, Core XR, Core Xsens/Qualisys/OptiTrack Pro, Demo) as valid for SDK use.

With a Feature license carrying the **SDK** and **Linux** entitlements, 3.2.x
works natively and none of this is needed — no VM, no container. This repo is for
the legacy case.

## Layout

| Path | What |
|---|---|
| `Makefile` | entry point for every task — `make` lists them |
| `sdkclient/` | SDK Client 2.5.1, patched to build on gcc 13 |
| `minimalclient/` | upstream's minimal example |
| `ros2/` | ROS2 publisher, ported from 3.2.x to 2.5.1 |
| `vm/` | Windows VM running MANUS Core |
| `udev/` | device permission rule |

## Quick start

**Once per machine:**

```sh
make udev        # dongle permissions                                 [sudo]
make image       # gRPC 1.28.1 container image - slow, builds from source
make client      # SDK client, remote-capable
make ros2-image  # ROS2 container image
make ros2        # ROS2 workspace, built in that image
```

**Each session:**

```sh
make vm-up      # Windows VM + networking; prints the viewer URL       [sudo]
                # then start MANUS Core inside Windows
make run        # SDK client, remote mode
make ros2-run   # or: ROS2 publisher
make ros2-shell # shell with ROS2 sourced, for `ros2 topic echo` / `hz`
make down       # stop everything and hand the dongle back
```

### Requirements

Docker, `arp-scan`, and — only for `client-native` — `build-essential cmake
libncurses-dev libudev-dev libusb-1.0-0-dev`. **A ROS2 installation is not
required**; the publisher builds and runs in a container. The SDK binaries are
not in the repo — see [Binaries](#binaries-are-not-tracked).

`ROS_DISTRO` defaults to `jazzy`, `IMAGE` to `manus-linux`; override on the
command line.

### What the targets do

| Target | |
|---|---|
| `udev` | installs `udev/99-manus.rules`; without it the dongle enumerates but cannot be opened |
| `image` | builds `sdkclient/Dockerfile` — gRPC **1.28.1** from source, which no distro packages |
| `client` | builds inside that image against the full `libManusSDK.so`, needed for remote mode |
| `client-native` | host build against `libManusSDK_Integrated.so`; standalone only, and integrated mode needs a license feature legacy licenses lack |
| `ros2-image` | ROS2 build/run environment, so no host ROS2 install is needed |
| `ros2` / `ros2-run` | build and run the publisher in that image, `--network host` so its topics reach the host's DDS domain |
| `ros2-shell` | interactive shell with ROS2 and the workspace sourced |
| `vm-up` | runs `vm/setup.sh`: macvlan network, host shim, routes, VM, guest discovery |
| `down` | stops the clients, the VM and the network. Matches on this repo's images, so unrelated containers are untouched. `vm-down` stops only the VM |
| `run` | the client **inside** the container on `manus-lan`, so it and the Windows guest are macvlan siblings and can reach each other directly |

### Local patches to the SDK client

Re-apply if you drop in a fresh SDK package:

1. `ClientLogging.hpp` needs `#include <cstdint>`. Upstream omits it; gcc 9 pulled
   it in transitively, gcc 13 does not, so a stock build fails with
   `uint8_t does not name a type`.
2. The Makefile takes `MANUS_LIB` instead of hardcoding `-lManusSDK`.

## ROS2

MANUS ships a ROS2 package only in 3.2.x, and it bundles the 3.2 library with the
`linuxTarget` check. This is that package ported to 2.5.1.

(The 2.5 downloads page calls its SDK *"including ROS2 Package"*, but the 2.5.1
archive contains only the four client examples — no ROS2 package. Hence the port.)

```sh
make ros2-image  # once
make ros2        # build
make ros2-run    # run
make ros2-shell  # then, elsewhere: ros2 topic echo /manus_glove_0
```

No host ROS2 install is needed — both build and run happen in the container.
`ros2-native` builds against a host installation instead, if you have one.

Publishes `/manus_glove_0` and `/manus_glove_1` at **120 Hz**, each carrying 25
raw skeleton nodes (position + quaternion) and 20 ergonomics values, plus
`/manus_glove_N/vibration_cmd` for haptics.

`ros2-run` reads the guest address from `vm/.guest-ip`, written by `make vm-up`.
Override with `make ros2-run CORE_IP=<addr>`, or delete the file to autodiscover.

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `connection_mode` | `remote` | `integrated` / `local` / `remote` |
| `core_ip` | *(empty)* | pin a MANUS Core; empty autodiscovers |
| `glove_topic_template` | `manus_glove_{index}` | topic naming |
| `vibration_suffix` | `vibration_cmd` | haptics subtopic |

### What the port changed

1. **Thumb ergonomics enums.** 3.x renamed them to anatomically correct joints.
   They index the same four slots of `ErgonomicsData.data`, so it is a pure
   rename — `CMCSpread→MCPSpread`, `CMCStretch→MCPStretch`,
   `MCPStretch→PIPStretch`, `IPStretch→DIPStretch`. Cross-checked against
   SDKClient 2.5.1's `PrintHandErgoData`, which labels those same slots
   cmc/cmc/mcp/ip, and against live values from both programs at once.
2. **Library layout.** 2.5.1 ships a flat `lib/libManusSDK.so`; 3.2.x uses
   `lib/<arch>/libManusSDK-<arch>.so`.
3. **Connection mode.** Upstream hardcodes integrated, which needs a license
   feature legacy licenses lack. Now a ROS parameter, defaulting to remote.
4. **gRPC.** Remote mode needs the full library, which links gRPC **1.28.1**. A
   matched set is vendored in `ros2/src/ManusSDK/lib/thirdparty/`, taken from the
   container image.
5. **Container needs the SDK's own deps.** `libManusSDK.so` links libusb, libudev
   and libzmq; the ROS2 image installs them, or the link fails with
   `undefined reference to libusb_init`.
6. **RPATH not RUNPATH.** `$ORIGIN` has to reach `libManusSDK.so`'s *own*
   dependencies. `DT_RUNPATH` is not inherited by transitive deps, so the build
   forces `DT_RPATH` via `-Wl,--disable-new-dtags`.

## Licensing

The constraint that shapes this repo. Licenses live on the dongle, not on disk.

- **Integrated mode** (standalone, no Core) needs a Feature license with the
  **SDK (integrated)** feature, required since Core 2.4.0. Without it the client
  initializes, starts its services, reaches the menu, then refuses with
  `No compatible license found. Please connect a license with the SDK component.`
- **Core 3.x rejects all legacy licenses.** They work only on Core 2.5.1 and below.
- **Remote mode on 2.5.x accepts legacy tiers**: Core Pro, Core XR, Core Xsens Pro,
  Core Qualisys Pro, Core OptiTrack Pro, Demo.

Hence: legacy license → Core 2.5.1 + remote mode. Feature license with SDK and
Linux → 3.2.x natively.

## Binaries are not tracked

`.gitignore` excludes every `libManusSDK*.so` — proprietary MANUS binaries, not
ours to redistribute. Tracked content is under 1 MB; with the binaries in place
the tree is a few hundred MB.

To restore after a clone, get the **MANUS Core 2.5.1 SDK** from MANUS Downloads
and copy `SDKClient_Linux/ManusSDK/lib/` into `sdkclient/ManusSDK/`,
`minimalclient/ManusSDK/` and `ros2/src/ManusSDK/`.

`ros2/src/ManusSDK/lib/thirdparty/` additionally needs the gRPC 1.28.1 set; the
simplest source is the `manus-linux` image built by `make image`:

```sh
cid=$(docker create --entrypoint bash manus-linux)
for l in libgrpc.so.9 libgrpc++.so.1 libgpr.so.9 libaddress_sorting.so.9 \
         libprotobuf.so.22 libupb.so.9; do
  docker cp -L "$cid:/usr/local/lib/$l" ros2/src/ManusSDK/lib/thirdparty/
done
docker rm -f $cid
```

## The Windows VM

```sh
make vm-up
```

`vm/setup.sh` derives your LAN interface, subnet and gateway from the host,
creates the docker macvlan network, the host shim interface and the routes,
starts the VM, and waits for Windows to take a DHCP lease — then records its
address in `vm/.guest-ip`. Re-runnable, and it is how you recover after a reboot,
since the shim and routes do not persist.

The first run installs Windows unattended and downloads several GB.

### Installing MANUS Core in the VM

`make vm-up` gives you a Windows desktop with the dongle attached, but Core is not
installed — do this once, inside the guest.

1. **Download the version-locked installer**, not the web installer. The web
   installer will offer to update you to 3.x, which rejects legacy licenses.

   [`MANUS_Core_2.5.1_Version_Locked_Installer.zip`](https://static.manus-meta.com/resources/manus_core_2/version_locked_installer/MANUS_Core_2.5.1_Version_Locked_Installer.zip)
   — from the [2.5 downloads page](https://docs.manus-meta.com/2.5.0/Resources/).
   No login required.

   Easiest route in: drop the zip in `vm/shared/`, which appears as drive `Z:`
   inside Windows.

2. **Run the setup wizard**, then launch MANUS Core. It opens the Dashboard and
   keeps running in the tray; Core must be running for the gloves to work.

3. **Create a user.** Core prompts for one on first launch — one per person
   wearing gloves. At least one must exist. When it asks about gloves vs.
   trackers, choose gloves; there is no tracking system here.

4. **Pair the gloves** from the Dashboard's Devices tab. Per-product instructions:
   [Quantum Metagloves](https://docs.manus-meta.com/2.5.0/Products/Quantum%20Mocap%20Metagloves/FirstTimeSetup/),
   [Prime 3](https://docs.manus-meta.com/2.5.0/Products/Prime%203%20Mocap/FirstTimeSetup/),
   [Prime 2/X](https://docs.manus-meta.com/2.5.0/Products/Prime%202%20and%20Prime%20X/FirstTimeSetup/).

5. **Calibrate** from the same tab. Worth doing properly — it is what the joint
   angles are measured against.

6. **Check Devices → License.** It should name your tier. If the dongle shows as
   unlicensed, nothing downstream will work; see [Licensing](#licensing).

Afterwards, only steps from *Each session* are needed: `make vm-up`, start Core
from the tray, then `make run` or `make ros2-run`.

**If the Linux client finds the host but cannot connect**, check Windows Firewall
— a fresh install blocks inbound connections on networks it treats as Public,
which stops the SDK's TCP connection while leaving UDP discovery working. Setting
the network to Private, or allowing MANUS Core through, fixes it.

Pairing, calibration, firmware updates and device telemetry all live in the
Dashboard. In remote mode the Linux side only consumes data — everything about
managing the devices happens here.

### Why it needs root

Creating a macvlan interface, adding routes, and ARP-scanning for the guest all
require it. Everything else runs as you.

### Why the networking is unusual

The SDK finds Core by **UDP broadcast**, which cannot cross NAT — so the guest
cannot sit behind the default QEMU NAT. It gets a real LAN address instead
(macvlan plus dockur's `DHCP: "Y"`).

That creates a second problem: the Linux kernel deliberately refuses to let a host
talk to its own macvlan children through the same NIC. The fix is a second macvlan
interface owned by the host — the "shim" — with `/32` routes for the container and
the guest pointed at it.

None of this would be needed if Core ran on a separate physical machine; it is
purely the cost of host and guest sharing one NIC. Running the VM under libvirt
with its default NAT bridge would also avoid it, at the cost of not using Docker.

### Other things to know

- **ROS2 containers need `--ipc=host`.** Fast DDS moves data over `/dev/shm`;
  without a shared IPC namespace, `ros2 topic list` works but `echo` returns
  nothing. The Makefile passes it.
- **The VM owns the dongle while it runs.** `make vm-down` returns it.
- **Any device reset breaks passthrough** — firmware updates, replugging. QEMU does
  not re-attach. Restart the container; confirm the dongle's interfaces under
  `/sys/bus/usb/devices/*/` point their `driver` at `usbfs`.
- **The guest address can change** on DHCP renewal. Re-run `make vm-up`.
- `DHCP: "Y"` requires a broad `c *:* rwm` device rule, granting the container
  access to all character devices. Noted in `vm/compose.yml`.
