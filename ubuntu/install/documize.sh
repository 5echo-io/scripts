#!/usr/bin/env bash
set -e

# ========================================================
#  5echo.io Documize Installer - Ubuntu/Debian (Interactive)
#  Version: 1.1.0
#  Source:  https://scripts.5echo.io/ubuntu/install/documize.sh
#  Path:    ubuntu/install/documize.sh
# ========================================================

# ---------- Colors ----------
GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RED="\e[31m"; NC="\e[0m"

# ---------- Minimalistic banner ----------
banner() {
  echo -e "${BLUE}==============================================${NC}"
  echo -e "${BLUE}          5echo.io - Documize Installer${NC}"
  echo -e "${BLUE}==============================================${NC}\n"
  echo -e "${BLUE}Script Path:${NC} ubuntu/install/documize.sh\n"
}

# ---------- Spinner wrapper ----------
loading() {
  local message="$1"; shift
  echo -ne "${BLUE}${message}${NC}"
  local spin='|/-\\'; local i=0
  ("$@" >/dev/null 2>&1) & local pid=$!
  while kill -0 $pid 2>/dev/null; do
    printf "\r${BLUE}${message}${NC} ${spin:$i:1}"
    i=$(( (i+1) % 4 )); sleep 0.2
  done
  wait $pid; local exit_code=$?
  if [ $exit_code -eq 0 ]; then
    printf "\r${GREEN}${message}... Done!${NC}\n"
  else
    printf "\r${RED}${message}... Failed!${NC}\n"; exit 1
  fi
}

# ---------- Helpers ----------
is_port_free() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ! ss -ltn "( sport = :$p )" | grep -q ":$p "
  else
    ! lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  fi
}

read_nonempty() {
  local prompt="$1" var
  while true; do
    read -r -p "$prompt" var
    if [ -n "$var" ]; then
      echo "$var"; return 0
    fi
    echo -e "${YELLOW}This field cannot be empty.${NC}"
  done
}

read_password_twice() {
  local p1 p2
  while true; do
    read -s -p "Enter database password: " p1; echo
    read -s -p "Confirm database password: " p2; echo
    if [ -z "$p1" ]; then
      echo -e "${YELLOW}Password cannot be empty.${NC}"; continue
    fi
    if [ "$p1" != "$p2" ]; then
      echo -e "${YELLOW}Passwords do not match. Try again.${NC}"; continue
    fi
    echo "$p1"; return 0
  done
}

read_hex_salt() {
  local salt
  while true; do
    read -r -p "Enter 64-char hex SALT (type 'g' to generate): " salt
    if [ "$salt" = "g" ] || [ "$salt" = "G" ]; then
      if command -v openssl >/dev/null 2>&1; then
        salt="$(openssl rand -hex 32)"
      else
        salt="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      fi
      echo "$salt"; return 0
    fi
    if [[ "$salt" =~ ^[0-9a-fA-F]{64}$ ]]; then
      echo "$salt"; return 0
    fi
    echo -e "${YELLOW}Invalid SALT. Must be exactly 64 hex characters (0-9a-f).${NC}"
  done
}

read_port() {
  local port
  while true; do
    read -r -p "Choose Documize listen port [8080]: " port
    port="${port:-8080}"
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
      echo -e "${YELLOW}Invalid port. Must be a number 1–65535.${NC}"; continue
    fi
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      echo -e "${YELLOW}Port out of valid range.${NC}"; continue
    fi
    if ! is_port_free "$port"; then
      echo -e "${YELLOW}Port $port is already in use. Pick another.${NC}"; continue
    fi
    echo "$port"; return 0
  done
}

