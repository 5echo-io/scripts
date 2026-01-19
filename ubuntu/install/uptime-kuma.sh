#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------
#  Uptime Kuma + MariaDB installer (Docker Compose)
#  Path: /uptimekuma
#  Default: binds to :3001
# ---------------------------------------------

APP_DIR="/uptimekuma"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

print() { printf "%b\n" "$*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print "\n[ERROR] Mangler kommando: $1"
    exit 1
  fi
}

random_pw() {
  # 24 chars base64-ish
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "$prompt [$default]: " var
  if [[ -z "${var}" ]]; then
    var="$default"
  fi
  printf "%s" "$var"
}

print "\n=== Uptime Kuma + MariaDB (Docker Compose) installer ===\n"

require_cmd sudo
require_cmd docker

if ! sudo docker compose version >/dev/null 2>&1; then
  print "[ERROR] docker compose (plugin) mangler eller fungerer ikke."
  print "Tips: Installer Docker Compose plugin, eller oppgrader Docker."
  exit 1
fi

# ---- Inputs
PORT="$(prompt_default "Hvilken port vil du bruke for Uptime Kuma (host)" "3001")"
DB_NAME="$(prompt_default "Database navn" "uptimekuma")"
DB_USER="$(prompt_default "Database bruker" "kumauser")"

DEFAULT_DB_PASS="$(random_pw)"
DEFAULT_ROOT_PASS="$(random_pw)"

DB_PASS="$(prompt_default "Database passord (blank = auto)" "$DEFAULT_DB_PASS")"
ROOT_PASS="$(prompt_default "MariaDB root passord (blank = auto)" "$DEFAULT_ROOT_PASS")"

# Optional: Traefik external network
USE_TRAEFIK="$(prompt_default "Skal den kobles på ekstern Traefik-nett (kuma_net)? (y/n)" "n")"

print "\n[INFO] Oppsett:"
print "  - Mappe: ${APP_DIR}"
print "  - Port : ${PORT} -> 3001"
print "  - DB   : ${DB_NAME}"
print "  - User : ${DB_USER}\n"

# ---- Create dir
print "[STEP] Oppretter mappe: ${APP_DIR}"
sudo mkdir -p "${APP_DIR}"
sudo chown "$USER":"$USER" "${APP_DIR}"

# ---- If exists: show warning
if [[ -f "${COMPOSE_FILE}" ]]; then
  print "\n[WARN] Fant eksisterende docker-compose.yml i ${APP_DIR}."
  OVERWRITE="$(prompt_default "Vil du overskrive den? (y/n)" "n")"
  if [[ "${OVERWRITE}" != "y" && "${OVERWRITE}" != "Y" ]]; then
    print "[INFO] Avbryter uten å endre compose."
    exit 0
  fi
fi

# ---- Write compose
print "[STEP] Skriver ${COMPOSE_FILE}"

if [[ "${USE_TRAEFIK}" == "y" || "${USE_TRAEFIK}" == "Y" ]]; then
  # With external network kuma_net (Traefik style)
  cat > "${COMPOSE_FILE}" <<EOF
services:
  mariadb:
    image: mariadb:11
    container_name: uptimekuma-mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${ROOT_PASS}"
      MYSQL_DATABASE: "${DB_NAME}"
      MYSQL_USER: "${DB_USER}"
      MYSQL_PASSWORD: "${DB_PASS}"
    volumes:
      - ./mariadb-data:/var/lib/mysql
    networks:
      - kuma_net

  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    depends_on:
      - mariadb
    ports:
      - "${PORT}:3001"
    volumes:
      - ./uptimekuma-data:/app/data
    environment:
      UPTIME_KUMA_DB_TYPE: "mariadb"
      UPTIME_KUMA_DB_HOSTNAME: "mariadb"
      UPTIME_KUMA_DB_PORT: "3306"
      UPTIME_KUMA_DB_NAME: "${DB_NAME}"
      UPTIME_KUMA_DB_USERNAME: "${DB_USER}"
      UPTIME_KUMA_DB_PASSWORD: "${DB_PASS}"
      UPTIME_KUMA_IN_CONTAINER: "true"
    networks:
      - kuma_net

networks:
  kuma_net:
    external: true
    name: kuma_net
EOF
else
  # Standard compose network
  cat > "${COMPOSE_FILE}" <<EOF
services:
  mariadb:
    image: mariadb:11
    container_name: uptimekuma-mariadb
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${ROOT_PASS}"
      MYSQL_DATABASE: "${DB_NAME}"
      MYSQL_USER: "${DB_USER}"
      MYSQL_PASSWORD: "${DB_PASS}"
    volumes:
      - ./mariadb-data:/var/lib/mysql

  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: uptime-kuma
    restart: unless-stopped
    depends_on:
      - mariadb
    ports:
      - "${PORT}:3001"
    volumes:
      - ./uptimekuma-data:/app/data
    environment:
      UPTIME_KUMA_DB_TYPE: "mariadb"
      UPTIME_KUMA_DB_HOSTNAME: "mariadb"
      UPTIME_KUMA_DB_PORT: "3306"
      UPTIME_KUMA_DB_NAME: "${DB_NAME}"
      UPTIME_KUMA_DB_USERNAME: "${DB_USER}"
      UPTIME_KUMA_DB_PASSWORD: "${DB_PASS}"
      UPTIME_KUMA_IN_CONTAINER: "true"
EOF
fi

# ---- Start
print "[STEP] Starter stacken"
cd "${APP_DIR}"

# Pull latest images (v2 tag is stable)
sudo docker compose pull

# Start
sudo docker compose up -d

# ---- Show status
print "\n[INFO] Container-status:"
sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | sed -n '1p;/uptime-kuma/p;/uptimekuma-mariadb/p'

print "\n[SUCCESS] Uptime Kuma er oppe."
print "Åpne: http://SERVER-IP:${PORT}\n"

print "Tips:"
print "  - Logs Kuma   : sudo docker logs -f uptime-kuma"
print "  - Logs MariaDB: sudo docker logs -f uptimekuma-mariadb"
print "  - Stop/start  : cd ${APP_DIR} && sudo docker compose down && sudo docker compose up -d\n"
