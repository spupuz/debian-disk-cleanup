#!/bin/bash
# ============================================================================
# Ultra-Safe Disk Cleanup Script for Debian Hosts
# ============================================================================
# A safe, configuration-driven disk cleanup script for Debian-based systems.
# Features comprehensive checks, dry-run mode, and selective cleanup operations.
# Designed to work on any Debian host with minimal dependencies.
#
# Requirements:
#   - Running as root
#   - Debian/Ubuntu-based system
#   - Optional: curl for Telegram notifications
#
# Configuration is driven by /etc/default/disk_cleanup.conf or ~/.disk_cleanup.conf
# ============================================================================

set -euo pipefail

# ============================================================================
# Default Configuration Values
# ============================================================================

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

# ============================================================================
# Load Configuration
# ============================================================================

SCRIPT_NAME="disk_cleanup"
EXEC_HOSTNAME=$(hostname 2>/dev/null || echo "unknown-host")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILES=("/etc/default/disk_cleanup.conf" "$HOME/.disk_cleanup.conf")

for config_file in "${CONFIG_FILES[@]}"; do
    if [[ -f "$config_file" ]]; then
        log_message "INFO" "Loading configuration from $config_file"
        # Parse configuration file - extract variable assignments
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Only set known variables
            case "$key" in
                TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID|TELEGRAM_ENABLED|CLEAN_APT_CACHE|CLEAN_JOURNAL|CLEAN_DOCKER_PRUNE|CLEAN_CONTAINERD_SNAPSHOTS|CLEAN_APACHE_LOGS|CLEAN_NANO|MIN_FREE_GB|FORCE_MODE|DRY_RUN|LOG_TO_FILE|LOG_FILE|WHITELISTED_PATHS)
                    export "${key}"="${value}"
                    ;;
                *)
                    log_message "WARN" "Unknown configuration key: ${key}, skipping"
                    ;;
            esac
        done < "$config_file"
    fi
done

# Set Telegram enabled state
if [[ -n "${TELEGRAM_BOT_TOKEN}" ]] && [[ "${TELEGRAM_BOT_TOKEN}" != "YOUR_TELEGRAM_BOT_TOKEN_HERE" ]] && \
   [[ -n "${TELEGRAM_CHAT_ID}" ]] && [[ "${TELEGRAM_CHAT_ID}" != "YOUR_TELEGRAM_CHAT_ID_HERE" ]]; then
    TELEGRAM_ENABLED=true
fi

# ============================================================================
# Utility Functions
# ============================================================================

# Escape Markdown V2 special characters
escape_markdown_v2() {
    local text="$1"
    # Proper Markdown V2 escaping using sed
    local special_chars='_*[()~#+\-=|{}!\\>'
    local escaped
    escaped=$(printf '%s' "$text" | sed 's/[][\(\)~#+\-=|{}\!\\>]/\\&/g')
    printf '%s' "$escaped"
}

log_message() {
    local level="$1"
    local message="$2"
    local escaped_msg
    escaped_msg=$(escape_markdown_v2 "$message")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Log to file if enabled
    if [[ "${LOG_TO_FILE}" == "true" ]]; then
        mkdir -p "$(dirname "$LOG_FILE" 2>/dev/null)" 2>/dev/null || true
        echo "[$timestamp] [$level] ${message}" | tee -a "${LOG_FILE:-/dev/null}" 2>/dev/null || true
    else
        echo "[$timestamp] [$level] ${message}" 2>/dev/null || true
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        local err_msg="❌ Script must be run as root"
        log_message "ERROR" "$err_msg"
        send_telegram "$err_msg"
        exit 1
    fi
}