confirm() {
  # y/N (default N)
  local prompt="$1" ans
  read -r -p "$prompt [y/N]: " ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------- Paths ----------
DOC_BASE="/opt/documize"
DOC_DATA="/var/lib/documize"
DOC_ENV="/etc/documize/env"
DOC_SVC="/etc/systemd/system/documize.service"

# ---------- Start ----------
clear; banner

# ---- Interactive input ----
DB_USER="$(read_nonempty 'Enter database user (e.g., docuser): ')"
DB_NAME="$(read_nonempty 'Enter database name (e.g., documize): ')"
DB_PASS="$(read_password_twice)"
DOC_SALT="$(read_hex_salt)"
DOC_PORT="$(read_port)"

if confirm "Open UFW for TCP port ${DOC_PORT}?"; then
  WANT_UFW="yes"
else
  WANT_UFW="no"
fi

echo
echo -e "${BLUE}Summary:${NC}
  DB user  : ${DB_USER}
  DB name  : ${DB_NAME}
  Port     : ${DOC_PORT}
  UFW open?: ${WANT_UFW}
  SALT     : (64-hex provided)"
if ! confirm "Proceed with these settings?"; then
  echo -e "${YELLOW}Aborting. Re-run the script to change values.${NC}"
  exit 1
fi
echo

# ---- Architecture check ----
ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" != "amd64" ]; then
  echo -e "${YELLOW}Warning:${NC} This script expects amd64. You have: ${ARCH}."
  echo -e "Continuing, but the download may fail on non-amd64.\n"
fi

# 1) Update & dependencies
loading "Updating apt and installing dependencies" bash -c "
  apt-get update -qq &&
  apt-get install -y curl wget jq ca-certificates postgresql postgresql-contrib openssl >/dev/null
"

# 2) Enable PostgreSQL
loading "Enabling PostgreSQL service" systemctl enable --now postgresql

# 3) Configure role & database (idempotent)
loading "Configuring PostgreSQL role and database" bash -c "
  sudo -u postgres psql >/dev/null <<'SQL'
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
  ELSE
    ALTER USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;

DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME}
  OWNER ${DB_USER}
  TEMPLATE template0
  ENCODING 'UTF8';

ALTER SCHEMA public OWNER TO ${DB_USER};
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE, USAGE ON SCHEMA public TO ${DB_USER};
SQL
"

# 4) System user & directories
loading "Creating system user and directories" bash -c "
  id -u documize >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d ${DOC_BASE} documize
  mkdir -p ${DOC_BASE} ${DOC_DATA} /etc/documize
  chown -R documize:documize ${DOC_BASE} ${DOC_DATA}
"

# 5) Download Documize Community (latest)
loading "Downloading Documize (latest release)" bash -c "
  DL_URL=\$(curl -s https://api.github.com/repos/documize/community/releases/latest \
    | jq -r '.assets[] | select(.name | test(\"linux-amd64$\")) | .browser_download_url')
  if [ -z \"\$DL_URL\" ]; then
    echo 'Could not find linux-amd64 binary in the latest release.' >&2; exit 1
  fi
  curl -fsSL \"\$DL_URL\" -o ${DOC_BASE}/documize
  chmod 0755 ${DOC_BASE}/documize
  chown documize:documize ${DOC_BASE}/documize
"

# 6) Optional UFW
if [ "$WANT_UFW" = "yes" ]; then
  loading "Installing and opening UFW for port ${DOC_PORT}" bash -c "
    apt-get install -y ufw >/dev/null &&
    ufw allow ${DOC_PORT}/tcp >/dev/null 2>&1 || true &&
    ufw --force reload >/dev/null 2>&1 || true
  "
else
  echo -e "${YELLOW}Skipping UFW opening as requested.${NC}"
fi

# 7) Environment file
loading "Writing environment file" bash -c "
  umask 027
  cat > ${DOC_ENV} <<EOF
DOCUMIZEDBTYPE=postgresql
DOCUMIZEDB=host=localhost port=5432 dbname=${DB_NAME} user=${DB_USER} password=${DB_PASS} sslmode=disable
DOCUMIZESALT=${DOC_SALT}
EOF
  chmod 0640 ${DOC_ENV}
  chown root:documize ${DOC_ENV}
"

# 8) systemd unit
loading "Creating systemd service" bash -c "
  cat > ${DOC_SVC} <<EOF
[Unit]
Description=Documize Community
After=network.target postgresql.service
Wants=postgresql.service

[Service]
User=documize
Group=documize
WorkingDirectory=${DOC_BASE}
EnvironmentFile=${DOC_ENV}
ExecStart=${DOC_BASE}/documize -port ${DOC_PORT}
Restart=always
RestartSec=5s
# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
"

# 9) Enable & start
loading "Enabling and starting Documize" systemctl enable --now documize

# 10) Health check
loading "Checking service status" bash -c "
  systemctl --no-pager --full status documize || true
  (command -v ss >/dev/null && ss -ltnp | grep -w :${DOC_PORT}) || true
"

echo -e "\n${GREEN}Documize is installed and running on port ${DOC_PORT}.${NC}"
echo -e "Open: ${YELLOW}http://<server-ip>:${DOC_PORT}/setup${NC} to complete initial configuration."
echo -e "\n${YELLOW}Powered by 5echo.io${NC}"
echo -e "${BLUE}2025 © 5echo.io${NC}"
echo -e "${BLUE}Script: ubuntu/install/documize.sh${NC}\n"
