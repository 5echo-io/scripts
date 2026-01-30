#!/usr/bin/env bash
set -euo pipefail

# 5echo.io – interheart installer wizard
# Intended usage:
#   sudo apt install -y curl && curl -fsSL https://scripts.5echo.io/ubuntu/install/interheart.sh | sudo bash

clear || true

bold(){ echo -e "\033[1m$*\033[0m"; }
muted(){ echo -e "\033[2m$*\033[0m"; }
err(){ echo -e "\033[31m$*\033[0m"; }

detect_installed(){
  if systemctl list-unit-files 2>/dev/null | grep -q '^interheart-webui\.service'; then
    return 0
  fi
  if [[ -d /opt/interheart ]]; then
    return 0
  fi
  return 1
}

stop_services(){
  systemctl stop interheart.timer interheart.service interheart-webui.service 2>/dev/null || true
  systemctl disable interheart.timer interheart.service interheart-webui.service 2>/dev/null || true
}

uninstall_all(){
  stop_services
  rm -rf /etc/systemd/system/interheart-webui.service.d 2>/dev/null || true
  rm -rf /opt/interheart 2>/dev/null || true
  systemctl daemon-reload || true
}

install_or_update(){
  bold "Installing/updating interheart…"
  apt-get update -y >/dev/null
  apt-get install -y git curl >/dev/null

  stop_services
  rm -rf /etc/systemd/system/interheart-webui.service.d 2>/dev/null || true

  rm -rf /opt/interheart
  git clone https://github.com/5echo-io/interheart.git /opt/interheart

  bash /opt/interheart/install.sh

  systemctl daemon-reload
  systemctl enable --now interheart.timer interheart-webui.service

  bold "Done."
  muted "Status:"
  systemctl status interheart-webui.service interheart.timer --no-pager -l || true
  muted "Listening ports:"
  ss -lntp | grep -E ':8088' || true
}

bold "interheart installer (5echo.io)"
muted "This wizard will install, update, or remove interheart on this machine."
echo

if detect_installed; then
  bold "Existing installation detected."
  echo "  1) Update / reinstall"
  echo "  2) Uninstall"
  echo "  3) Cancel"
  echo
  read -r -p "Choose [1-3]: " choice
  case "${choice:-}" in
    1) install_or_update ;;
    2) uninstall_all; bold "Uninstalled." ;;
    3) muted "Cancelled."; exit 0 ;;
    *) err "Invalid choice."; exit 1 ;;
  esac
else
  echo "  1) Install"
  echo "  2) Cancel"
  echo
  read -r -p "Choose [1-2]: " choice
  case "${choice:-}" in
    1) install_or_update ;;
    2) muted "Cancelled."; exit 0 ;;
    *) err "Invalid choice."; exit 1 ;;
  esac
fi