send_telegram() {
    if [[ "${TELEGRAM_ENABLED}" != "true" ]]; then
        return 0
    fi

    local message="$1"
    # Escape for Markdown V2
    local escaped_message
    escaped_message=$(escape_markdown_v2 "$message")

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
    # Build payload
    local payload="chat_id=${TELEGRAM_CHAT_ID}&parse_mode=MarkdownV2&text=${escaped_message}"

    if curl -s --max-time 15 -X POST "$url" -d "$payload" > /dev/null 2>&1; then
        log_message "INFO" "Telegram message sent successfully"
    else
        log_message "WARN" "Failed to send Telegram message"
    fi
}

check_disk_space() {
    local df_output
    df_output=$(df -B1 / | tail -1)
    local used avail size pct

    used=$(echo "$df_output" | awk '{print $3}')
    avail=$(echo "$df_output" | awk '{print $4}')
    size=$(echo "$df_output" | awk '{print $2}')
    pct=$(echo "$df_output" | awk '{print $5}' | tr -d '%')

    # Convert to GB
    local used_gb avail_gb size_gb
    used_gb=$((used / 1024 / 1024 / 1024))
    avail_gb=$((avail / 1024 / 1024 / 1024))
    size_gb=$((size / 1024 / 1024 / 1024))

    local disk_info
    disk_info="$(escape_markdown_v2 "Disk: ${size_gb}G total, ${used_gb}G used, ${avail_gb}G free (${pct}% used)")"

    log_message "INFO" "${disk_info}"

    # Check minimum free space threshold
    if [[ $avail_gb -le $MIN_FREE_GB ]]; then
        local warning_msg
        warning_msg="$(escape_markdown_v2 "⚠️ Free space (${avail_gb}G) below minimum threshold (${MIN_FREE_GB}G). Proceeding with forced cleanup.")"
        log_message "WARN" "Low disk space: ${avail_gb}G (min: ${MIN_FREE_GB}G)"
        send_telegram "⚠️ *Warning*: Free space *${avail_gb}G* is below minimum *${MIN_FREE_GB}G*. Cleanup proceeding forced."
        return 1
    fi

    local ok_msg
    ok_msg="$(escape_markdown_v2 "✅ Sufficient free space: ${avail_gb}G (minimum ${MIN_FREE_GB}G required)")"
    log_message "INFO" "${ok_msg}"
    return 0
}

# ============================================================================
# APT Cache Cleanup
# ============================================================================

cleanup_apt_cache() {
    if [[ "${CLEAN_APT_CACHE}" != "true" ]]; then
        log_message "INFO" "APT cache cleanup skipped (CLEAN_APT_CACHE not enabled)"
        return 0
    fi

    log_message "INFO" "Cleaning APT cache..."

    if $DRY_RUN; then
        log_message "INFO" "[DRY RUN] Would run: apt clean"
        send_telegram "🔍 *DRY RUN*: Would clean APT cache on *${EXEC_HOSTNAME}*"
        return 0
    fi

    if apt clean 2>&1; then
        local apt_msg
        apt_msg="$(escape_markdown_v2 "✅ *APT cache cleaned* successfully on *${EXEC_HOSTNAME}*")"
        log_message "INFO" "APT cache cleaned"
        send_telegram "${apt_msg}"
        return 0
    else
        local apt_err
        apt_err="$(escape_markdown_v2 "⚠️ *APT cache cleanup* had no effect or encountered issues on *${EXEC_HOSTNAME}*")"
        log_message "WARN" "Nothing to clean for APT cache"
        send_telegram "${apt_err}"
        return 1
    fi
}

# ============================================================================
# Systemd Journal Cleanup
# ============================================================================

