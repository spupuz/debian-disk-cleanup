#!/bin/bash
# ============================================================================
# Ultra-Safe Disk Cleanup Script for Debian Hosts
# ============================================================================

set -euo pipefail

# ============================================================================
# Functions - defined first
# ============================================================================

print_help() {
    echo "Usage: $SCRIPT_NAME [options]"
    echo "Ultra-safe disk cleanup script for Debian hosts."
    echo ""
    echo "Options:"
    echo "  --help, -h      Show this help message"
    echo "  --version, -V   Show script version and exit"
    echo "  --dry-run       Preview changes without making any modifications"
    echo "  --force         Skip interactive confirmations (where applicable)"
    echo "  --no-update     Disable auto-update check at startup"
    echo ""
    echo "Environment variables:"
    echo "  AUTO_UPDATE     Set to 'false' to disable auto-update (default: true)"
    echo "  FORCE_MODE      Set to 'true' to skip confirmations"
    echo "  DRY_RUN         Set to 'true' to preview only"
    echo "  TELEGRAM_BOT_TOKEN  Telegram bot token"
    echo "  TELEGRAM_CHAT_ID    Telegram chat ID"
}

print_version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
}

# ============================================================================
# Default Configuration Values
# ============================================================================

SCRIPT_NAME="disk_cleanup"
SCRIPT_VERSION="1.0.0"
EXEC_HOSTNAME=$(hostname 2>/dev/null || echo "unknown-host")

# GitHub auto-update config
GITHUB_OWNER="spupuz"
GITHUB_REPO="debian-disk-cleanup"
GITHUB_RELEASE_LATEST="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/latest"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/$GITHUB_OWNER/$GITHUB_REPO/main"

# Telegram configuration
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_ENABLED=false

# Cleanup options (true/false)
CLEAN_APT_CACHE=true
CLEAN_JOURNAL=true
CLEAN_DOCKER_PRUNE=false
CLEAN_CONTAINERD_SNAPSHOTS=false
CLEAN_APACHE_LOGS=false
CLEAN_NANO=false

# Space thresholds (in GB - cleanup only if free space below this)
MIN_FREE_GB=5

# Which paths to check for orphaned data (only safe, verified paths)
WHITELISTED_PATHS=()

# Force mode (skip interactive confirmation)
FORCE_MODE=false

# Dry run mode (show what would be done without doing it)
DRY_RUN=false

# Logging
LOG_TO_FILE=true
LOG_FILE="/var/log/disk_cleanup.log"

# Parse global flags early (before any other processing)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            print_help
            exit 0
            ;;

        --version|-V)
            print_version
            exit 0
            ;;

        --dry-run)
            DRY_RUN=true
            shift
            ;;

        --force)
            FORCE_MODE=true
            shift
            ;;

        --no-update)
            AUTO_UPDATE=false
            shift
            ;;

        *)
            log_message "WARN" "Unknown flag: $1, ignoring"
            shift
            ;;
    esac
done

# ============================================================================
# Rest of the script continues...
# ============================================================================
# (The original script content would follow here)
# ============================================================================

# Quick test
print_help
