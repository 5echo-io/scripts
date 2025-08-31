#!/bin/bash
set -e

# ========================================================
#  5echo.io Docker Installer - Ubuntu/Debian
#  Version: 1.9.5
#  Source: https://5echo.io
# ========================================================

# ---- Config (env-overridable) --------------------------
REINSTALL="${REINSTALL:-0}"     # 1=force reinstall without prompt
PURGE_DATA="${PURGE_DATA:-0}"   # 1=purge /var/lib/docker and /etc/docker during reinstall
SKIP_HELLO="${SKIP_HELLO:-0}"   # 1=skip hello-world test
# --------------------------------------------------------

# Colors
GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RED="\e[31m"; NC="\e[0m"

# --- Banner (informative header, aligned) ---------------
SCRIPT_VERSION="1.9.5"

banner() {
  # Gather context quietly
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

  # Base steps: 6 core + optional hello-world
  local EST_TOTAL=6
  if [ "${SKIP_HELLO}" -ne 1 ]; then EST_TOTAL=$((EST_TOTAL + 1)); fi

  echo -e "${BLUE}==============================================${NC}"
  echo -e "${BLUE}            5echo.io - Docker Installer${NC}"
  echo -e "${BLUE}==============================================${NC}"
  printf " %-7s v%s   Steps (est.): %d total\n" "Script:" "$SCRIPT_VERSION" "$EST_TOTAL"
  printf " %-7s %-22s %-7s %s\n" "Host:" "$HOSTNAME_SHORT" "User:" "$USER_NAME"
  if [ -n "${OS_PRETTY}" ]; then
    printf " %-7s %s (%s)\n" "OS:" "$OS_PRETTY" "${OS_CODE:-n/a}"
  fi
  printf " %-7s %-22s %-7s %s\n" "Kernel:" "$KERNEL" "Arch:" "$ARCH"
  if [ -n "${NOW}" ]; then
    printf " %-7s %s\n" "Time:" "$NOW"
  fi
  printf " %-7s REINSTALL=%s  PURGE_DATA=%s  SKIP_HELLO=%s\n" "Flags:" "$REINSTALL" "$PURGE_DATA" "$SKIP_HELLO"
  printf " %-7s %s\n\n" "Note:" "Reinstall/purge may add extra steps."
}

# Summary state
ACTION="unknown"
SUMMARY_INSTALLED_BEFORE=""
SUMMARY_CANDIDATE=""
SUMMARY_VERSION_AFTER=""

footer() {
  echo -e "\n${YELLOW}Summary:${NC}"
  echo -e "  Action: ${BLUE}${ACTION}${NC}"
  [ -n "$SUMMARY_INSTALLED_BEFORE" ] && echo -e "  Before: ${SUMMARY_INSTALLED_BEFORE}"
  [ -n "$SUMMARY_CANDIDATE" ]       && echo -e "  Candidate: ${SUMMARY_CANDIDATE}"
  if command -v docker >/dev/null 2>&1; then
    SUMMARY_VERSION_AFTER="$(docker --version 2>/dev/null | sed 's/^/  After: /')"
    [ -n "$SUMMARY_VERSION_AFTER" ] && echo -e "${SUMMARY_VERSION_AFTER}"
  fi
  echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
  echo -e "${BLUE}2025 © 5echo.io${NC}\n"
}
trap footer EXIT

# --- Step numbering & clean spinner (no duration) --------
STEP_INDEX=0

run_step() {
  local title="$1"; shift
  STEP_INDEX=$((STEP_INDEX + 1))
  local logf; logf="$(mktemp /tmp/5echo-step.XXXXXX.log)"

  ( "$@" >"$logf" 2>&1 ) &
  local pid=$!

  local spin='|/-\'; local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r\033[K${BLUE}[%d] %s${NC}  %s" "$STEP_INDEX" "$title" "${spin:$i:1}"
    i=$(( (i + 1) % 4 ))
    sleep 0.15
  done

  wait "$pid"; local rc=$?
  printf "\r\033[K"  # clear spinner line

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
  # usage: ask_yes_no "Question" [Y|N]  (default is second arg, default=N if omitted)
  local q="$1"; local def="${2:-N}"; local prompt="[y/N]"
  [ "$def" = "Y" ] && prompt="[Y/n]"
  local ans=""

  # Prefer reading from the controlling terminal to ensure prompt is shown
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s %s " "$q" "$prompt" > /dev/tty
    IFS= read -r ans < /dev/tty || true
  elif [ -t 0 ]; then
    # fallback to stdin if it's a TTY
    read -r -p "$q $prompt " ans || true
  else
    # non-interactive: keep ans empty to use default below
    :
  fi

  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO)   return 1 ;;
    *)           [ "$def" = "Y" ] && return 0 || return 1 ;;
  esac
}

# === Start ===
clear
banner

# 1) Ensure curl
run_step "Checking curl (and installing if missing)" bash -lc '
  if ! command -v curl >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    sudo -E apt-get -qq update
    sudo -E apt-get -y -qq install curl
  fi
'

# 2) Check Docker status & candidate (quiet)
DOCKER_ENV_FILE="/tmp/docker_check_5echo.env"
CHECK_SCRIPT="$(mktemp /tmp/5echo-check-docker.XXXXXX.sh)"

cat <<'EOS' > "$CHECK_SCRIPT"
#!/bin/bash
set -e

OUT="/tmp/docker_check_5echo.env"
{
  echo "status=absent"
  echo "installed="
  echo "candidate="
} > "$OUT"

if ! command -v docker >/dev/null 2>&1; then
  exit 0
fi

sudo install -m 0755 -d /etc/apt/keyrings
. /etc/os-release
DIST="${ID}"
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