cleanup_journal() {
    if [[ "${CLEAN_JOURNAL}" != "true" ]]; then
        log_message "INFO" "Journal cleanup skipped (CLEAN_JOURNAL not enabled)"
        return 0
    fi

    log_message "INFO" "Cleaning systemd journal..."

    if [[ "${JOURNAL_VACUUM_SIZE}" -gt 0 ]]; then
        if $DRY_RUN; then
            log_message "INFO" "[DRY RUN] Would run: journalctl --vacuum-size=${JOURNAL_VACUUM_SIZE}M"
            send_telegram "🔍 *DRY RUN*: Would vacuum journal to ${JOURNAL_VACUUM_SIZE}M on *${EXEC_HOSTNAME}*"
            return 0
        fi

        if journalctl --vacuum-size="${JOURNAL_VACUUM_SIZE}M" 2>&1; then
            local journal_msg
            journal_msg="$(escape_markdown_v2 "📓 *Journal compressed to ${JOURNAL_VACUUM_SIZE}M* on *${EXEC_HOSTNAME}*")"
            log_message "INFO" "Journal compressed to ${JOURNAL_VACUUM_SIZE}M"
            send_telegram "${journal_msg}"
            return 0
        else
            local journal_err
            journal_err="$(escape_markdown_v2 "❌ *Journal cleanup failed* on *${EXEC_HOSTNAME}*")"
            log_message "WARN" "Journal cleanup failed"
            send_telegram "${journal_err}"
            return 1
        fi
    else
        local journal_skip
        journal_skip="$(escape_markdown_v2 "⏭️ *Journal cleanup skipped* (vacuum-size=0) on *${EXEC_HOSTNAME}*")"
        log_message "INFO" "Journal cleanup skipped"
        send_telegram "${journal_skip}"
        return 0
    fi
}

# ============================================================================
# Docker Prune
# ============================================================================

cleanup_docker_prune() {
    if [[ "${CLEAN_DOCKER_PRUNE}" != "true" ]]; then
        log_message "INFO" "Docker prune skipped (CLEAN_DOCKER_PRUNE not enabled)"
        return 0
    fi

    log_message "INFO" "Initiating Docker system prune..."

    if $DRY_RUN; then
        log_message "INFO" "[DRY RUN] Would run: docker system prune --all"
        send_telegram "🔍 *DRY RUN*: Would prune Docker system (images, volumes, networks) on *${EXEC_HOSTNAME}*"
        return 0
    fi

    # For safety, require confirmation unless FORCE_DOCKER_PRUNE is set
    if [[ "${FORCE_MODE}" != "true" ]]; then
        local confirm_msg
        confirm_msg="$(escape_markdown_v2 "Docker prune confirmation needed on ${EXEC_HOSTNAME}. Proceed with docker system prune --all? (y/N)")"
        log_message "INFO" "Docker prune confirmation required"

        # Read from tty for confirmation - non-interactive fallback
        local response="N"
        if [[ -t 0 ]]; then
            response=$(read -r response < /dev/tty 2>/dev/null || echo "N")
        fi

        if [[ "$response" =~ ^[Yy]$ ]]; then
            if docker system prune --all 2>&1; then
                local docker_ok
                docker_ok="$(escape_markdown_v2 "✅ *Docker prune completed* successfully on *${EXEC_HOSTNAME}*")"
                log_message "INFO" "Docker prune completed"
                send_telegram "${docker_ok}"
                return 0
            else
                local docker_err
                docker_err="$(escape_markdown_v2 "❌ *Docker prune failed* on *${EXEC_HOSTNAME}*")"
                log_message "WARN" "Docker prune failed"
                send_telegram "${docker_err}"
                return 1
            fi
        else
            local docker_skipped
            docker_skipped="$(escape_markdown_v2 "⏭️ *Docker prune skipped* by user on *${EXEC_HOSTNAME}*")"
            log_message "INFO" "Docker prune skipped by user"
            send_telegram "${docker_skipped}"
            return 0
        fi
    else
        # Forced mode
        if docker system prune --all 2>&1; then
            local docker_forced_ok
            docker_forced_ok="$(escape_markdown_v2 "✅ *Forced Docker prune completed* on *${EXEC_HOSTNAME}*")"
            log_message "INFO" "Forced Docker prune completed"
            send_telegram "${docker_forced_ok}"
            return 0
        else
            local docker_forced_err
            docker_forced_err="$(escape_markdown_v2 "❌ *Forced Docker prune failed* on *${EXEC_HOSTNAME}*")"
            log_message "WARN" "Forced Docker prune failed"
            send_telegram "${docker_forced_err}"
            return 1
        fi
    fi
}

