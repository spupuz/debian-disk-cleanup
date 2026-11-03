#!/bin/bash
# ============================================================================
# debian-disk-cleanup - Auto-installation script
# Usage: curl -sSL https://raw.githubusercontent.com/spupuz/debian-disk-cleanup/main/install_disk_cleanup.sh | bash
#
# Optional: install to custom path
#   curl -sSL https://raw.githubusercontent.com/spupuz/debian-disk-cleanup/main/install_disk_cleanup.sh | bash -s -- --dir /opt/my-scripts
# ============================================================================

set -euo pipefail

# Configuration
GITHUB_REPO="spupuz/debian-disk-cleanup"
DEFAULT_INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/default"
LOG_DIR="/var/log"
SCRIPT_NAME="disk_cleanup"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

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
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Set install directory (use default if not specified)
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Determine latest version from GitHub
log_info "Checking latest version from GitHub..."
LATEST_VERSION=$(curl -sf --connect-timeout 10 --max-time 15 "https://raw.githubusercontent.com/${GITHUB_REPO}/main/version.txt" 2>/dev/null)
if [[ -z "$LATEST_VERSION" ]]; then
    log_error "Failed to fetch latest version from GitHub"
    exit 1
fi

log_info "Version: $LATEST_VERSION"

# Create installation directories
log_info "Creating installation directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$LOG_DIR"

# Download the main script
log_info "Downloading $SCRIPT_NAME script to $INSTALL_DIR..."
SCRIPT_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/disk_cleanup.sh"
if curl -sfL "$SCRIPT_URL" -o "$INSTALL_DIR/$SCRIPT_NAME" 2>/dev/null; then
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    log_info "Script installed to $INSTALL_DIR/$SCRIPT_NAME"
else
    log_error "Failed to download script from $SCRIPT_URL"
    exit 1
fi

# Download configuration file (if it doesn't already exist)
CONFIG_FILE="$CONFIG_DIR/disk_cleanup.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_info "Installing configuration file..."
    CONFIG_URL="https://raw.githubusercontent.com/${GITHUB_REPO}/main/disk_cleanup_config.cfg"
    if curl -sfL "$CONFIG_URL" -o "$CONFIG_FILE" 2>/dev/null; then
        log_info "Configuration installed to $CONFIG_FILE"
        log_warn "Please edit $CONFIG_FILE to set your Telegram bot token and chat ID"
    else
        log_warn "Failed to download configuration file"
    fi
else
    log_info "Configuration already exists at $CONFIG_FILE, skipping"
fi

# Set up log directory and file
LOG_FILE="$LOG_DIR/disk_cleanup.log"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
log_info "Log file: $LOG_FILE"

# Download systemd units (optional)
log_info "Installing systemd timer and service..."
TIMER_FILE="/etc/systemd/system/disk_cleanup.timer"
SERVICE_FILE="/etc/systemd/system/disk_cleanup.service"

# Update the ExecStart in the service file to match the install path
sed "s|/usr/local/bin/disk_cleanup|$INSTALL_DIR/$SCRIPT_NAME|g" > "$SERVICE_FILE" << 'SERVICEEOF'
[Unit]
Description=Disk Cleanup Script
Documentation=https://github.com/spupuz/debian-disk-cleanup

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk_cleanup.sh
StandardOutput=journal
StandardError=journal
SERVICEEOF

chmod 644 "$TIMER_FILE" "$SERVICE_FILE"
systemctl daemon-reload 2>/dev/null || log_warn "systemctl not available, skipping daemon reload"

# Final summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Installed files:"
echo "  - $INSTALL_DIR/$SCRIPT_NAME (main script)"
echo "  - $CONFIG_FILE (configuration)"
echo "  - $LOG_FILE (log file)"
echo "  - $TIMER_FILE (systemd timer)"
echo "  - $SERVICE_FILE (systemd service)"
echo ""
echo "Next steps:"
echo "  1. Edit $CONFIG_FILE to configure Telegram credentials"
echo "    - Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
echo "  2. Run dry-run first: $INSTALL_DIR/$SCRIPT_NAME --dry-run"
echo "  3. Run cleanup: $INSTALL_DIR/$SCRIPT_NAME"
echo "  4. Enable systemd timer: systemctl enable --now disk_cleanup.timer"
echo ""
echo "Usage examples:"
echo "  $INSTALL_DIR/$SCRIPT_NAME --help    Show help"
echo "  $INSTALL_DIR/$SCRIPT_NAME --version  Show version"
echo "  $INSTALL_DIR/$SCRIPT_NAME --dry-run  Preview cleanup"
echo "  $INSTALL_DIR/$SCRIPT_NAME --force  Skip confirmations"
echo ""
echo "Auto-update mechanism:"
echo "  The script automatically checks GitHub releases for newer versions."
echo "  To update, re-run the install script or run with --no-update flag to skip."
echo "  The auto-update works regardless of the installation path - it always"
echo "  checks https://github.com/${GITHUB_REPO}/releases for the latest version."
echo ""
echo "Repository: https://github.com/${GITHUB_REPO}"
echo "Docs:       https://github.com/${GITHUB_REPO}/blob/main/README.md"
echo ""
echo -e "${GREEN}Enjoy clean disks!${NC}"