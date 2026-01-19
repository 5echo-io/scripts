#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
#  5echo - Install Uptime Kuma (v2) + MariaDB (Docker Compose)
#  Default path: /uptimekuma
#  Default port: 3001
#
#  Usage:
#    sudo bash uptime-kuma.sh
#
#  Non-interactive:
#    sudo bash uptime-kuma.sh --port 3001 --path /uptimekuma --db-name uptimekuma --db-user kumauser --db-pass 'xxx' --root-pass 'yyy' --traefik n
# ------------------------------------------------------------

APP_DIR="/uptimekuma"
PORT="3001"
DB_NAME="uptimekuma"
DB_USER="kumauser"
DB_PASS=""
ROOT_PASS=""
USE_TRAEFIK="n"

print() { printf "%b\n" "$*"; }
die() { print "\n[ERROR] $*\n"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Mangler kommando: $1"
}

random_pw() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local var=""
  read -r -p "$prompt [$default]: " var
  if [[ -z "$var" ]]; then var="$default"; fi
  printf "%s" "$var"
}

usage() {
  cat <<EOF
Uptime Kuma + MariaDB installer

Flags:
  --path        Install path (default: /uptimekuma)
  --port        Host port for Uptime Kuma (default: 3001)
  --db-name     MariaDB database name (default: uptimekuma)
  --db-user     MariaDB user (default: kumauser)
  --db-pass     MariaDB password (default: auto-generate if empty)
  --root-pass   MariaDB root password (default: auto-generate if empty)
  --traefik     Connect to external Docker network 'kuma_net' (y/n) (default: n)
  --yes         Non-interactive mode (uses provided flags + defaults)
  -h, --help    Show help

Examples:
  sudo bash uptime-kuma.sh
  sudo bash uptime-kuma.sh --path /uptimekuma --port 3001 --traefik y --yes
EOF
}

YES="n"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) APP_DIR="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --db-name) DB_NAME="${2:-}"; shift 2 ;;
    --db-user) DB_USER="${2:-}"; shift 2 ;;
    --db-pass) DB_PASS="${2:-}"; shift 2 ;;
    --root-pass) ROOT_PASS="${2:-}"; shift 2 ;;
    --traefik) USE_TRAEFIK="${2:-}"; shift 2 ;;
    --yes) YES="y"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Ukjent flagg: $1 (bruk --help)" ;;
  esac
done

COMPOSE_FILE="${APP_DIR%/}/docker-compose.yml"

print "\n=== Uptime Kuma + MariaDB (Docker Compose) installer ===\n"

require_cmd sudo
require_cmd docker

if ! sudo docker compose version >/dev/null 2>&1; then
  die "docker compose (plugin) mangler eller fungerer ikke. Installer docker-compose-plugin."
fi

if [[ "$YES" != "y" ]]; then
  PORT="$(prompt_default "Hvilken port vil du bruke for Uptime Kuma (host)" "$PORT")"
  APP_DIR="$(prompt_default "Hvor skal stacken ligge (path)" "$APP_DIR")"
  DB_NAME="$(prompt_default "Database navn" "$DB_NAME")"
  DB_USER="$(prompt_default "Database bruker" "$DB_USER")"

  local_db_default="$(random_pw)"
  local_root_default="$(random_pw)"

  DB_PASS="$(prompt_default "Database passord (blank = auto)" "${DB_PASS:-$local_db_default}")"
  ROOT_PASS="$(prompt_default "MariaDB root passord (blank = auto)" "${ROOT_PASS:-$local_root_default}")"
  USE_TRAEFIK="$(prompt_default "Skal den kobles pa ekstern Traefik-nett (kuma_net)? (y/n)" "$USE_TRAEFIK")"
else
  # Non-interactive defaults
  if [[ -z "$DB_PASS" ]]; then DB_PASS="$(random_pw)"; fi
  if [[ -z "$ROOT_PASS" ]]; then ROOT_PASS="$(random_pw)"; fi
fi

APP_DIR="${APP_DIR%/}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

# Basic validation
[[ "$PORT" =~ ^[0-9]+$ ]] || die "Port ma vaere et tall. Fikk: $PORT"
if (( PORT < 1 || PORT > 65535 )); then die "Port ma vaere 1-65535. Fikk: $PORT"; fi

print "\n[INFO] Oppsett:"
print "  - Mappe: ${APP_DIR}"
print "  - Port : ${PORT} -> 3001"
print "  - DB   : ${DB_NAME}"
print "  - User : ${DB_USER}"
print "  - Traefik kuma_net: ${USE_TRAEFIK}\n"

print "[STEP] Oppretter mappe: ${APP_DIR}"
sudo mkdir -p "${APP_DIR}"
sudo chown "$USER":"$USER" "${APP_DIR}"

if [[ -f "${COMPOSE_FILE}" && "$YES" != "y" ]]; then
  print "\n[WARN] Fant eksisterende docker-compose.yml i ${APP_DIR}."
  OVERWRITE="$(prompt_default "Vil du overskrive den? (y/n)" "n")"
  if [[ "${OVERWRITE}" != "y" && "${OVERWRITE}" != "Y" ]]; then
    print "[INFO] Avbryter uten a endre compose."
    exit 0
  fi
fi

print "[STEP] Skriver ${COMPOSE_FILE}"

if [[ "${USE_TRAEFIK}" == "y" || "${USE_TRAEFIK}" == "Y" ]]; then
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

print "[STEP] Starter stacken"
cd "${APP_DIR}"

# Check port availability (best effort)
if sudo ss -ltn 2>/dev/null | grep -qE "(:${PORT}\s)"; then
  print "\n[WARN] Port ${PORT} ser ut til a vaere i bruk. Hvis oppstart feiler, velg en annen port."
fi

sudo docker compose pull
sudo docker compose up -d

print "\n[INFO] Container-status:"
sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | sed -n '1p;/uptime-kuma/p;/uptimekuma-mariadb/p'

print "\n[SUCCESS] Uptime Kuma er oppe."
print "Aapne: http://SERVER-IP:${PORT}\n"
print "Tips:"
print "  - Logs Kuma   : sudo docker logs -f uptime-kuma"
print "  - Logs MariaDB: sudo docker logs -f uptimekuma-mariadb"
print "  - Stop/start  : cd ${APP_DIR} && sudo docker compose down && sudo docker compose up -d\n"
