#!/bin/bash
set -e

# Colors
NC='\033[0m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
GREEN='\033[0;32m'

# Spinner
spin() {
    local -a marks=('/' '-' '\' '|')
    while :; do
        for m in "${marks[@]}"; do
            printf "\r$1 %s" "$m"
            sleep 0.1
        done
    done
}

# Loading phase
phase() {
    local msg=$1
    echo -ne "\n${BLUE}${msg}${NC}"
    spin "$msg" &
    SPIN_PID=$!
    disown
}

# Done with phase
done_phase() {
    kill "$SPIN_PID" &>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    echo -e "\r${GREEN}✔${NC} ${GREEN}Done.${NC}"
}

# Copyright
footer() {
    echo -e "\n${YELLOW}2025 © 5echo.io${NC}\n"
}

# Start
echo -e "${BLUE}Starting Uptime Kuma installation. Press CTRL+C to cancel.${NC}"

# Check Docker
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker is not installed. Please run: 5echo install docker${NC}"
    exit 1
fi

# Phase 1
phase "Creating Docker volume..."
docker volume create uptime-kuma-data >/dev/null 2>&1
done_phase

# Phase 2
phase "Deploying container..."
docker run -d \
  --name uptime-kuma \
  --restart=always \
  -p 3001:3001 \
  -v uptime-kuma-data:/app/data \
  louislam/uptime-kuma:latest >/dev/null
done_phase

# Finish
echo -e "\n${GREEN}✅ Uptime Kuma is now running on port 3001${NC}"
echo -e "${YELLOW}➡️  Visit: http://<your-server-ip>:3001${NC}"
footer
