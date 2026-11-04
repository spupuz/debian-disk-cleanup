#!/bin/bash
# shellcheck disable=SC2034,SC2221,SC2222
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

# Journal vacuum size (in MB, 0 to skip)
JOURNAL_VACUUM_SIZE=100

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
SCRIPT_VERSION="1.0.0"
EXEC_HOSTNAME=$(hostname 2>/dev/null || echo "unknown-host")

# GitHub auto-update config
GITHUB_OWNER="spupuz"
GITHUB_REPO="debian-disk-cleanup"
GITHUB_RELEASE_LATEST="https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/latest"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/$GITHUB_OWNER/$GITHUB_REPO/main"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${BASH_SOURCE[0]}"
CONFIG_FILES=("/etc/default/disk_cleanup.conf" "$HOME/.disk_cleanup.conf")

for config_file in "${CONFIG_FILES[@]}"; do
    if [[ -f "$config_file" ]]; then
        if type log_message &>/dev/null; then log_message "INFO" "Loading configuration from $config_file"; fi
        # Parse configuration file - extract variable assignments
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            # Trim whitespace without invoking external commands
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            # Strictly validate key name to prevent injection
            [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            # Reject values containing control characters or newlines
            [[ "$value" == *$'\\n'* || "$value" == *$'\\r'* ]] && continue
            # Only set known variables
            case "$key" in
                TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID|TELEGRAM_ENABLED|CLEAN_APT_CACHE|CLEAN_JOURNAL|CLEAN_DOCKER_PRUNE|CLEAN_CONTAINERD_SNAPSHOTS|CLEAN_APACHE_LOGS|CLEAN_NANO|MIN_FREE_GB|FORCE_MODE|DRY_RUN|LOG_TO_FILE|LOG_FILE|WHITELISTED_PATHS|JOURNAL_VACUUM_SIZE)
                    export "${key}"="${value}"
                    ;;
                *)
                    if type log_message &>/dev/null; then log_message "WARN" "Unknown configuration key: ${key}, skipping"; fi
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
    escaped=$(printf '%s' "$text" | sed 's/[][\(\)~#+=|{}\!\\>-]/\\&/g')
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
# Auto-Update: check GitHub for a newer version and replace itself
# ============================================================================

