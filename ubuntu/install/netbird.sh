#!/bin/bash
set -e

# ========================================================
#  5echo.io - NetBird Client Installer
#  Version: 1.1.0
#  Source:  https://5echo.io
#  Run: curl -fsSL https://scripts.5echo.io/ubuntu/install/netbird.sh | sudo bash
# ========================================================

NETBIRD_DIR="${NETBIRD_DIR:-netbird}"
NB_SETUP_KEY="${NB_SETUP_KEY:-}"

GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RED="\e[31m"; NC="\e[0m"

SCRIPT_VERSION="1.1.0"

banner() {

  HOSTNAME_SHORT="$(hostname -s)"
  USER_NAME="${SUDO_USER:-$USER}"

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-$NAME}"
    OS_CODE="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  fi

  KERNEL="$(uname -r)"
  ARCH="$(uname -m)"
  NOW="$(date '+%Y-%m-%d %H:%M:%S')"

  echo -e "${BLUE}==============================================${NC}"
  echo -e "${BLUE}           5echo.io - NetBird Installer${NC}"
  echo -e "${BLUE}==============================================${NC}"
  printf " %-7s v%s\n" "Script:" "$SCRIPT_VERSION"
  printf " %-7s %-22s %-7s %s\n" "Host:" "$HOSTNAME_SHORT" "User:" "$USER_NAME"
  printf " %-7s %s (%s)\n" "OS:" "$OS_PRETTY" "$OS_CODE"
  printf " %-7s %-22s %-7s %s\n" "Kernel:" "$KERNEL" "Arch:" "$ARCH"
  printf " %-7s %s\n" "Time:" "$NOW"
  echo
}

STEP_INDEX=0

run_step() {

  local title="$1"
  shift

  STEP_INDEX=$((STEP_INDEX + 1))
  local logf
  logf="$(mktemp /tmp/netbird-step.XXXXXX.log)"

  ( "$@" >"$logf" 2>&1 ) &
  local pid=$!

  local spin=( '|' '/' '-' '\' )
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r\033[K${BLUE}[%d] %s${NC}  %s" "$STEP_INDEX" "$title" "${spin[$i]}"
    i=$(( (i + 1) % 4 ))
    sleep 0.15
  done

  wait "$pid"
  local rc=$?

  printf "\r\033[K"

  if [ $rc -eq 0 ]; then
    echo -e "${GREEN}[${STEP_INDEX}] ${title}... Done!${NC}"
    rm -f "$logf"
  else
    echo -e "${RED}[${STEP_INDEX}] ${title}... Failed!${NC}"
    tail -n 80 "$logf"
    exit 1
  fi
}

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

footer() {

  echo
  echo -e "${YELLOW}Summary:${NC}"
  echo -e "  NetBird folder: ${BLUE}${PWD}/${NETBIRD_DIR}${NC}"
  echo
  echo -e "${YELLOW}Powered by 5echo.io${NC}"
  echo -e "${BLUE}2026 © 5echo.io${NC}"
}

trap footer EXIT

clear
banner

# Ensure root
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Run with sudo:${NC}"
  echo "curl -fsSL https://scripts.5echo.io/ubuntu/install/netbird.sh | sudo bash"
  exit 1
fi

# Ask setup key
if [ -z "$NB_SETUP_KEY" ]; then
  ask_input_hidden "Enter NetBird Setup Key:" NB_SETUP_KEY
fi

if [ -z "$NB_SETUP_KEY" ]; then
  echo -e "${RED}NB_SETUP_KEY cannot be empty${NC}"
  exit 1
fi

# Install curl if missing
run_step "Ensuring curl is installed" bash -lc '
apt-get update -y
apt-get install -y curl
'

# Install Docker if missing
if ! command -v docker >/dev/null 2>&1; then

run_step "Installing Docker" bash -lc '
curl -fsSL https://scripts.5echo.io/ubuntu/install/docker.sh | bash
'

fi

# Enable IP forwarding
run_step "Enabling IP forwarding" bash -lc '

sysctl -w net.ipv4.ip_forward=1

grep -q net.ipv4.ip_forward /etc/sysctl.conf || \
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
'

# Disable rp_filter
run_step "Disabling rp_filter" bash -lc '

sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
'

# Configure firewall
run_step "Configuring firewall rules (RFC1918)" bash -lc '

if command -v ufw >/dev/null 2>&1; then

ufw allow from 10.0.0.0/8 || true
ufw allow from 172.16.0.0/12 || true
ufw allow from 192.168.0.0/16 || true

fi
'

# Create directory
run_step "Creating NetBird directory" bash -lc "
mkdir -p ${NETBIRD_DIR}
"

# Write docker compose
run_step "Writing docker compose file" bash -lc "

cat > ${NETBIRD_DIR}/docker-compose.yml <<EOF
version: '3.8'

services:
  netbird-client:
    image: netbirdio/netbird:latest
    container_name: netbird-client
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    environment:
      - NB_SETUP_KEY=${NB_SETUP_KEY}
    volumes:
      - netbird-client:/var/lib/netbird
    network_mode: host

volumes:
  netbird-client:
EOF

chmod 600 ${NETBIRD_DIR}/docker-compose.yml
"

# Start container
run_step "Starting NetBird container" bash -lc "

cd ${NETBIRD_DIR}
docker compose up -d
"

run_step "Verifying container" bash -lc "

docker ps --filter name=netbird-client
"
