#!/bin/bash
# ============================================================================
# Auto-installation script for debian-disk-cleanup
# ============================================================================

set -euo pipefail

# Default install directory
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/default"
LOG_DIR="/var/log"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir|-d)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--dir INSTALL_DIR] [--help]"
            echo ""
            echo "Options:"
            echo "  --dir, -d INSTALL_DIR  Installation directory (default: /usr/local/bin)"
            echo "  --help, -h             Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Get latest release version from GitHub
LATEST_VERSION=$(curl -sf --connect-timeout 10 --max-time 15 "https://raw.githubusercontent.com/spupuz/debian-disk-cleanup/main/version.txt" 2>/dev/null || echo "1.0.0")

echo "Installing debian-disk-cleanup v$LATEST_VERSION"

# Download the script
INSTALL_SCRIPT="$INSTALL_DIR/disk_cleanup.sh"
curl -sfL "https://raw.githubusercontent.com/spupuz/debian-disk-cleanup/main/disk_cleanup.sh" -o "$INSTALL_SCRIPT" 2>/dev/null || {
    echo "ERROR: Failed to download disk_cleanup.sh"
    exit 1
}

# Make executable
chmod +x "$INSTALL_SCRIPT"

# Install configuration file
CONFIG_FILE="$CONFIG_DIR/disk_cleanup.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    if curl -sfL "https://raw.githubusercontent.com/spupuz/debian-disk-cleanup/main/disk_cleanup_config.cfg" -o "$CONFIG_FILE" 2>/dev/null; then
        echo "Created default config at $CONFIG_FILE"
        echo "Please edit $CONFIG_FILE to set your Telegram credentials and preferences"
    else
        echo "WARNING: Failed to download default config to $CONFIG_FILE"
    fi
else
    echo "Config already exists at $CONFIG_FILE, skipping"
fi

# Set up log directory
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/disk_cleanup.log"
chmod 644 "$LOG_DIR/disk_cleanup.log"

# Create systemd timer (optional - ask user)
echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "1. Edit $CONFIG_FILE to configure Telegram (bot token and chat ID)"
echo "2. Review $INSTALL_DIR/disk_cleanup.sh and adjust settings as needed"
echo "3. Run: $INSTALL_DIR/disk_cleanup.sh --dry-run  (preview first)"
echo "4. Run: $INSTALL_DIR/disk_cleanup.sh       (actual cleanup)"
echo ""
echo "For automated scheduling, see systemd timer setup below."