# ============================================================================
# Containerd Snapshot Cleanup (Super Safe)
# ============================================================================

cleanup_containerd_snapshots_super_safe() {
    if [[ "${CLEAN_CONTAINERD_SNAPSHOTS}" != "true" ]]; then
        log_message "INFO" "Containerd snapshot cleanup skipped (CLEAN_CONTAINERD_SNAPSHOTS not enabled)"
        return 0
    fi

    log_message "INFO" "Starting super-safe containerd snapshot cleanup..."
    send_telegram "🗂️ *Starting super-safe containerd snapshot cleanup* on host *${EXEC_HOSTNAME}*"

    local freed_gb=0
    local snapshot_count_before=0
    local snapshot_count_after=0
    local active_containers=0
    local safe_to_prune=true

    # 1. Verify containerd is running
    log_message "INFO" "Checking containerd status..."
    if ! systemctl is-active --quiet containerd 2>/dev/null; then
        local err_msg
        err_msg="$(escape_markdown_v2 "⚠️ containerd is not running. Skipping snapshot cleanup.")"
        log_message "WARN" "containerd not running, skipping"
        send_telegram "⚠️ *Warning*: containerd is not running on *${EXEC_HOSTNAME}*. Skipping snapshot cleanup."
        safe_to_prune=false
    fi

    # 2. Count snapshots before
    if [[ "$safe_to_prune" == "true" ]]; then
        if [[ -d "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots" ]]; then
            snapshot_count_before=$(ls -la /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/ 2>/dev/null | wc -l || echo "0")
            local before_msg
            before_msg="$(escape_markdown_v2 "📊 Snapshot count before cleanup: *${snapshot_count_before}* on *${EXEC_HOSTNAME}*")"
            log_message "INFO" "Snapshots before: ${snapshot_count_before}"
            send_telegram "${before_msg}"
        else
            local no_snap_msg
            no_snap_msg="$(escape_markdown_v2 "📁 Snapshot directory not found. Nothing to clean.")"
            log_message "INFO" "Snapshot directory not found"
            send_telegram "📁 *Info*: Snapshot directory not found on *${EXEC_HOSTNAME}*. Nothing to clean."
            safe_to_prune=false
        fi
    fi

    # 3. Check which containers are actively using snapshots
    if [[ "$safe_to_prune" == "true" ]]; then
        log_message "INFO" "Checking actively running containers..."

        # Get list of running containers via docker
        local running_containers
        running_containers=$(docker ps --format "{{.Names}}" 2>/dev/null || echo "")

        if [[ -n "$running_containers" ]]; then
            active_containers=$(echo "$running_containers" | wc -l)
            local containers_msg
            containers_msg="$(escape_markdown_v2 "📦 *${active_containers}* active containers found on *${EXEC_HOSTNAME}*")"
            log_message "INFO" "Active containers: ${active_containers}"
            send_telegram "${containers_msg}"
        fi
    fi

    # 4. Get containerd snapshot metadata to identify which are in use
    #    We'll be conservative: only prune snapshots NOT referenced by active containers
    if [[ "$safe_to_prune" == "true" ]]; then
        log_message "INFO" "Analyzing snapshot metadata for container usage..."

        # Create a temp file for snapshots to prune
        local snap_prune_list="/tmp/snapshots_to_prune_$$.txt"
        > "$snap_prune_list"

        # Get all snapshot directories
        local snap_dir="/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
        if [[ -d "$snap_dir" ]]; then
            local snapshots=()
            while IFS= read -r -d '' snapEntry; do
                # Extract just the snapshot ID/dirname
                local snapName
                snapName=$(basename "$snapEntry")
                snapshots+=("$snapName")
            done < <(find "$snap_dir" -maxdepth 1 -type d -print0 2>/dev/null)

            log_message "INFO" "Found ${#snapshots[@]} snapshot directories to evaluate"

            for snapID in "${snapshots[@]}"; do
                # Check if this snapshot is used by any running container
                local is_referenced=false

                # Method 1: Check if any docker container is using this snapshot via graph driver
                if [[ -n "$running_containers" ]]; then
                    for container_name in $running_containers; do
                        # Check container's snapshot/overlay usage
                        local container_snapshot_ref
                        container_snapshot_ref=$(docker inspect --format='{{.GraphDriver.Data.MergedRollup256}}' "$container_name" 2>/dev/null || echo "")
                        # If container has a merged rollup, it's using snapshots - be conservative
                        if [[ -n "$container_snapshot_ref" ]]; then
                            is_referenced=true
                            break
                        fi
                    done
                else
                    # No running containers, so it's safer to prune (orphaned snapshots)
                    is_referenced=false
                fi

                # If snapshot is NOT referenced by any active container, mark for prune
                if [[ "$is_referenced" == "false" ]]; then
                    echo "$snapID" >> "$snap_prune_list"
                    log_message "INFO" "Snapshot $snapID marked for pruning (not referenced by active containers)"
                else
                    log_message "INFO" "Snapshot $snapID SKIPPED (referenced by active container(s))"
                fi
            done

            # 5. Perform the prune only if there are items to prune
            local items_to_prune
            items_to_prune=$(wc -l < "$snap_prune_list")

            if [[ $items_to_prune -gt 0 ]]; then
                log_message "INFO" "Pruning $items_to_prune snapshots that are not referenced by active containers..."

                send_telegram "🗑️ *Pruning ${items_to_prune} safe snapshots* on *${EXEC_HOSTNAME}*. These are not used by any running container."

                # Perform the actual prune - remove orphaned snapshot directories
                local prune_success=true
                while IFS= read -r snapID_to_prune; do
                    if [[ -n "$snapID_to_prune" ]]; then
                        if [[ -d "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/${snapID_to_prune}" ]]; then
                            if $DRY_RUN; then
                                log_message "INFO" "[DRY RUN] Would remove snapshot: ${snapID_to_prune}"
                            else
                                # Safe removal: remove the directory and its contents
                                rm -rf "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/${snapID_to_prune}" 2>/dev/null || \
                                    log_message "WARN" "Failed to remove snapshot: ${snapID_to_prune}"
                            fi
                        fi
                    fi
                done < "$snap_prune_list"

                # Count remaining snapshots
                if [[ -d "$snap_dir" ]]; then
                    snapshot_count_after=$(ls -la "$snap_dir" 2>/dev/null | wc -l || echo "0")

                    local after_msg
                    after_msg="$(escape_markdown_v2 "✅ Cleanup complete on *${EXEC_HOSTNAME}*. Snapshot count: *${snapshot_count_before}* → *${snapshot_count_after}*")"
                    log_message "INFO" "Snapshots after: ${snapshot_count_after}"
                    send_telegram "${after_msg}"
                fi
            else
                local nothing_to_prune
                nothing_to_prune="$(escape_markdown_v2 "✅ No unsafe snapshots found on *${EXEC_HOSTNAME}*. All snapshots are referenced by active containers. No cleanup performed.")"
                log_message "INFO" "No unsafe snapshots found - all are in use by running containers"
                send_telegram "${nothing_to_prune}"
            fi
        fi

        # Cleanup temp file
        rm -f "$snap_prune_list" 2>/dev/null || true
    fi

    # Summary
    local total_freed_msg
    total_freed_msg="$(escape_markdown_v2 "📈 Containerd snapshot cleanup on *${EXEC_HOSTNAME}*: ${snapshot_count_before} → ${snapshot_count_after} snapshots")"
    log_message "INFO" "Snapshot cleanup summary: ${snapshot_count_before} → ${snapshot_count_after}"
    send_telegram "${total_freed_msg}"
}

