#!/usr/bin/env bash
# One-shot setup for the MANUS Windows VM.   Usage:  sudo ./setup.sh
#
# Nothing to edit - the LAN interface, subnet, gateway and all addresses are
# derived from the host. Re-runnable; also the way to recover after a reboot,
# since the shim interface and routes do not persist.
#
# Why this is needed at all: MANUS Core is discovered over UDP broadcast, which
# cannot cross NAT, so the Windows guest must be a real device on the LAN
# (macvlan + dockur's DHCP mode). The Linux kernel then refuses to let this host
# reach its own macvlan children through the same NIC, so we add a "shim"
# macvlan interface for the host and route the VM through it.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
[ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"
REAL_USER=${SUDO_USER:-$USER}
NET=manus-lan; SHIM=manus-shim

need() { command -v "$1" >/dev/null || { echo "missing: $1 (apt install $2)"; exit 1; }; }
need docker docker.io; need arp-scan arp-scan; need python3 python3

# --- derive LAN config from the host ----------------------------------------
PARENT=$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
GATEWAY=$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
CIDR=$(ip -o -f inet addr show "$PARENT" | awk '{print $4; exit}')
read -r SUBNET RANGE SHIM_IP <<<"$(python3 - "$CIDR" <<'PY'
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1],strict=False); h=list(n.hosts())
block=ipaddress.ip_network(f"{h[-8]}/29",strict=False)   # top /29 for containers
print(n, block, h[-9])                                   # shim sits just below it
PY
)"
echo "iface=$PARENT  gw=$GATEWAY  subnet=$SUBNET  pool=$RANGE  shim=$SHIM_IP"

# --- docker macvlan network --------------------------------------------------
if docker network inspect "$NET" >/dev/null 2>&1; then
  HAVE=$(docker network inspect "$NET" --format '{{(index .IPAM.Config 0).IPRange}}')
  if [ "$HAVE" != "$RANGE" ]; then
    echo "network $NET exists with range $HAVE, expected $RANGE."
    echo "remove it and re-run:  docker network rm $NET"; exit 1
  fi
else
  docker network create -d macvlan --subnet="$SUBNET" --gateway="$GATEWAY" \
    --ip-range="$RANGE" -o parent="$PARENT" "$NET" >/dev/null
  echo "created docker network $NET"
fi

# --- host shim ---------------------------------------------------------------
ip link del "$SHIM" 2>/dev/null || true
ip link add "$SHIM" link "$PARENT" type macvlan mode bridge
ip addr add "$SHIM_IP/32" dev "$SHIM"
ip link set "$SHIM" up

# --- start the VM ------------------------------------------------------------
docker compose up -d
CONTAINER_IP=$(docker inspect manus-windows \
  --format "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}")
ip route replace "$CONTAINER_IP/32" dev "$SHIM"
echo "container=$CONTAINER_IP  viewer=http://$CONTAINER_IP:8006"

# --- find Windows once it takes a DHCP lease ---------------------------------
echo "waiting for Windows to take a DHCP lease (up to 5 min)..."
MAC=$(for _ in $(seq 1 30); do
        m=$(docker logs manus-windows 2>&1 | grep -oE "MAC: [0-9A-Fa-f:]{17}" | tail -1 | cut -d' ' -f2)
        [ -n "$m" ] && { echo "$m"; break; }; sleep 2
      done)
[ -n "$MAC" ] || { echo "could not read guest MAC from dockur logs"; exit 1; }

GUEST_IP=$(for _ in $(seq 1 60); do
             # NB: --localnet is wrong here - the shim holds a /32, so it would
             # scan a single address. Scan the real subnet instead.
             g=$(arp-scan --interface="$SHIM" "$SUBNET" 2>/dev/null \
                 | awk -v m="${MAC,,}" 'tolower($2)==m {print $1; exit}')
             [ -n "$g" ] && { echo "$g"; break; }; sleep 5
           done)

if [ -n "$GUEST_IP" ]; then
  ip route replace "$GUEST_IP/32" dev "$SHIM"
  printf '%s\n' "$GUEST_IP" > .guest-ip; chown "$REAL_USER" .guest-ip
  echo; echo "Windows: $GUEST_IP   (also saved to vm/.guest-ip)"
  echo "Start MANUS Core there, then run the SDK client and pick Remote."
else
  echo; echo "No lease yet - Windows may still be booting."
  echo "Re-run this script once it reaches the desktop; nothing else needs redoing."
fi
