#!/bin/bash
set -e

# ========================================================
#  5echo.io - Clean Ubuntu Bootstrap + NetBird Client
#  Version: 0.1.0
#  Source:  https://5echo.io
# ========================================================

# ---- Config (env-overridable) --------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/Netbird}"       # Where to create the Netbird folder
NB_SETUP_KEY="${NB_SETUP_KEY:-}"                 # If set, no prompt needed
DEFAULT_NB_SETUP_KEY="${DEFAULT_NB_SETUP_KEY:-}" # Optional future "default for all"
AUTO_YES="${AUTO_YES:-1}"                        # 1=noninteractive apt
# --------------------------------------------------------

# Colors
GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RED="\e[31m"; NC="\e[0m"

SCRIPT_VERSION="0.1.0"

banner() {
  local HOSTNAME_SHORT USER_NAME OS_PRETTY OS_CODE KERNEL ARCH NOW
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo unknown)"
  USER_NAME="${SUDO_USER:-$USER}"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-$NAME}"
    OS_CODE="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  fi
  KERNEL="$(uname -r 2>/dev/null || echo unknown)"
  ARCH="$(uname -m 2>/dev/null || echo unknown)"
  NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '')"

  echo -e "${BLUE}==============================================${NC}"
  echo -e "${BLUE}      5echo.io - Ubuntu Bootstrap + NetBird${NC}"
  echo -e "${BLUE}==============================================${NC}"
  printf " %-7s v%s\n" "Script:" "$SCRIPT_VERSION"
  printf " %-7s %-22s %-7s %s\n" "Host:" "$HOSTNAME_SHORT" "User:" "$USER_NAME"
  if [ -n "${OS_PRETTY}" ]; then
    printf " %-7s %s (%s)\n" "OS:" "$OS_PRETTY" "${OS_CODE:-n/a}"
  fi
  printf " %-7s %-22s %-7s %s\n" "Kernel:" "$KERNEL" "Arch:" "$ARCH"
  if [ -n "${NOW}" ]; then
    printf " %-7s %s\n" "Time:" "$NOW"
  fi
  echo
}

# Summary state
ACTION="bootstrap+netbird"
SUMMARY_DIR=""
SUMMARY_DOCKER=""
SUMMARY_NETBIRD=""

footer() {
  echo -e "\n${YELLOW}Summary:${NC}"
  echo -e "  Action: ${BLUE}${ACTION}${NC}"
  [ -n "$SUMMARY_DIR" ]    && echo -e "  Folder: ${SUMMARY_DIR}"
  [ -n "$SUMMARY_DOCKER" ] && echo -e "  Docker: ${SUMMARY_DOCKER}"
  [ -n "$SUMMARY_NETBIRD" ]&& echo -e "  NetBird: ${SUMMARY_NETBIRD}"
  echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
  echo -e "${BLUE}2026 © 5echo.io${NC}\n"
}
trap footer EXIT

# --- Step numbering & clean spinner ----------------------
STEP_INDEX=0

run_step() {
  local title="$1"; shift
  STEP_INDEX=$((STEP_INDEX + 1))
  local logf; logf="$(mktemp /tmp/5echo-step.XXXXXX.log)"

  ( "$@" >"$logf" 2>&1 ) &
  local pid=$!

  local spin=( '|' '/' '-' '\' )
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r\033[K${BLUE}[%d] %s${NC}  %s" "$STEP_INDEX" "$title" "${spin[$i]}"
    i=$(( (i + 1) % ${#spin[@]} ))
    sleep 0.15
  done

  wait "$pid"; local rc=$?
  printf "\r\033[K"

  if [ $rc -eq 0 ]; then
    echo -e "${GREEN}[${STEP_INDEX}] ${title}... Done!${NC}"
    rm -f "$logf"
  else
    echo -e "${RED}[${STEP_INDEX}] ${title}... Failed!${NC}"
    echo -e "${YELLOW}Last 80 log lines:${NC}"
    tail -n 80 "$logf" || true
    echo -e "${YELLOW}Full log:${NC} $logf"
    exit 1
  fi
}

ask_input_hidden() {
  # usage: ask_input_hidden "Prompt" varname
  local prompt="$1"
  local __varname="$2"
  local ans=""

  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s " "$prompt" > /dev/tty
    stty -echo < /dev/tty 2>/dev/null || true
    IFS= read -r ans < /dev/tty || true
    stty echo < /dev/tty 2>/dev/null || true
    printf "\n" > /dev/tty
  else
    # fallback (not hidden)
    read -r -p "$prompt " ans || true
  fi

  # shellcheck disable=SC2163
  eval "$__varname=\"\$ans\""
}

# === Start ===
clear
banner

# 1) Update & Upgrade
run_step "Updating and upgrading system packages" bash -lc '
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  sudo -E apt-get update -y
  sudo -E apt-get upgrade -y
'

# 2) Ensure curl
run_step "Installing curl" bash -lc '
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  sudo -E apt-get install -y curl
'

# 3) Install Docker via 5echo script
run_step "Installing Docker (via scripts.5echo.io)" bash -lc '
  curl -fsSL https://scripts.5echo.io/ubuntu/install/docker.sh | sudo bash
'

# Quick sanity check
if command -v docker >/dev/null 2>&1; then
  SUMMARY_DOCKER="$(docker --version 2>/dev/null || true)"
else
  SUMMARY_DOCKER="not found (install may have failed)"
  echo -e "${RED}Docker command not found after install. Aborting.${NC}"
  exit 1
fi

# 4) Create Netbird folder + docker-compose.yaml
run_step "Creating Netbird folder" bash -lc '
  sudo mkdir -p "'"$INSTALL_DIR"'"
  sudo chmod 755 "'"$INSTALL_DIR"'"
'
SUMMARY_DIR="$INSTALL_DIR"

# 4b) Ask for NB_SETUP_KEY (supports future defaults)
if [ -z "$NB_SETUP_KEY" ]; then
  if [ -n "$DEFAULT_NB_SETUP_KEY" ]; then
    NB_SETUP_KEY="$DEFAULT_NB_SETUP_KEY"
  else
    ask_input_hidden "Enter NB_SETUP_KEY (hidden input):" NB_SETUP_KEY
  fi
fi

if [ -z "$NB_SETUP_KEY" ]; then
  echo -e "${RED}NB_SETUP_KEY was empty. Aborting (to avoid deploying a broken config).${NC}"
  exit 1
fi

run_step "Writing docker-compose.yaml for NetBird client" bash -lc '
  tmpf="$(mktemp /tmp/netbird-compose.XXXXXX.yaml)"
  cat > "$tmpf" <<EOF
version: "3.8"

services:
  netbird:
    container_name: netbird-client
    image: netbirdio/netbird:latest
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    environment:
      NB_SETUP_KEY: "'"$NB_SETUP_KEY"'"
    volumes:
      - netbird-client:/var/lib/netbird

volumes:
  netbird-client:
EOF
  sudo mv "$tmpf" "'"$INSTALL_DIR"'/docker-compose.yaml"
  sudo chmod 600 "'"$INSTALL_DIR"'/docker-compose.yaml"
'

# 5) Start container
run_step "Starting NetBird client container" bash -lc '
  cd "'"$INSTALL_DIR"'"
  sudo docker compose up -d
  sudo docker ps --filter "name=netbird-client" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
'

SUMMARY_NETBIRD="deployed (container: netbird-client)"