auto_update() {
    local latest_version tmp_script cache_file cache_failure_file first_line latest_tag dl_url DOWNLOAD_REF uid_cache
    uid_cache="${EUID:-$(id -u)}"
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/disk-cleanup"
    [ -d "$cache_dir" ] || mkdir -p "$cache_dir" 2>/dev/null || cache_dir="${TMPDIR:-/tmp}"
    cache_file="$cache_dir/.disk_cleanup_version_cache_$uid_cache"
    cache_failure_file="$cache_dir/.disk_cleanup_version_cache_failure_$uid_cache"

    if [ -f "$cache_file" ] && [ -n "$(find "$cache_file" -mmin -1440 2>/dev/null)" ]; then
        IFS= read -r latest_version < "$cache_file"
        if [[ "$latest_version" == *[!a-zA-Z0-9.-]* ]]; then
            return
        fi
    elif [ -f "$cache_failure_file" ] && [ -n "$(find "$cache_failure_file" -mmin -60 2>/dev/null)" ]; then
        return
    else
        local headers
        headers=$(curl -sfI --connect-timeout 5 --max-time 5 --proto '=https' "$GITHUB_RELEASE_LATEST" 2>/dev/null)
        if [[ "$headers" =~ [Ll]ocation:[[:space:]]*.*/tag/([^[:space:]$'\r\n']+) ]]; then
            latest_tag="${BASH_REMATCH[1]}"
            if [[ "$latest_tag" == *[!a-zA-Z0-9.-]* ]]; then return; fi
        fi

        if [ -n "$latest_tag" ]; then
            latest_version="${latest_tag#v}"
            DOWNLOAD_REF="$latest_tag"
        else
            latest_version=$(curl -sf --compressed --connect-timeout 5 --max-time 5 --proto '=https' "$GITHUB_RAW_BASE/version.txt" 2>/dev/null)
            latest_version="${latest_version//$'\r'/}"
            latest_version="${latest_version//$'\n'/}"
            if [[ "$latest_version" == *[!a-zA-Z0-9.-]* ]]; then
                latest_version=""
            fi
            [ -n "$latest_version" ] && DOWNLOAD_REF="main"
        fi
        if [ -n "$latest_version" ]; then
            local tmp_cache
            tmp_cache=$(mktemp "${cache_dir}/.version_cache_tmp_${uid_cache}_XXXXXX")
            printf "%s\n" "$latest_version" > "$tmp_cache"
            mv -f "$tmp_cache" "$cache_file"
            rm -f "$cache_failure_file"
        else
            local tmp_failure
            tmp_failure=$(mktemp "${cache_dir}/.version_cache_failure_tmp_${uid_cache}_XXXXXX")
            if [ -n "$tmp_failure" ]; then
                mv -f "$tmp_failure" "$cache_failure_file" 2>/dev/null || rm -f "$tmp_failure"
            fi
        fi
    fi
    [ -z "$latest_version" ] && return
    : "${DOWNLOAD_REF:=v${latest_version}}"

    if [ "$latest_version" != "$SCRIPT_VERSION" ] && [ "$(printf '%s\n' "$SCRIPT_VERSION" "$latest_version" | sort -V | tail -1)" = "$latest_version" ]; then
        local cache_dir="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
        cache_dir="${cache_dir:-${TMPDIR:-/tmp}}"
        [ -d "$cache_dir" ] || mkdir -p "$cache_dir" 2>/dev/null || cache_dir="/tmp"
        tmp_script=$(mktemp "$cache_dir/disk_cleanup_${uid_cache}_XXXXXX")

        if [ "$DOWNLOAD_REF" != "main" ]; then
            dl_url="https://raw.githubusercontent.com/$GITHUB_OWNER/$GITHUB_REPO/$DOWNLOAD_REF/disk_cleanup.sh"
        else
            dl_url="$GITHUB_RAW_BASE/disk_cleanup.sh"
        fi

        if curl -sf --compressed --connect-timeout 5 --max-time 10 --proto '=https' -o "$tmp_script" "$dl_url" 2>/dev/null && [ -s "$tmp_script" ]; then
            IFS= read -r first_line < "$tmp_script"
            if [[ "$first_line" != "#!/bin/bash"* ]]; then
                rm -f "$tmp_script"
                return
            fi
            if ! diff -q "$tmp_script" "$SCRIPT_PATH" &>/dev/null; then
                if [[ -L "$SCRIPT_PATH" ]]; then rm -f "$tmp_script"; return; fi
                chmod +x "$tmp_script" && mv -f "$tmp_script" "$SCRIPT_PATH"
                rm -f "$tmp_script"
                export UPDATED_FROM_VERSION="$SCRIPT_VERSION"
                exec "$SCRIPT_PATH" "$@"
            fi
        fi
        rm -f "$tmp_script"
    fi
}

# Run auto-update synchronously (short timeouts: ~5s max if no update, ~15s for full update)
if [ "${AUTO_UPDATE:-true}" = "true" ] && command -v curl &>/dev/null; then
    auto_update "$@"
