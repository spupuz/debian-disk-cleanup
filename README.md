# debian-disk-cleanup

Ultra-safe disk cleanup script for Debian-based hosts.

## Overview

A safe, configuration-driven disk cleanup script designed for Debian/Ubuntu-based systems.
Comprehensive checks prevent accidental removal of critical data. Supports Telegram
notifications with Markdown V2 formatting.

## Features

- **Root-only execution** - Prevents run as non-root user
- **Configuration-driven** - Edit `/etc/default/disk_cleanup.conf` or `~/.disk_cleanup.conf`
- **Dry-run mode** - Preview changes with `DRY_RUN=true`
- **Force mode** - Skip confirmations with `FORCE_MODE=true`
- **Comprehensive cleanup**:
  - APT cache cleanup
  - Systemd journal vacuum
  - Docker system prune (with confirmation)
  - **Super-safe containerd snapshot cleanup** - Uses `ctr` CLI (not direct `rm -rf`), checks actual container references, disabled by default
  - Apache logs cleanup
  - Orphaned data in whitelisted paths
- **Telegram notifications** - Markdown V2 formatted updates
- **Disk space thresholds** - Configurable minimum free GB
- **Whitelisted paths only** - No arbitrary deletion

## Quick Start

```bash
# Make executable
chmod +x disk_cleanup.sh

# Run with defaults
./disk_cleanup.sh

# Preview only (dry-run)
DRY_RUN=true ./disk_cleanup.sh

# Run in force mode (skip confirmations)
FORCE_MODE=true ./disk_cleanup.sh
```

## Configuration

Copy the config file and edit as needed:

```bash
cp disk_cleanup_config.cfg /etc/default/disk_cleanup.conf
```

Edit `/etc/default/disk_cleanup.conf` to:
- Set `MIN_FREE_GB` - minimum free space threshold in GB
- Enable/disable cleanup options: `CLEAN_APT_CACHE`, `CLEAN_JOURNAL`, `CLEAN_DOCKER_PRUNE`, `CLEAN_CONTAINERD_SNAPSHOTS`
- Add paths to `WHITELISTED_PATHS` array for orphaned data cleanup
- Configure Telegram: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`

## Safety Features

- Verifies containerd/docker is running before snapshot cleanup
- Checks active containers before pruning snapshots
- Only removes snapshots not referenced by active containers
- Minimum free space threshold prevents cleanup when critically low
- Dry-run mode for safe preview
- Configuration validation before operations

## Supported Distributions

Debian 11+, Ubuntu 20.04+, and derivatives with systemd, apt, and docker/containerd.

## Quick Start

### Using the one-line installer (recommended)
```bash
curl -sSL https://raw.githubusercontent.com/spupuz/debian-disk-cleanup/main/install_disk_cleanup.sh | bash
```

### Manual installation
```bash
# Clone the repository
git clone https://github.com/spupuz/debian-disk-cleanup.git
cd debian-disk-cleanup

# Make the script executable
chmod +x disk_cleanup.sh

# Install configuration
cp disk_cleanup_config.cfg /etc/default/disk_cleanup.conf

# Edit configuration
#   - Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID for notifications
#   - Adjust MIN_FREE_GB, cleanup options, etc.

# Run with defaults
./disk_cleanup.sh

# Or use the one-line installer (above)
```

## Installation

### Using the one-line installer (recommended)
```bash
# Default installation to /usr/local/bin
curl -sSL https://raw.githubusercontent.com/spupuz/debian-disk-cleanup/main/install_disk_cleanup.sh | bash

# Custom installation path
curl -sSL https://raw.githubusercontent.com/spupuz/debian-disk-cleanup/main/install_disk_cleanup.sh | bash -s -- --dir /opt/my-scripts
```

This will:
- Download and install the script to the specified directory (default: `/usr/local/bin`)
- Install default configuration to `/etc/default/disk_cleanup.conf`
- Set up systemd timer for daily automated cleanup at the custom path
- Configure log rotation
- Print next steps for configuring Telegram

**Auto-update mechanism**: The script automatically checks GitHub releases for newer versions at `https://github.com/spupuz/debian-disk-cleanup/releases/latest`. This works **regardless of the installation path** - the update mechanism always checks GitHub, not the local file system. To update, simply re-run the install script or run `disk_cleanup.sh` with `AUTO_UPDATE=true` (default).

### Manual installation
```bash
# 1. Clone or download
git clone https://github.com/spupuz/debian-disk-cleanup.git
cd debian-disk-cleanup

# 2. Make script executable
chmod +x disk_cleanup.sh

# 3. Install configuration
cp disk_cleanup_config.cfg /etc/default/disk_cleanup.conf

# 4. Edit configuration (required for Telegram notifications)
#    - Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in /etc/default/disk_cleanup.conf
#    - Adjust MIN_FREE_GB, cleanup options, etc.

# 5. Set up log directory
mkdir -p /var/log
touch /var/log/disk_cleanup.log

# 6. Enable systemd timer (optional)
#    systemctl enable --now disk_cleanup.timer

# 7. Run with defaults
#    ./disk_cleanup.sh
#    # Or with dry-run first:
#    DRY_RUN=true ./disk_cleanup.sh
```

## License

MIT