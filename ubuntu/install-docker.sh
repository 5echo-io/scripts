#!/bin/bash
set -e

# ========================================================
#  5echo.io Docker Installer - Ubuntu/Debian
#  Version: 1.1.0
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

    # Run command in background
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

# Remove old Docker packages
loading "Removing old Docker packages" bash -c "
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        sudo apt-get remove -y \$pkg >/dev/null 2>&1 || true
    done
"

# Add Docker repository
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

# Install Docker
loading "Installing Docker packages" sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable and start Docker
loading "Enabling Docker service" sudo systemctl enable docker
loading "Starting Docker service" sudo systemctl start docker

# Test Docker installation
loading "Testing Docker installation" docker --version

# Run hello-world container
loading "Running Docker hello-world test" sudo docker run hello-world

# Footer branding
echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
echo -e "${BLUE}2025 © 5echo.io${NC}\n"
