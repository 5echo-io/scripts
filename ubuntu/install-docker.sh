#!/bin/bash
set -e

# ========================================================
#  5echo.io Docker Installer - Ubuntu/Debian
#  Version: 1.0.0
#  Source: https://5echo.io
# ========================================================

# Colors for better output
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

# Spinner function
spinner() {
    local pid=$!
    local delay=0.1
    local spin='|/-\'
    while [ -d /proc/$pid ]; do
        for i in $(seq 0 3); do
            echo -ne "\r${BLUE}Starting${NC} ${spin:$i:1}   Press CTRL+C to cancel."
            sleep $delay
        done
    done
    echo -ne "\r${GREEN}Starting... Done!${NC}          \n"
}

# Loading function with animated dots
loading() {
    local message="$1"
    echo -ne "${BLUE}${message}${NC}"
    for i in {1..3}; do
        echo -ne "."
        sleep 0.4
    done
    echo ""
}

# === Start ===
clear
banner
(sleep 2) & spinner

# Remove old Docker packages
loading "Removing old Docker packages"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get remove -y $pkg >/dev/null 2>&1 || true
done

# Add Docker repository
loading "Adding Docker repository"
sudo apt-get update -qq
sudo apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Configure the repository for the correct Ubuntu version
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update -qq

# Install Docker packages
loading "Installing Docker packages"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

# Enable and start Docker service
loading "Enabling Docker service"
sudo systemctl enable docker >/dev/null
sudo systemctl start docker >/dev/null

# Test Docker installation
loading "Testing Docker installation"
if docker --version >/dev/null 2>&1; then
    echo -e "${GREEN}Docker installed successfully!${NC}"
    docker --version
else
    echo -e "${RED}Docker installation failed.${NC}"
    exit 1
fi

# Run hello-world container to verify installation
loading "Running Docker hello-world test"
if sudo docker run hello-world >/dev/null 2>&1; then
    echo -e "${GREEN}Docker test container ran successfully!${NC}"
else
    echo -e "${YELLOW}Docker installed, but hello-world test failed.${NC}"
fi

# Footer branding
echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
echo -e "${BLUE}2025 © 5echo.io${NC}\n"