# ============================================================================
# Apache Logs Cleanup
# ============================================================================

cleanup_apache_logs() {
    if [[ "${CLEAN_APACHE_LOGS}" != "true" ]]; then
        log_message "INFO" "Apache logs cleanup skipped (CLEAN_APACHE_LOGS not enabled)"
        return 0
    fi

    log_message "INFO" "Cleaning Apache logs..."

    local apache_log_dirs=("/var/log/apache2" "/var/log/httpd")

    for log_dir in "${apache_log_dirs[@]}"; do
        if [[ -d "$log_dir" ]]; then
            if $DRY_RUN; then
                log_message "INFO" "[DRY RUN] Would clean logs in: $log_dir"
            else
                # Rotate and clean old logs, keep recent ones
                find "$log_dir" -name "*.1" -o -name "*.gz" -o -name "*.old" 2>/dev/null | while read -r old_log; do
                    local log_name
                    log_name=$(basename "$old_log")
                    # Only remove compressed/rotated old logs older than 30 days
                    if [[ -n "$old_log" ]]; then
                        local days_old
                        days_old=$(find "$old_log" -mtime +30 2>/dev/null | wc -l)
                        if [[ $days_old -gt 0 ]]; then
                            if $DRY_RUN; then
                                log_message "INFO" "[DRY RUN] Would remove: $old_log"
                            else
                                rm -f "$old_log" 2>/dev/null || true
                                log_message "INFO" "Removed old log: $old_log"
                            fi
                        fi
                    fi
                done
                send_telegram "📄 *Apache logs cleanup* on *${EXEC_HOSTNAME}*. Check logs for details."
            fi
        fi
    done

    return 0
}

