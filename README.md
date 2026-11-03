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
  - Containerd snapshot cleanup (super-safe, checks active container references)
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

## License

MIT