#!/bin/bash
set -e

REPO_BASE="https://scripts.5echo.io"
CLI_PATH="/usr/local/bin/5echo"
CLI_URL="$REPO_BASE/5echo"

# ------------------------------
# Main: Run this if curl | bash
# ------------------------------

echo -e "\n🛠️  5echo CLI Installer\n"

# Check if CLI already exists
if [[ -f "$CLI_PATH" ]]; then
  echo "⚠️  5echo CLI is already installed at $CLI_PATH"
  echo "ℹ️  Use '5echo update' to update to the latest version."
  exit 0
fi

# Download and install CLI
echo "📦 Installing 5echo CLI to $CLI_PATH"
sudo curl -sL "$CLI_URL" -o "$CLI_PATH"
sudo chmod +x "$CLI_PATH"

# Confirm installation
echo -e "\n✅ 5echo CLI installed!"
echo -e "👉 Try: ${CLI_PATH} help\n"
