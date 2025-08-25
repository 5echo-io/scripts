#!/bin/bash

set -e

REPO_BASE="https://scripts.5echo.io"
CLI_PATH="/usr/local/bin/5echo"
CLI_URL="$REPO_BASE/5echo"

# Show CLI help
function show_help() {
  echo -e "\n🛠️  5echo CLI - Tools by 5echo.io"
  echo -e "\nUsage:"
  echo "  5echo install <package>    Install a supported package"
  echo "  5echo update               Update this CLI to latest version"
  echo "  5echo help                 Show this help text"
  echo ""
  echo "Supported packages:"
  echo "  docker         Install Docker CE"
  echo "  uptime-kuma    Install Uptime Kuma monitoring"
  echo ""
}

# Install packages
function install_package() {
  case "$1" in
    docker)
      echo "🔧 Installing Docker..."
      curl -sL "$REPO_BASE/install-docker.sh" | bash
      ;;
    uptime-kuma)
      echo "🔧 Installing Uptime Kuma..."
      curl -sL "$REPO_BASE/install-uptime-kuma.sh" | bash
      ;;
    *)
      echo "❌ Unknown package: $1"
      show_help
      ;;
  esac
}

# CLI update function
function update_cli() {
  echo "📦 Updating 5echo CLI..."
  sudo curl -sL "$CLI_URL" -o "$CLI_PATH"
  sudo chmod +x "$CLI_PATH"
  echo "✅ CLI updated! Try: 5echo help"
}

# Main logic
case "$1" in
  install)
    install_package "$2"
    ;;
  update)
    update_cli
    ;;
  help|--help|-h|"")
    show_help
    ;;
  *)
    echo "❌ Unknown command: $1"
    show_help
    ;;
esac
