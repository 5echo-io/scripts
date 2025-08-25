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

# If script is executed directly (via curl | bash), install CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo -e "\n🛠️  5echo CLI Installer\n"

  if [[ -f "$CLI_PATH" ]]; then
    echo "⚠️  5echo CLI is already installed at $CLI_PATH"
    echo "ℹ️  Use '5echo update' to update to the latest version."
    exit 0
  fi

  echo "📦 Installing 5echo CLI to $CLI_PATH"
  sudo curl -sL "$CLI_URL" -o "$CLI_PATH"
  sudo chmod +x "$CLI_PATH"
  echo "✅ Installed! Try: 5echo help"
  exit 0
fi

# If sourced or executed manually, run CLI interface
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