[ -f /etc/apt/keyrings/docker.asc ] || {
  curl -fsSL "https://download.docker.com/linux/${DIST}/gpg" -o /tmp/docker.asc 2>/dev/null || true
  if [ -s /tmp/docker.asc ]; then
    sudo mv /tmp/docker.asc /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
  fi
}

[ -f /etc/apt/sources.list.d/docker.list ] || {
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DIST} ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
}

sudo apt-get -qq update || true

INST=""
CAND=""
if dpkg -s docker-ce >/dev/null 2>&1; then
  INST="$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)"
  CAND="$(apt-cache policy docker-ce | awk "/Candidate:/ {print \$2}")"
  if [ -n "$CAND" ] && [ "$CAND" != "(none)" ] && [ "$INST" = "$CAND" ]; then
    echo "status=up_to_date" > "$OUT"
  else
    echo "status=needs_update" > "$OUT"
  fi
  echo "installed=$INST" >> "$OUT"
  echo "candidate=$CAND"  >> "$OUT"
  exit 0
fi

if dpkg -s docker.io >/dev/null 2>&1; then
  INST="$(dpkg-query -W -f='${Version}' docker.io 2>/dev/null || true)"
  CAND="$(apt-cache policy docker-ce | awk "/Candidate:/ {print \$2}")"
  echo "status=needs_update" > "$OUT"
  echo "installed=$INST" >> "$OUT"
  echo "candidate=$CAND"  >> "$OUT"
  exit 0
fi

VER="$(docker --version 2>/dev/null | awk "{print \$3}" | tr -d , || true)"
echo "status=needs_update" > "$OUT"
echo "installed=$VER" >> "$OUT"
echo "candidate="     >> "$OUT"
EOS
chmod +x "$CHECK_SCRIPT"

run_step "Checking Docker status" bash "$CHECK_SCRIPT"
# shellcheck disable=SC1090
. "$DOCKER_ENV_FILE" || true
SUMMARY_INSTALLED_BEFORE="${installed:-}"
SUMMARY_CANDIDATE="${candidate:-}"

# 2b) If Docker exists: offer reinstall (optional data purge)
if [ "${status:-absent}" != "absent" ]; then
  if [ "$REINSTALL" -eq 1 ]; then
    REINSTALL_DECISION=1
  else
    echo -e "${YELLOW}Docker detected.${NC} Installed: ${installed:-unknown}  Candidate: ${candidate:-unknown}"
    if ask_yes_no "Reinstall Docker from scratch?" "N"; then
      REINSTALL_DECISION=1
    else
      REINSTALL_DECISION=0
    fi
  fi

  if [ "$REINSTALL_DECISION" -eq 1 ]; then
    ACTION="reinstall"
    if [ "$PURGE_DATA" -eq 1 ]; then
      PURGE_DECISION=1
    else
      if ask_yes_no "Also purge Docker data (/var/lib/docker and /etc/docker)? This removes images/containers." "N"; then
        PURGE_DECISION=1
      else
        PURGE_DECISION=0
      fi
    fi
  else
    if [ "${status}" = "up_to_date" ]; then
      ACTION="noop"
      echo -e "${GREEN}Docker is already at the latest version. Exiting.${NC}"
      rm -f "$CHECK_SCRIPT" "$DOCKER_ENV_FILE" 2>/dev/null || true
      exit 0
    fi
  fi
fi

# 3) Reinstall branch: stop services, remove pkgs, optional data purge
if [ "${ACTION}" = "reinstall" ]; then
  run_step "Stopping Docker services" bash -lc '
    sudo systemctl stop docker || true
    sudo systemctl stop containerd || true
  '
  run_step "Removing Docker packages" bash -lc '
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    for pkg in docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin \
               docker-buildx-plugin docker.io docker-doc docker-compose docker-compose-v2 \
               podman-docker containerd runc; do
      sudo -E apt-get -y -qq remove "$pkg" >/dev/null 2>&1 || true
      sudo -E apt-get -y -qq purge  "$pkg" >/dev/null 2>&1 || true
    done
  '
  if [ "${PURGE_DECISION:-0}" -eq 1 ]; then
    run_step "Purging Docker data (/var/lib/docker, /etc/docker)" bash -lc '
      sudo rm -rf /var/lib/docker /etc/docker
    '
  fi
fi

# Decide ACTION if still unknown
if [ "$ACTION" = "unknown" ]; then
  case "${status:-absent}" in
    absent)       ACTION="install" ;;
    needs_update) ACTION="upgrade" ;;
    up_to_date)   ACTION="noop" ;;  # handled above
    *)            ACTION="install" ;;
  esac
fi

# 4) Add/refresh Docker repository
run_step "Adding Docker repository" bash -lc '
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  sudo -E apt-get -qq update
  sudo -E apt-get -y -qq install ca-certificates curl gnupg lsb-release >/dev/null
  sudo install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  DIST="${ID}"; CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  curl -fsSL "https://download.docker.com/linux/${DIST}/gpg" | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DIST} ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo -E apt-get -qq update
'

# 5) Install/Upgrade Docker
if [ "$ACTION" = "upgrade" ]; then
  run_step "Upgrading Docker to latest" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    sudo -E apt-get -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  run_step "Installing Docker packages" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    sudo -E apt-get -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# 6) Enable Docker service
run_step "Enabling Docker service" sudo systemctl enable docker

# 7) Test Docker installation (start service + check version)
run_step "Testing Docker installation" bash -lc '
  sudo systemctl start docker
  docker --version
'

# 8) Hello-world test (optional)
if [ "$SKIP_HELLO" -ne 1 ]; then
  run_step "Running Docker hello-world test" sudo docker run --rm hello-world
fi

# Cleanup
rm -f "$CHECK_SCRIPT" "$DOCKER_ENV_FILE" 2>/dev/null || true
