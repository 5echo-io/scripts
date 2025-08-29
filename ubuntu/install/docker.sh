#!/bin/bash
set -e

# ========================================================
#  5echo.io Docker Installer - Ubuntu/Debian
#  Version: 1.2.0
#  Source: https://5echo.io
# ========================================================

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RED="\e[31m"
NC="\e[0m" # Reset

# Minimalistic banner
banner() {
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BLUE}            5echo.io - Docker Installer${NC}"
    echo -e "${BLUE}==============================================${NC}\n"
}

# Spinner while process runs
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

# === Start ===
clear
banner

# Ensure curl is installed (needed later for repo key fetch)
loading "Checking curl (and installing if missing)" bash -c "
    if ! command -v curl >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y curl
    fi
"

# Check Docker status and decide path (absent | up_to_date | needs_update)
loading "Checking Docker status" bash -c '
    STATUS_FILE="/tmp/docker_status_5echo"
    : > "$STATUS_FILE"

    if ! command -v docker >/dev/null 2>&1; then
        echo "absent" > "$STATUS_FILE"
        exit 0
    fi

    # Ensure Docker repo exists so candidate version is accurate
    sudo install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        # Try to detect Ubuntu/Debian codename
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

    # Which package provides docker?
    if dpkg -s docker-ce >/dev/null 2>&1; then
        PKG=docker-ce
    elif dpkg -s docker.io >/dev/null 2>&1; then
        PKG=docker.io
    else
        # Unknown origin (snap/other), treat as needs_update/migrate
        echo "needs_update" > "$STATUS_FILE"
        exit 0
    fi

    # If docker-ce is installed, compare installed vs candidate
    if [ "$PKG" = "docker-ce" ]; then
        INSTALLED=$(dpkg-query -W -f='"'${Version}'"' docker-ce 2>/dev/null | tr -d '"')
        CANDIDATE=$(apt-cache policy docker-ce | awk "/Candidate:/ {print \$2}")
        if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "(none)" ] && [ "$INSTALLED" = "$CANDIDATE" ]; then
            echo "up_to_date" > "$STATUS_FILE"
        else
            echo "needs_update" > "$STATUS_FILE"
        fi
        exit 0
    fi

    # docker.io installed → consider migrating to docker-ce (newer)
    if [ "$PKG" = "docker.io" ]; then
        echo "needs_update" > "$STATUS_FILE"
        exit 0
    fi
'

DOCKER_STATUS="$(cat /tmp/docker_status_5echo 2>/dev/null || echo absent)"

if [ "$DOCKER_STATUS" = "up_to_date" ]; then
    echo -e "${GREEN}Docker is already at the latest version. Exiting.${NC}"
    exit 0
fi

# Remove old Docker packages (only if we install/upgrade)
loading "Removing old Docker packages" bash -c "
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        sudo apt-get remove -y \$pkg >/dev/null 2>&1 || true
    done
"

# Add/refresh Docker repository
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

if [ "$DOCKER_STATUS" = "needs_update" ]; then
    loading "Upgrading Docker to latest" sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    # DOCKER_STATUS=absent → fresh install
    loading "Installing Docker packages" sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Enable and start Docker
loading "Enabling Docker service" sudo systemctl enable docker
loading "Starting Docker service" sudo systemctl start docker

# Test Docker installation
loading "Testing Docker installation" docker --version

# Run hello-world container
loading "Running Docker hello-world test" sudo docker run --rm hello-world

# Footer branding
echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
echo -e "${BLUE}2025 © 5echo.io${NC}\n"
