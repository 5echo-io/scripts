#!/bin/bash
set -e

# ========================================================
#  5echo.io Docker Installer - Ubuntu/Debian
#  Version: 1.5.0
#  Source: https://5echo.io
# ========================================================

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RED="\e[31m"
NC="\e[0m" # Reset

# --- Progress bar state (overall) ---
TOTAL_STEPS=9
CURRENT_STEP=0

# Terminal capabilities (for sticky bar)
USE_TPUT=0
if command -v tput >/dev/null 2>&1 && [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; then
  if tput cup 0 0 >/dev/null 2>&1; then
    USE_TPUT=1
  fi
fi

progress_make_bar() {
  local percent="$1"
  local width=40
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local bar
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')"
  bar="$bar$(printf '%*s' "$empty" '' | tr ' ' '-')"
  printf "Progress: [%s] %3d%%" "$bar" "$percent"
}

progress_draw() {
  local current="$1"
  local total="$2"
  local percent=$(( 100 * current / total ))
  if [ "$USE_TPUT" -eq 1 ]; then
    tput sc
    local lines; lines="$(tput lines)"
    tput cup $((lines - 1)) 0
    tput el
    echo -ne "${BLUE}"
    progress_make_bar "$percent"
    echo -ne "${NC}"
    tput rc
  else
    echo -e "${BLUE}$(progress_make_bar "$percent")${NC}"
  fi
}

progress_clear_sticky() {
  if [ "$USE_TPUT" -eq 1 ]; then
    tput sc
    local lines; lines="$(tput lines)"
    tput cup $((lines - 1)) 0
    tput el
    tput rc
  fi
}

progress_advance() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  progress_draw "$CURRENT_STEP" "$TOTAL_STEPS"
}

# Minimalistic banner
banner() {
  echo -e "${BLUE}==============================================${NC}"
  echo -e "${BLUE}            5echo.io - Docker Installer${NC}"
  echo -e "${BLUE}==============================================${NC}\n"
}

footer() {
  # All exits show a clean final 100% line + footer
  progress_clear_sticky
  local _old="$USE_TPUT"
  USE_TPUT=0
  progress_draw "$TOTAL_STEPS" "$TOTAL_STEPS"
  USE_TPUT="$_old"
  echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
  echo -e "${BLUE}2025 © 5echo.io${NC}\n"
}

# Always show footer on exit (success, failure, or early exit)
trap footer EXIT

# Spinner for short tasks (non-apt). No constant redraw (avoids flicker).
loading() {
  local message="$1"
  shift
  echo -ne "${BLUE}${message}${NC}"
  local spin='|/-\\'
  local i=0

  ("$@" >/dev/null 2>&1) &
  local pid=$!

  while kill -0 $pid 2>/dev/null; do
    printf "\r${BLUE}${message}${NC} ${spin:$i:1}"
    i=$(( (i + 1) % 4 ))
    sleep 0.2
  done

  wait $pid
  local exit_code=$?

  if [ $exit_code -eq 0 ]; then
    printf "\r${GREEN}${message}... Done!${NC}\n"
  else
    printf "\r${RED}${message}... Failed!${NC}\n"
    exit 1
  fi
}

# For apt operations: show native apt progress bar (no backgrounding or redirection)
apt_run() {
  local title="$1"; shift
  echo -e "${BLUE}${title}${NC}"
  progress_clear_sticky
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  sudo apt-get -o Dpkg::Progress-Fancy=1 -y \
       -o Dpkg::Options::="--force-confdef" \
       -o Dpkg::Options::="--force-confold" \
       "$@"
  echo
}

# === Start ===
clear
banner
progress_draw 0 "$TOTAL_STEPS"

# 1) Ensure curl is installed
loading "Checking curl (and installing if missing)" bash -c "
  if ! command -v curl >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y curl
  fi
"
progress_advance

# 2) Check Docker status via helper (avoid quoting issues)
STATUS_FILE="/tmp/docker_status_5echo"
CHECK_SCRIPT="$(mktemp /tmp/5echo-check-docker.XXXXXX.sh)"

cat <<'EOS' > "$CHECK_SCRIPT"
#!/bin/bash
set -e

STATUS_FILE="/tmp/docker_status_5echo"
: > "$STATUS_FILE"

# If docker is not installed, mark absent and exit
if ! command -v docker >/dev/null 2>&1; then
  echo "absent" > "$STATUS_FILE"
  exit 0
fi

# Ensure Docker repo exists so candidate version is accurate
sudo install -m 0755 -d /etc/apt/keyrings

if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  . /etc/os-release
  CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc 2>/dev/null || true
  if [ -s /tmp/docker.asc ]; then
    sudo mv /tmp/docker.asc /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
fi

sudo apt-get update -qq || true

# Determine package origin
if dpkg -s docker-ce >/dev/null 2>&1; then
  PKG=docker-ce
elif dpkg -s docker.io >/dev/null 2>&1; then
  PKG=docker.io
else
  echo "needs_update" > "$STATUS_FILE"
  exit 0
fi

if [ "$PKG" = "docker-ce" ]; then
  INSTALLED=$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)
  CANDIDATE=$(apt-cache policy docker-ce | awk '/Candidate:/ {print $2}')
  if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "(none)" ] && [ "$INSTALLED" = "$CANDIDATE" ]; then
    echo "up_to_date" > "$STATUS_FILE"
  else
    echo "needs_update" > "$STATUS_FILE"
  fi
  exit 0
fi

# docker.io installed -> migrate/update to docker-ce
if [ "$PKG" = "docker.io" ]; then
  echo "needs_update" > "$STATUS_FILE"
  exit 0
fi
EOS
chmod +x "$CHECK_SCRIPT"

loading "Checking Docker status" bash "$CHECK_SCRIPT"
progress_advance

DOCKER_STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo absent)"

if [ "$DOCKER_STATUS" = "up_to_date" ]; then
  echo -e "${GREEN}Docker is already at the latest version. Exiting.${NC}"
  rm -f "$CHECK_SCRIPT" "$STATUS_FILE" 2>/dev/null || true
  exit 0
fi

# 3) Remove old Docker packages (quiet clean-up)
loading "Removing old Docker packages" bash -c "
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get remove -y \$pkg >/dev/null 2>&1 || true
  done
"
progress_advance

# 4) Add/refresh Docker repository
loading "Adding Docker repository" bash -c "
  sudo apt-get update -qq &&
  sudo apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null &&
  sudo install -m 0755 -d /etc/apt/keyrings &&
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc &&
  sudo chmod a+r /etc/apt/keyrings/docker.asc &&
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  \$(. /etc/os-release && echo \"\${UBUNTU_CODENAME:-\$VERSION_CODENAME}\") stable\" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null &&
  sudo apt-get update -qq
"
progress_advance

# 5) Install/Upgrade (foreground, show apt progress bar)
if [ "$DOCKER_STATUS" = "needs_update" ]; then
  apt_run "Upgrading Docker to latest" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  apt_run "Installing Docker packages" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
progress_advance

# 6) Enable Docker service
loading "Enabling Docker service" sudo systemctl enable docker
progress_advance

# 7) Start Docker service
loading "Starting Docker service" sudo systemctl start docker
progress_advance

# 8) Test Docker installation
loading "Testing Docker installation" docker --version
progress_advance

# 9) Run hello-world
loading "Running Docker hello-world test" sudo docker run --rm hello-world
progress_advance

# Cleanup
rm -f "$CHECK_SCRIPT" "$STATUS_FILE" 2>/dev/null || true
