#!/bin/bash
set -e

# ========================================================
#  5echo.io Docker Installer - Ubuntu/Debian
#  Version: 1.6.0
#  Source: https://5echo.io
# ========================================================

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RED="\e[31m"
NC="\e[0m" # Reset

banner() {
  echo -e "${BLUE}==============================================${NC}"
  echo -e "${BLUE}            5echo.io - Docker Installer${NC}"
  echo -e "${BLUE}==============================================${NC}\n"
}

footer() {
  echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
  echo -e "${BLUE}2025 © 5echo.io${NC}\n"
}
trap footer EXIT

# --- Compact per-step progress bar (ASCII, inline, only while running) ---
run_step() {
  local title="$1"; shift
  local logf; logf="$(mktemp /tmp/5echo-step.XXXXXX.log)"

  # Start command in background; redirect all output to log
  ( "$@" >"$logf" 2>&1 ) &
  local pid=$!

  # Simple “marquee” bar
  local width=28 i=0 dir=1
  while kill -0 "$pid" 2>/dev/null; do
    local bar=""
    for ((c=0; c<width; c++)); do
      if [ $c -eq $i ]; then bar+="#"; else bar+="-"; fi
    done
    # Print inline bar; clear line first to avoid remnants
    printf "\r\033[K${BLUE}%s${NC}  [%s]" "$title" "$bar"
    i=$((i+dir))
    if [ $i -ge $((width-1)) ] || [ $i -le 0 ]; then dir=$(( -dir )); fi
    sleep 0.08
  done

  # Wait for command to end and capture exit
  wait "$pid"; local rc=$?

  if [ $rc -eq 0 ]; then
    # Clear the line and print clean “Done!”
    printf "\r\033[K${GREEN}%s... Done!${NC}\n" "$title"
    rm -f "$logf"
  else
    printf "\r\033[K${RED}%s... Failed!${NC}\n" "$title"
    echo -e "${YELLOW}Last 50 log lines:${NC}"
    tail -n 50 "$logf" || true
    rm -f "$logf"
    exit 1
  fi
}

# === Start ===
clear
banner

# 1) Ensure curl is installed
run_step "Checking curl (and installing if missing)" bash -c '
  if ! command -v curl >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    sudo apt-get -qq update
    sudo apt-get -y -qq install curl
  fi
'

# 2) Prepare helper to check Docker status cleanly (no quoting pitfalls)
STATUS_FILE="/tmp/docker_status_5echo"
CHECK_SCRIPT="$(mktemp /tmp/5echo-check-docker.XXXXXX.sh)"

cat <<'EOS' > "$CHECK_SCRIPT"
#!/bin/bash
set -e

STATUS_FILE="/tmp/docker_status_5echo"
: > "$STATUS_FILE"

# If docker is not installed, mark absent
if ! command -v docker >/dev/null 2>&1; then
  echo "absent" > "$STATUS_FILE"
  exit 0
fi

# Ensure Docker repo exists so candidate version is accurate
sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release
DIST="${ID}"
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL "https://download.docker.com/linux/${DIST}/gpg" -o /tmp/docker.asc 2>/dev/null || true
  if [ -s /tmp/docker.asc ]; then
    sudo mv /tmp/docker.asc /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
  fi
fi

if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DIST} ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
fi

sudo apt-get -qq update || true

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
  CANDIDATE=$(apt-cache policy docker-ce | awk "/Candidate:/ {print \$2}")
  if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "(none)" ] && [ "$INSTALLED" = "$CANDIDATE" ]; then
    echo "up_to_date" > "$STATUS_FILE"
  else
    echo "needs_update" > "$STATUS_FILE"
  fi
  exit 0
fi

# docker.io installed -> treat as needs_update/migrate to docker-ce
echo "needs_update" > "$STATUS_FILE"
EOS
chmod +x "$CHECK_SCRIPT"

run_step "Checking Docker status" bash "$CHECK_SCRIPT"
DOCKER_STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo absent)"

if [ "$DOCKER_STATUS" = "up_to_date" ]; then
  echo -e "${GREEN}Docker is already at the latest version. Exiting.${NC}"
  rm -f "$CHECK_SCRIPT" "$STATUS_FILE" 2>/dev/null || true
  exit 0
fi

# 3) Remove old/conflicting packages quietly
run_step "Removing old Docker packages" bash -c '
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get -y -qq remove "$pkg" >/dev/null 2>&1 || true
  done
'

# 4) Add/refresh Docker repository (ID + CODENAME aware)
run_step "Adding Docker repository" bash -c '
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  sudo apt-get -qq update
  sudo apt-get -y -qq install ca-certificates curl gnupg lsb-release >/dev/null
  sudo install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  DIST="${ID}"
  CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  sudo curl -fsSL "https://download.docker.com/linux/${DIST}/gpg" -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DIST} ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get -qq update
'

# 5) Install/Upgrade Docker (silent; logs if error)
APT_COMMON_OPTS=(-y -qq
  -o Dpkg::Options::="--force-confdef"
  -o Dpkg::Options::="--force-confold"
)
if [ "$DOCKER_STATUS" = "needs_update" ]; then
  run_step "Upgrading Docker to latest" bash -c '
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    sudo apt-get "${APT_COMMON_OPTS[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ' _
else
  run_step "Installing Docker packages" bash -c '
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    sudo apt-get "${APT_COMMON_OPTS[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ' _
fi

# 6) Enable service
run_step "Enabling Docker service" sudo systemctl enable docker

# 7) Start service
run_step "Starting Docker service" sudo systemctl start docker

# 8) Test docker binary
run_step "Testing Docker installation" docker --version

# 9) Hello-world test (silent)
run_step "Running Docker hello-world test" sudo docker run --rm hello-world

# Cleanup
rm -f "$CHECK_SCRIPT" "$STATUS_FILE" 2>/dev/null || true