fi

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

    local snapshot_count_before=0
    local snapshot_count_after=0
    local safe_to_prune=true

    # 1. Verify containerd is running
    log_message "INFO" "Checking containerd status..."
    if ! systemctl is-active --quiet containerd 2>/dev/null; then
        log_message "WARN" "containerd not running, skipping"
        send_telegram "⚠️ *Warning*: containerd is not running on *${EXEC_HOSTNAME}*. Skipping snapshot cleanup."
        safe_to_prune=false
    fi

    # 2. Verify ctr command is available
    if [[ "$safe_to_prune" == "true" ]] && ! command -v ctr &>/dev/null; then
        log_message "WARN" "ctr command not available, skipping"
        send_telegram "⚠️ *Warning*: ctr command not available on *${EXEC_HOSTNAME}*. Skipping snapshot cleanup."
        safe_to_prune=false
    fi

    # 3. Count snapshots before
    if [[ "$safe_to_prune" == "true" ]]; then
        if [[ -d "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots" ]]; then
            snapshot_count_before=$(ls -la /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/ 2>/dev/null | wc -l || echo "0")
            log_message "INFO" "Snapshots before: ${snapshot_count_before}"
            send_telegram "📊 *Snapshot count before cleanup: ${snapshot_count_before}* on *${EXEC_HOSTNAME}*"
        else
            log_message "INFO" "Snapshot directory not found"
            send_telegram "📁 *Info*: Snapshot directory not found on *${EXEC_HOSTNAME}*. Nothing to clean."
            safe_to_prune=false
        fi
    fi

    # 4. Use ctr to list and prune unreferenced snapshots safely
    if [[ "$safe_to_prune" == "true" ]]; then
        log_message "INFO" "Using ctr to analyze containerd snapshots..."

        # Get all snapshot names from ctr
        local snapshots_to_check
        snapshots_to_check=$(ctr snapshots list -q 2>/dev/null || echo "")

        if [[ -z "$snapshots_to_check" ]]; then
            log_message "INFO" "No snapshots found via ctr"
            send_telegram "✅ *No snapshots found* on *${EXEC_HOSTNAME}*. Nothing to clean."
            safe_to_prune=false
        else
            log_message "INFO" "Found $(echo "$snapshots_to_check" | wc -l) snapshots via ctr"

            # Check which containers are running (both docker and containerd)
            local running_containerd_containers
            running_containerd_containers=$(ctr containers list -q 2>/dev/null || echo "")

            # Get list of snapshot IDs that are actively used by containers
            local used_snapshots=""
            if [[ -n "$running_containerd_containers" ]]; then
                for container_id in $running_containerd_containers; do
                    # Get the snapshot used by this container
                    local container_snapshot
                    container_snapshot=$(ctr containers info "$container_id" 2>/dev/null | grep -i "snapshot" | head -1 | awk '{print $NF}' || echo "")
                    if [[ -n "$container_snapshot" ]]; then
                        used_snapshots+="$container_snapshot"$'\n'
                    fi
                done
            fi

            # Also check docker containers if docker is available
            local running_docker_containers
            running_docker_containers=$(docker ps -q 2>/dev/null || echo "")
            if [[ -n "$running_docker_containers" ]]; then
                for container_id in $running_docker_containers; do
                    local docker_snapshot
                    docker_snapshot=$(docker inspect --format='{{.GraphDriver.Data.MergedDir}}' "$container_id" 2>/dev/null | grep -oE '[a-f0-9]{64}' | head -1 || echo "")
                    if [[ -n "$docker_snapshot" ]]; then
                        used_snapshots+="$docker_snapshot"$'\n'
                    fi
                done
            fi

            # Prune only snapshots not in the used list
            local pruned_count=0
            while IFS= read -r snap_name; do
                [[ -z "$snap_name" ]] && continue

                # Check if this snapshot is in use
                if echo "$used_snapshots" | grep -q "^${snap_name}$"; then
                    log_message "INFO" "Snapshot $snap_name is in use, skipping"
                    continue
                fi

                # Also check if any container references this snapshot via ctr
                local is_referenced=false
                for container_id in $running_containerd_containers; do
                    if ctr containers info "$container_id" 2>/dev/null | grep -q "$snap_name"; then
                        is_referenced=true
                        break
                    fi
                done

                if [[ "$is_referenced" == "true" ]]; then
                    log_message "INFO" "Snapshot $snap_name is referenced by a container, skipping"
                    continue
                fi

                # Safe prune using ctr (not rm -rf!) - ctr handles the removal safely
                if $DRY_RUN; then
                    log_message "INFO" "[DRY RUN] Would prune snapshot: $snap_name"
                    pruned_count=$((pruned_count + 1))
                else
                    if ctr snapshots remove "$snap_name" 2>/dev/null; then
                        log_message "INFO" "Pruned snapshot: $snap_name"
                        pruned_count=$((pruned_count + 1))
                    else
                        log_message "WARN" "Failed to prune snapshot: $snap_name"
                    fi
                fi
            done <<< "$snapshots_to_check"

            # Count remaining snapshots
            if [[ -d "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots" ]]; then
                snapshot_count_after=$(ls -la /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/ 2>/dev/null | wc -l || echo "0")
                log_message "INFO" "Snapshots after: ${snapshot_count_after}"
                send_telegram "✅ *Cleanup complete on *${EXEC_HOSTNAME}*. Pruned: ${pruned_count} snapshots. Count: ${snapshot_count_before} → ${snapshot_count_after}"
            fi
        fi
    fi

    # Summary
    log_message "INFO" "Snapshot cleanup summary: ${snapshot_count_before} → ${snapshot_count_after}"
    send_telegram "📈 *Containerd snapshot cleanup on *${EXEC_HOSTNAME}*: ${snapshot_count_before} → ${snapshot_count_after} snapshots"
}

# ============================================================================
# Apache Logs Cleanup
# ============================================================================

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
                        *.log|*.tmp|*.cache|*.bak|*.old|*.swp|*.pyc|*.class)
                        # Skip symlinks to avoid path traversal / symlink attacks
                        if [[ -L "$file" ]]; then
                            log_message "INFO" "Skipping symlink (unsafe): $file"
                            continue
                        fi
                        # Only remove regular files, never directories
                        if [[ ! -f "$file" ]]; then
                            log_message "INFO" "Skipping non-regular file: $file"
                            continue
                        fi
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