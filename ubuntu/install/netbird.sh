#!/bin/bash
set -e

# ========================================================
#  5echo.io - Ubuntu Bootstrap + NetBird Client (local dir)
#  Version: 0.2.0
#  Source:  https://5echo.io
# ========================================================

# ---- Config (env-overridable) --------------------------
DEFAULT_MONITORING_KEY="${DEFAULT_MONITORING_KEY:-09290FC5-F263-4476-949E-1348CD7F09AE}"
NB_SETUP_KEY="${NB_SETUP_KEY:-}"           # If set, no prompts needed
NETBIRD_DIR="${NETBIRD_DIR:-netbird}"      # local folder name (relative)
SKIP_HELLO="${SKIP_HELLO:-1}"              # keep for parity (unused here)
# --------------------------------------------------------

# Colors
GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RED="\e[31m"; NC="\e[0m"

SCRIPT_VERSION="0.2.0"

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
  [ -n "$SUMMARY_DIR" ]     && echo -e "  Folder: ${SUMMARY_DIR}"
  [ -n "$SUMMARY_DOCKER" ]  && echo -e "  Docker: ${SUMMARY_DOCKER}"
  [ -n "$SUMMARY_NETBIRD" ] && echo -e "  NetBird: ${SUMMARY_NETBIRD}"
  echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
  echo -e "${BLUE}2026 © 5echo.io${NC}\n"
}
trap footer EXIT

# --- Step numbering & spinner ---------------------------
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

ask_yes_no() {
  local q="$1"; local def="${2:-Y}"; local prompt="[Y/n]"
  [ "$def" = "N" ] && prompt="[y/N]"
  local ans=""

  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s %s " "$q" "$prompt" > /dev/tty
    IFS= read -r ans < /dev/tty || true
  elif [ -t 0 ]; then
    read -r -p "$q $prompt " ans || true
  fi

  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO)   return 1 ;;
    *)           [ "$def" = "Y" ] && return 0 || return 1 ;;
  esac
}

ask_input_hidden() {
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
    read -r -p "$prompt " ans || true
  fi

  eval "$__varname=\"\$ans\""
}

# === Start ===
clear
banner

# 0) Ensure we're root (script uses sudo, but this avoids weirdness)
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Please run with sudo:${NC} sudo bash <script>"
  exit 1
fi

# 1) Update & Upgrade
run_step "Updating and upgrading system packages" bash -lc '
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update -y
  apt-get upgrade -y
'

# 2) Ensure curl
run_step "Installing curl" bash -lc '
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get install -y curl
'

# 3) Install Docker (via your existing docker installer)
run_step "Installing Docker (via scripts.5echo.io)" bash -lc '
  curl -fsSL https://scripts.5echo.io/ubuntu/install/docker.sh | bash
'

if command -v docker >/dev/null 2>&1; then
  SUMMARY_DOCKER="$(docker --version 2>/dev/null || true)"
else
  SUMMARY_DOCKER="not found (install may have failed)"
  echo -e "${RED}Docker command not found after install. Aborting.${NC}"
  exit 1
fi

# 4) Decide key (default monitoring key vs custom)
if [ -z "$NB_SETUP_KEY" ]; then
  echo -e "${YELLOW}NetBird setup key:${NC}"
  echo -e "  Default monitoring key is set."
  if ask_yes_no "Use Default monitoring key?" "Y"; then
    NB_SETUP_KEY="$DEFAULT_MONITORING_KEY"
  else
    ask_input_hidden "Enter custom NB_SETUP_KEY (hidden input):" NB_SETUP_KEY
  fi
fi

if [ -z "$NB_SETUP_KEY" ]; then
  echo -e "${RED}NB_SETUP_KEY is empty. Aborting.${NC}"
  exit 1
fi

# 5) Create local folder (visible with ls/la) and write compose there
run_step "Creating local folder ./${NETBIRD_DIR}" bash -lc '
  mkdir -p "'"$NETBIRD_DIR"'"
'

SUMMARY_DIR="$(pwd)/${NETBIRD_DIR}"

run_step "Writing docker-compose.yaml in ./${NETBIRD_DIR}" bash -lc '
  cd "'"$NETBIRD_DIR"'"
  cat > docker-compose.yaml <<EOF
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
  chmod 600 docker-compose.yaml
'

# 6) Start container
run_step "Starting NetBird client container" bash -lc '
  cd "'"$NETBIRD_DIR"'"
  docker compose up -d
  docker ps --filter "name=netbird-client" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
'

SUMMARY_NETBIRD="deployed (container: netbird-client)"
