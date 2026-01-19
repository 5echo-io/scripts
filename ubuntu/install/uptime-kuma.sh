#!/bin/bash
set -e

# ========================================================
#  5echo.io Uptime Kuma + MariaDB Installer (Docker Compose)
#  Version: 1.0.0
#  Source : https://5echo.io
# ========================================================

# ---- Config (env-overridable) --------------------------
APP_DIR="${APP_DIR:-/uptimekuma}"
HOST_PORT="${HOST_PORT:-3001}"
DB_NAME="${DB_NAME:-uptimekuma}"
DB_USER="${DB_USER:-kumauser}"
DB_PASS="${DB_PASS:-}"          # auto-generate if empty
DB_ROOT_PASS="${DB_ROOT_PASS:-}"# auto-generate if empty
USE_TRAEFIK_NET="${USE_TRAEFIK_NET:-0}"  # 1=attach to external kuma_net
FORCE_REDEPLOY="${FORCE_REDEPLOY:-0}"    # 1=stop/remove existing containers + redeploy
# --------------------------------------------------------

# Colors
GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RED="\e[31m"; NC="\e[0m"

SCRIPT_VERSION="1.0.0"

# Summary state
ACTION="unknown"
SUMMARY_PATH=""
SUMMARY_PORT=""
SUMMARY_URL=""
SUMMARY_DOCKER=""

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
  echo -e "${BLUE}      5echo.io - Uptime Kuma Installer${NC}"
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

footer() {
  echo -e "\n${YELLOW}Summary:${NC}"
  echo -e "  Action: ${BLUE}${ACTION}${NC}"
  [ -n "$SUMMARY_PATH" ] && echo -e "  Path:   ${SUMMARY_PATH}"
  [ -n "$SUMMARY_PORT" ] && echo -e "  Port:   ${SUMMARY_PORT}"
  [ -n "$SUMMARY_URL" ]  && echo -e "  URL:    ${SUMMARY_URL}"
  if command -v docker >/dev/null 2>&1; then
    SUMMARY_DOCKER="$(docker --version 2>/dev/null | sed 's/^/  Docker: /')"
    [ -n "$SUMMARY_DOCKER" ] && echo -e "${SUMMARY_DOCKER}"
  fi
  echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
  echo -e "${BLUE}2025 © 5echo.io${NC}\n"
}
trap footer EXIT

# --- Step numbering & clean spinner (ASCII) -------------
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
    echo -e "${YELLOW}Last 120 log lines:${NC}"
    tail -n 120 "$logf" || true
    echo -e "${YELLOW}Full log:${NC} $logf"
    exit 1
  fi
}

ask_yes_no() {
  local q="$1"; local def="${2:-N}"; local prompt="[y/N]"
  [ "$def" = "Y" ] && prompt="[Y/n]"
  local ans=""

  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s %s " "$q" "$prompt" > /dev/tty
    IFS= read -r ans < /dev/tty || true
  elif [ -t 0 ]; then
    read -r -p "$q $prompt " ans || true
  else
    :
  fi

  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO)   return 1 ;;
    *)           [ "$def" = "Y" ] && return 0 || return 1 ;;
  esac
}

ask_input() {
  # usage: ask_input "Question" "default" -> prints answer
  local q="$1"; local def="$2"; local ans=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s [%s]: " "$q" "$def" > /dev/tty
    IFS= read -r ans < /dev/tty || true
  else
    read -r -p "$q [$def]: " ans || true
  fi
  [ -z "$ans" ] && ans="$def"
  printf "%s" "$ans"
}

gen_pw() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo -e "${RED}Missing: $1${NC}"; exit 1; }
}

# === Start ===
clear
banner

ACTION="install"

# 1) Check prerequisites (docker + compose)
run_step "Checking prerequisites (docker + compose)" bash -lc '
  command -v docker >/dev/null 2>&1
  docker compose version >/dev/null 2>&1
'

# 2) Collect config (TTY-safe)
if [ "$FORCE_REDEPLOY" -ne 1 ]; then
  echo -e "${YELLOW}Config:${NC} (trykk Enter for standard)"
  HOST_PORT="$(ask_input "Host port for Uptime Kuma" "$HOST_PORT")"
  APP_DIR="$(ask_input "Install path" "$APP_DIR")"
  DB_NAME="$(ask_input "MariaDB database name" "$DB_NAME")"
  DB_USER="$(ask_input "MariaDB user" "$DB_USER")"
  if ask_yes_no "Use external Traefik network 'kuma_net'?" "N"; then
    USE_TRAEFIK_NET=1
  else
    USE_TRAEFIK_NET=0
  fi
  if ask_yes_no "Redeploy (stop/remove existing uptime-kuma containers)?" "N"; then
    FORCE_REDEPLOY=1
  fi