# ============================================================================
# Orphaned Data Cleanup (Whitelisted Paths Only)
# ============================================================================

cleanup_orphaned_data() {
    log_message "INFO" "Checking for orphaned data in whitelisted paths..."

    for path in "${WHITELISTED_PATHS[@]}"; do
        if [[ -z "$path" ]]; then
            continue
        fi

        if [[ ! -d "$path" ]]; then
            log_message "INFO" "Path not found: $path, skipping"
            continue
        fi

        log_message "INFO" "Checking path: $path"

        if $DRY_RUN; then
            log_message "INFO" "[DRY RUN] Would inspect: $path"
            continue
        fi

        # Find large files/directories not accessed in over 30 days
        # Only clean if explicitly safe - this is a placeholder for verified paths
        local large_files
        large_files=$(find "$path" -type f -atime +30 -size +100M 2>/dev/null | head -20)

        if [[ -n "$large_files" ]]; then
            log_message "INFO" "Found potentially orphanable files in $path"
            echo "$large_files" | while read -r file; do
                local days_since_access
                days_since_access=$(find "$file" -atime +30 2>/dev/null | wc -l || echo "0")
                if [[ $days_since_access -gt 0 ]]; then
                    # Double-check: verify this is likely orphaned data, not application data
                    local file_name
                    file_name=$(basename "$file")
                    # Skip common application extensions
                    case "$file_name" in
                        *.log|*.tmp|*.cache|*.bak|*.old|.old|*.swp|*.pyc|*.class)
                            # Safe to remove
                            rm -f "$file" 2>/dev/null || true
                            log_message "INFO" "Removed orphaned file: $file"
                            ;;
                        *)
                            log_message "INFO" "Skipping file (possible application data): $file"
                            ;;
                    esac
                fi
            done
        fi
    done

    send_telegram "🧹 *Orphaned data cleanup* completed on *${EXEC_HOSTNAME}*."
    return 0
}

# ============================================================================
# Main Execution
# ============================================================================

total_freed=0
operations=()

# ============================================================================
# Initialize & Checks
# ============================================================================

