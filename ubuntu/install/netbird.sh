#!/usr/bin/env bash
# ========================================================
#  5echo.io - NetBird Gateway Installer + Updater
#  Version: 1.5.0
#  Source:  https://5echo.io
#  Run: curl -fsSL https://scripts.5echo.io/ubuntu/install/netbird.sh | sudo bash
# ========================================================

set -e

APP="NetBird Gateway"
VERSION="1.5.0"
INSTALL_DIR="/opt/netbird"

clear

echo "=============================================="
echo "      5echo.io - NetBird Gateway Installer + Updater"
echo "=============================================="
echo " Script: v$VERSION"
echo " Run:    curl -fsSL https://scripts.5echo.io/ubuntu/install/netbird.sh | sudo bash"
echo
echo " Host:   $(hostname)"
echo " User:   $(whoami)"
echo " OS:     $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo " Kernel: $(uname -r)"
echo " Arch:   $(uname -m)"
echo " Time:   $(date '+%Y-%m-%d %H:%M:%S')"
echo

if [ "$EUID" -ne 0 ]; then
  echo "Please run with sudo"
  exit 1
fi

############################################
# Hidden input
############################################
ask_input_hidden() {
  local prompt="$1"
  local __var="$2"
  local ans=""
  if [ -r /dev/tty ]; then
    printf "%s " "$prompt" > /dev/tty
    stty -echo < /dev/tty
    IFS= read -r ans < /dev/tty
    stty echo < /dev/tty
    printf "\n" > /dev/tty
  else
    read -r -p "$prompt " ans
  fi
  eval "$__var=\"\$ans\""
}

############################################
# Check if NetBird container exists
############################################
CONTAINER_NAME="netbird-client"
NETBIRD_EXISTS=0

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
  NETBIRD_EXISTS=1
  echo "Detected existing NetBird container: $CONTAINER_NAME"
fi

############################################
# NetBird Setup Key
############################################
NB_SETUP_KEY="${NB_SETUP_KEY:-}"

if [ -z "$NB_SETUP_KEY" ]; then
  if [ $NETBIRD_EXISTS -eq 1 ]; then
    # Try to read existing key from environment
    NB_SETUP_KEY=$(docker inspect "$CONTAINER_NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^NB_SETUP_KEY=' | cut -d= -f2)
    if [ -n "$NB_SETUP_KEY" ]; then
      echo "Using existing NB_SETUP_KEY from container."
    fi
  fi
  if [ -z "$NB_SETUP_KEY" ]; then
    ask_input_hidden "Enter NetBird Setup Key:" NB_SETUP_KEY
  fi
fi

if [ -z "$NB_SETUP_KEY" ]; then
  echo "NB_SETUP_KEY cannot be empty. Exiting."
  exit 1
fi

############################################
# Dependencies
############################################
echo
echo "Installing dependencies..."
apt update -y
apt install -y curl ca-certificates gnupg lsb-release iproute2 iptables

############################################
# Docker
############################################
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found — installing..."
  curl -fsSL https://get.docker.com | bash
fi

############################################
# Enable IP forwarding
############################################
echo
echo "Enabling IP forwarding..."
cat <<EOF >/etc/sysctl.d/99-netbird.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl --system >/dev/null

############################################
# Detect active interfaces
############################################
echo
echo "Detecting active network interfaces..."
INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(eth|wlan|vlan)')

if [ -z "$INTERFACES" ]; then
  echo "No active interfaces found. Exiting."
  exit 1
fi

echo "Active interfaces detected:"
for iface in $INTERFACES; do
  echo " • $iface"
done

############################################
# Detect subnets per interface
############################################
SUBNETS=""
for iface in $INTERFACES; do
  if_subnets=$(ip -o -f inet addr show dev "$iface" | awk '{print $4}')
  for s in $if_subnets; do
    SUBNETS="$SUBNETS $s"
  done
done

echo
echo "Detected local subnets:"
for s in $SUBNETS; do
  echo " • $s"
done

############################################
# Apply NAT per interface
############################################
echo
echo "Setting up NAT for all interfaces..."
for iface in $INTERFACES; do
  for s in $SUBNETS; do
    iptables -t nat -C POSTROUTING -s "$s" -o "$iface" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$s" -o "$iface" -j MASQUERADE
  done
done

############################################
# Install directory
############################################
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

############################################
# Docker Compose with labels
############################################
echo
echo "Creating docker-compose.yml..."
cat <<EOF > docker-compose.yml
version: "3.8"

services:

  netbird:
    image: netbirdio/netbird:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped

    network_mode: host
    cap_add:
      - NET_ADMIN

    environment:
      - NB_SETUP_KEY=$NB_SETUP_KEY

    volumes:
      - netbird-client:/var/lib/netbird

    labels:
      netbird.role: gateway
      netbird.subnets: "$SUBNETS"

volumes:
  netbird-client:
EOF

############################################
# Update or Start container
############################################
if [ $NETBIRD_EXISTS -eq 1 ]; then
  echo
  echo "Updating NetBird container..."
  docker compose pull
  docker compose up -d
else
  echo
  echo "Starting NetBird container..."
  docker compose up -d
fi

############################################
# Done
############################################
echo
echo "=============================================="
echo " NetBird Gateway installation/update complete"
echo "=============================================="
echo
echo "Install directory: $INSTALL_DIR"
echo
echo "Container status:"
docker ps --filter "name=$CONTAINER_NAME"
echo
echo "Detected LAN networks:"
for s in $SUBNETS; do
  echo " • $s"
done
echo
echo "Next steps:"
echo "1. Open the NetBird Admin Console"
echo "2. Navigate to Routes"
echo "3. Add routes for the networks above and assign this machine as gateway"
echo "4. Configure Access Policies for peers"
echo
echo "Security notice: No peers have access until policies are configured."
echo
echo "Powered by 5echo.io"
echo "2026 © 5echo.io"
echo