else
  USE_TRAEFIK_NET="${USE_TRAEFIK_NET:-0}"
fi

# Auto-generate passwords if empty
[ -z "$DB_PASS" ] && DB_PASS="$(gen_pw)"
[ -z "$DB_ROOT_PASS" ] && DB_ROOT_PASS="$(gen_pw)"

SUMMARY_PATH="$APP_DIR"
SUMMARY_PORT="$HOST_PORT"

# 3) Create directory
run_step "Preparing install directory" bash -lc "
  sudo mkdir -p '$APP_DIR'
  sudo chown '${SUDO_USER:-$USER}':'${SUDO_USER:-$USER}' '$APP_DIR'
"

# 4) Optional redeploy: stop/remove existing containers
if [ "$FORCE_REDEPLOY" -eq 1 ]; then
  ACTION="redeploy"
  run_step "Stopping previous uptime-kuma containers (if any)" bash -lc "
    sudo docker rm -f uptime-kuma uptimekuma-mariadb >/dev/null 2>&1 || true
  "
fi

# 5) Write docker-compose.yml
run_step "Writing docker-compose.yml" bash -lc "
  cat > '$APP_DIR/docker-compose.yml' <<'EOF'
services:
  mariadb:
    image: mariadb:11
    container_name: uptimekuma-mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: '${DB_ROOT_PASS}'
      MYSQL_DATABASE: '${DB_NAME}'
      MYSQL_USER: '${DB_USER}'
      MYSQL_PASSWORD: '${DB_PASS}'
    volumes:
      - ./mariadb-data:/var/lib/mysql
EOF
  if [ '$USE_TRAEFIK_NET' -eq 1 ]; then
    cat >> '$APP_DIR/docker-compose.yml' <<'EOF'
    networks:
      - kuma_net
EOF
  fi

  cat >> '$APP_DIR/docker-compose.yml' <<'EOF'

  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    depends_on:
      - mariadb
    ports:
      - '${HOST_PORT}:3001'
    volumes:
      - ./uptimekuma-data:/app/data
    environment:
      UPTIME_KUMA_DB_TYPE: 'mariadb'
      UPTIME_KUMA_DB_HOSTNAME: 'mariadb'
      UPTIME_KUMA_DB_PORT: '3306'
      UPTIME_KUMA_DB_NAME: '${DB_NAME}'
      UPTIME_KUMA_DB_USERNAME: '${DB_USER}'
      UPTIME_KUMA_DB_PASSWORD: '${DB_PASS}'
      UPTIME_KUMA_IN_CONTAINER: 'true'
EOF
  if [ '$USE_TRAEFIK_NET' -eq 1 ]; then
    cat >> '$APP_DIR/docker-compose.yml' <<'EOF'
    networks:
      - kuma_net

networks:
  kuma_net:
    external: true
    name: kuma_net
EOF
  fi
"

# 6) Start stack
run_step "Pulling images" bash -lc "
  cd '$APP_DIR'
  sudo docker compose pull
"
run_step "Starting stack" bash -lc "
  cd '$APP_DIR'
  sudo docker compose up -d
"

# 7) Show status
run_step "Showing container status" bash -lc "
  sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | sed -n '1p;/uptime-kuma/p;/uptimekuma-mariadb/p'
"

SUMMARY_URL="http://SERVER-IP:${HOST_PORT}"

echo -e "\n${GREEN}Uptime Kuma is up!${NC}"
echo -e "Open: ${BLUE}http://SERVER-IP:${HOST_PORT}${NC}\n"
echo -e "${YELLOW}Tips:${NC}"
echo -e "  Logs Kuma   : ${BLUE}sudo docker logs -f uptime-kuma${NC}"
echo -e "  Logs MariaDB: ${BLUE}sudo docker logs -f uptimekuma-mariadb${NC}"
echo -e "  Manage      : ${BLUE}cd ${APP_DIR} && sudo docker compose down && sudo docker compose up -d${NC}\n"