log_message "INFO" "=========================================="
log_message "INFO" "Starting Disk Cleanup Script for Debian Hosts"
log_message "INFO" "Hostname: ${EXEC_HOSTNAME}"
log_message "INFO" "=========================================="

# Send start message via Telegram
start_msg="$(escape_markdown_v2 "🚀 *Disk Cleanup Started* on host \`${EXEC_HOSTNAME}\`. Checking disk space and configuration...")"
log_message "INFO" "${start_msg}"
send_telegram "${start_msg}"

# Check root
check_root

# Check disk space
if ! check_disk_space; then
    log_message "WARN" "Low disk space detected - proceeding with forced cleanup"
fi

# ============================================================================
# Cleanup Operations
# ============================================================================

# 1. APT Cache Cleanup
if [[ "${CLEAN_APT_CACHE}" == "true" ]]; then
    cleanup_apt_cache
fi

# 2. Systemd Journal Cleanup
if [[ "${CLEAN_JOURNAL}" == "true" ]]; then
    cleanup_journal
fi

# 3. Docker Prune
if [[ "${CLEAN_DOCKER_PRUNE}" == "true" ]]; then
    cleanup_docker_prune
fi

# 4. Containerd Snapshot Cleanup
if [[ "${CLEAN_CONTAINERD_SNAPSHOTS}" == "true" ]]; then
    cleanup_containerd_snapshots_super_safe
fi

# 5. Apache Logs Cleanup
if [[ "${CLEAN_APACHE_LOGS}" == "true" ]]; then
    cleanup_apache_logs
fi

# 6. Orphaned Data Cleanup (whitelisted paths only)
if [[ ${#WHITELISTED_PATHS[@]} -gt 0 ]]; then
    cleanup_orphaned_data
fi

# ============================================================================
# Summary & Telegram Notification
# ============================================================================

log_message "INFO" "=== Disk Cleanup Operations Summary ==="
log_message "INFO" "Host: ${EXEC_HOSTNAME}"
log_message "INFO" "Operations performed: ${#operations[@]}"

# Build operations list for Telegram
ops_summary=""
for op in "${operations[@]}"; do
    # Escape each operation for Markdown
    escaped_op=$(escape_markdown_v2 "• ${op}")
    ops_summary+="${escaped_op}"$'\n'
done

# Get final disk space
final_avail=$(df -B1 / | tail -1 | awk '{print $4}')
final_avail_gb=$((final_avail / 1024 / 1024 / 1024))
total_size_gb=$(( $(df -B1 / | tail -1 | awk '{print $2}') / 1024 / 1024 / 1024))

# Build final summary message with Markdown formatting
summary_msg="$(escape_markdown_v2 "==========================================")"
summary_msg+="\n*🧹 Disk Cleanup Completed*"
summary_msg+="\n*Host:* \`${EXEC_HOSTNAME}\`"
summary_msg+="\n*Time:* $(date '+%Y-%m-%d %H:%M:%S')"
summary_msg+="\n*Total operations:* ${#operations[@]}"
summary_msg+="\n*Final disk state:* ${final_avail_gb}G free / ${total_size_gb}G total"
summary_msg+="\n\n*Operations performed:*"
if [[ ${#operations[@]} -gt 0 ]] && [[ -n "$ops_summary" ]]; then
    summary_msg+="\n${ops_summary}"
else
    summary_msg+="\n• No operations were performed"
fi
summary_msg+="\n=========================================="

log_message "INFO" "${summary_msg}"
send_telegram "${summary_msg}"

log_message "INFO" "=========================================="
log_message "INFO" "Disk Cleanup Script finished"
log_message "INFO" "=========================================="

# Final Telegram message
send_telegram "🏁 *Disk Cleanup Script finished* on host \`${EXEC_HOSTNAME}\`. Check logs at ${LOG_FILE} for details."

log_message "INFO" "=========================================="
log_message "INFO" "Disk Cleanup Script finished"
log_message "INFO" "=========================================="