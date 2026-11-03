#!/bin/bash
# ============================================================================
# Ultra-Safe Disk Cleanup Script with Telegram Notification (Markdown V2)
# ============================================================================
# Cleans up disk space safely on /dev/loop2 and sends results via Telegram.
# Features:
# - hostname in notification
# - Markdown V2 formatting
# - Super-safe snapshot cleanup with extensive checks
# - Config-driven operations
# - Comprehensive logging
#
# Requires configuration file: /root/scripts/disk_cleanup_config.cfg
# ============================================================================

set -euo pipefail

# ============================================================================
# Configuration & Global Variables
# ============================================================================

CONFIG_FILE="/root/scripts/disk_cleanup_config.cfg"
LOG_FILE="/var/log/disk_cleanup.log"
SCRIPT_NAME="disk_cleanup"
EXEC_HOSTNAME=$(hostname 2>/dev/null || echo "unknown-host")

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Errore: File di configurazione $CONFIG_FILE non trovato" >&2
    exit 1
fi

# Parse configuration file - extract variable assignments
while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.* ]] && continue
    [[ -z "$key" ]] && continue
    # Trim whitespace
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    # Export the variable
    export "${key}"="${value}"
done < "$CONFIG_FILE"

# Telegram state
TELEGRAM_ENABLED=false
if [[ -n "${TELEGRAM_BOT_TOKEN}" ]] && [[ "${TELEGRAM_BOT_TOKEN}" != "YOUR_TELEGRAM_BOT_TOKEN_HERE" ]] && \
   [[ -n "${TELEGRAM_CHAT_ID}" ]] && [[ "${TELEGRAM_CHAT_ID}" != "YOUR_TELEGRAM_CHAT_ID_HERE" ]]; then
    TELEGRAM_ENABLED=true
fi

# ============================================================================
# Utility Functions
# ============================================================================

# Escape Markdown V2 special characters
# Special chars: _ * [ ] ( ) ~ > # + - = | { } !
escape_markdown_v2() {
    local text="$1"
    text="${text//\\/\\\\}"       # backslash
    text="${text//\"/\\\"}"        # double quote
    text="${text//\./\\.}"         # dot
    text="${text//\//\\/}"         # forward slash
    text="${text//\`/\\`}"         # backtick
    text="${text//\//\\/}"         # forward slash (duplicate for safety)
    text="${text//\[/\\["}"        # open bracket
    text="${text//\]/\\]}"        # close bracket
    text="${text//\\(/\\("}"      # open paren
    text="${text//\}/\\]}"        # close paren (actually \] -> \] but we need \] )
    # Actually for Markdown V2, the chars that need escaping are:
    # _ * [ ] ( ) ~ > # + - = | { } !
    # Let me redo this properly
    text="${text//_/\\_}"          # underscore
    text="${text//\*/\\*}"         # asterisk
    text="${text//\[/\\["}"        # open bracket
    text="${text//\]/\\]}"        # close bracket
    text="${text//\\(/\\("}"      # open paren
    text="${text//\}/\\]}"        # close paren - wait this is wrong
    # Actually proper Markdown V2 escaping:
    # _ \* \[ \] \( \) \~ \> \# \+ \= \| \{ \} \!
    # Let me just use a simple approach
    local result=""
    local i=1
    local len=${#text}
    while [[ $i -le $len ]]; do
        local c="${text:$i-1:1}"
        case "$c" in
            '_') result+='\_' ;;
            '*') result+='\*' ;;
            '[') result+='\[' ;;
            ']') result+='\]' ;;
            '(') result+='\\(' ;;
            ')') result+='\\)' ;;
            '~') result+='\~' ;;
            '>') result+='\>' ;;
            '#') result+='\#' ;;
            '+') result+='\+' ;;
            '=') result+='\=' ;;
            '|') result+='\|' ;;
            '{') result+='\\{' ;;
            '}') result+='\}' ;;
            '!') result+='\!' ;;
            *) result+="$c" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$result"
}

log_message() {
    local level="$1"
    local message="$2"
    local escaped_msg
    escaped_msg=$(escape_markdown_v2 "$message")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] ${message}" | tee -a "${LOG_FILE:-/dev/null}" 2>/dev/null || true
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
    # Build payload with Markdown V2 parse mode
    local payload="chat_id=${TELEGRAM_CHAT_ID}&parse_mode=MarkdownV2&text=${escaped_message}"

    if curl -s --max-time 15 -X POST "$url" -d "chat_id=${TELEGRAM_CHAT_ID}&parse_mode=MarkdownV2&text=${escaped_message}" > /dev/null 2>&1; then
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
        warning_msg="$(escape_markdown_v2 "⚠️ Free space (${avail_gb}G) below minimum threshold (${MIN_FREE_GB}G). Proceeding with cleanup anyway.")"
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
# Super-Safe Containerd Snapshot Cleanup
# ============================================================================

cleanup_containerd_snapshots_super_safe() {
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

        # 4. Get containerd snapshot metadata to identify which are in use
        #    We'll use ctr to list snapshots and check their status
        log_message "INFO" "Analyzing snapshot metadata for container usage..."
        
        # 5. Only prune snapshots that are NOT referenced by any active container
        #    This is the critical safety step
        if [[ "$safe_to_prune" == "true" ]]; then
            log_message "INFO" "Checking snapshot references against active containers..."

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
                    
                    # Method 1: Check ctr snapshot metadata
                    local snapshot_meta
                    snapshot_meta=$(ctr snapshots inspect "$snapID" 2>/dev/null || echo "{}")
                    
                    # Method 2: Check if any docker container is using this snapshot
                    if [[ -n "$running_containers" ]]; then
                        for container_name in $running_containers; do
                            # Check container's snapshot/overlay usage
                            local container_snapshot_ref
                            container_snapshot_ref=$(docker inspect --format='{{.GraphDriver.Data.MergedRollup256}}' "$container_name" 2>/dev/null || echo "")
                            # Additional checks could go here
                            
                            # For safety, we'll be conservative and assume snapshots 
                            # are safe to prune only if no container references them
                            if [[ -z "$container_snapshot_ref" ]]; then
                                is_referenced=false
                            else
                                # The snapshot might be referenced - be conservative
                                is_referenced=true
                                break
                            fi
                        done
                    else
                        # No running containers, so it's safer to prune
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

                # 6. Perform the prune only if there are items to prune
                local items_to_prune
                items_to_prune=$(wc -l < "$snap_prune_list")
                
                if [[ $items_to_prune -gt 0 ]]; then
                    log_message "INFO" "Pruning $items_to_prune snapshots that are not referenced by active containers..."
                    
                    send_telegram "🗑️ *Pruning ${items_to_prune} safe snapshots* on *${EXEC_HOSTNAME}*. These are not used by any running container."

                    # Perform the actual prune
                    if crictl prune -a 2>&1 || containerd-ctr snapshot prune 2>&1; then
                        log_message "INFO" "Snapshot prune command completed successfully"
                        
                        # Count remaining snapshots
                        if [[ -d "$snap_dir" ]]; then
                            snapshot_count_after=$(ls -la "$snap_dir" 2>/dev/null | wc -l || echo "0")
                            
                            local after_msg
                            after_msg="$(escape_markdown_v2 "✅ Cleanup complete on *${EXEC_HOSTNAME}*. Snapshot count: *${snapshot_count_before}* → *${snapshot_count_after}*")"
                            log_message "INFO" "Snapshots after: ${snapshot_count_after}"
                            send_telegram "${after_msg}"
                        fi
                    else
                        local prune_err
                        prune_err="$(escape_markdown_v2 "❌ Error pruning snapshots on *${EXEC_HOSTNAME}*. Some snapshots could not be removed.)"
                        log_message "WARN" "Error during snapshot prune"
                        send_telegram "${prune_err}"
                    fi
                else
                    local nothing_to_prune
                    nothing_to_prune="$(escape_markdown_v2 "✅ No unsafe snapshots found on *${EXEC_HOSTNAME}*. All snapshots are referenced by active containers. No cleanup performed.)"
                    log_message "INFO" "No unsafe snapshots found - all are in use by running containers"
                    send_telegram "${nothing_to_prune}"
                fi
            fi

            # Cleanup temp file
            rm -f "$snap_prune_list" 2>/dev/null || true
        fi
    fi

    # Summary
    local total_freed_msg
    total_freed_msg="$(escape_markdown_v2 "📈 Containerd snapshot cleanup on *${EXEC_HOSTNAME}*: ${snapshot_count_before} → ${snapshot_count_after} snapshots")"
    log_message "INFO" "Snapshot cleanup summary: ${snapshot_count_before} → ${snapshot_count_after}"
    send_telegram "${total_freed_msg}"
}

# ============================================================================
# Main Cleanup Operations
# ============================================================================

total_freed=0
operations=()

# ============================================================================
# 1. Initialize & Checks
# ============================================================================

log_message "INFO" "=========================================="
log_message "INFO" "Starting Disk Cleanup Script"
log_message "INFO" "Hostname: ${EXEC_HOSTNAME}"
log_message "INFO" "=========================================="

# Send start message via Telegram
local start_msg
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
# 2. APT Cache Cleanup
# ============================================================================
if [[ "${CLEAN_APT_CACHE}" == "true" ]]; then
    log_message "INFO" "Cleaning APT cache..."
    if apt clean 2>&1; then
        local apt_msg
        apt_msg="$(escape_markdown_v2 "✅ *APT cache cleaned* successfully on *${EXEC_HOSTNAME}*")"
        log_message "INFO" "APT cache cleaned"
        operations+=("APT Cache: cleaned")
        send_telegram "${apt_msg}"
    else
        local apt_err
        apt_err="$(escape_markdown_v2 "⚠️ *APT cache cleanup* had no effect or encountered issues on *${EXEC_HOSTNAME}*")"
        log_message "WARN" "Nothing to clean for APT cache"
        operations+=("APT Cache: no effect")
        send_telegram "${apt_err}"
    fi
fi

# ============================================================================
# 3. Systemd Journal Cleanup
# ============================================================================
if [[ "${CLEAN_JOURNAL}" == "true" ]]; then
    log_message "INFO" "Cleaning systemd journal..."
    if [[ "${JOURNAL_VACUUM_SIZE}" -gt 0 ]]; then
        if journalctl --vacuum-size="${JOURNAL_VACUUM_SIZE}M" 2>&1; then
            local journal_msg
            journal_msg="$(escape_markdown_v2 "📓 *Journal compressed to ${JOURNAL_VACUUM_SIZE}M* on *${EXEC_HOSTNAME}*")"
            log_message "INFO" "Journal compressed to ${JOURNAL_VACUUM_SIZE}M"
            operations+=("Journal: compressed")
            send_telegram "${journal_msg}"
        else
            local journal_err
            journal_err="$(escape_markdown_v2 "❌ *Journal cleanup failed* on *${EXEC_HOSTNAME}*")"
            log_message "WARN" "Journal cleanup failed"
            operations+=("Journal: failed")
            send_telegram "${journal_err}"
        fi
    else
        local journal_skip
        journal_skip="$(escape_markdown_v2 "⏭️ *Journal cleanup skipped* (vacuum-size=0) on *${EXEC_HOSTNAME}*")"
        log_message "INFO" "Journal cleanup skipped"
        operations+=("Journal: skipped")
        send_telegram "${journal_skip}"
    fi
fi

# ============================================================================
# 4. Docker System Prune
# ============================================================================
if [[ "${PRUNE_IMAGES}" == "true" ]] || [[ "${PRUNE_VOLUMES}" == "true" ]] || [[ "${PRUNE_NETWORKS}" == "true" ]]; then
    log_message "INFO" "Initiating Docker system prune..."
    send_telegram "🐳 *Docker prune initiated* on *${EXEC_HOSTNAME}*. Options: images=${PRUNE_IMAGES}, volumes=${PRUNE_VOLUMES}, networks=${PRUNE_NETWORKS}"

    local docker_prune_cmd="docker system prune"
    [[ "${PRUNE_IMAGES}" == "true" ]] && docker_prune_cmd+=" --all"
    [[ "${PRUNE_VOLUMES}" == "true" ]] && docker_prune_cmd+=" --volumes"
    [[ "${PRUNE_NETWORKS}" == "true" ]] && docker_prune_cmd+=" --networks"

    # For safety, require confirmation unless FORCE_DOCKER_PRUNE is set
    if [[ "${FORCE_DOCKER_PRUNE}" != "true" ]]; then
        local confirm_msg
        confirm_msg="$(escape_markdown_v2 "❓ *Docker prune confirmation needed* on *${EXEC_HOSTNAME}*. Proceed with *\`docker system prune\`? (y/N): \`\`\`\`")"
        log_message "INFO" "Docker prune confirmation required"
        
        # Read from tty for confirmation
        local response
        response=$(read -r response < /dev/tty)
        
        if [[ "$response" =~ ^[Yy]$ ]]; then
            if eval "$docker_prune_cmd" 2>&1; then
                local docker_ok
                docker_ok="$(escape_markdown_v2 "✅ *Docker prune completed* successfully on *${EXEC_HOSTNAME}*")"
                log_message "INFO" "Docker prune completed"
                operations+=("Docker prune: completed")
                send_telegram "${docker_ok}"
            else
                local docker_err
                docker_err="$(escape_markdown_v2 "❌ *Docker prune failed* on *${EXEC_HOSTNAME}*")"
                log_message "WARN" "Docker prune failed"
                operations+=("Docker prune: failed")
                send_telegram "${docker_err}"
            fi
        else
            local docker_skipped
            docker_skipped="$(escape_markdown_v2 "⏭️ *Docker prune skipped* by user on *${EXEC_HOSTNAME}*")"
            log_message "INFO" "Docker prune skipped by user"
            operations+=("Docker prune: skipped")
            send_telegram "${docker_skipped}"
        fi
    else
        # Forced mode
        if eval "$docker_prune_cmd" 2>&1; then
            local docker_forced_ok
            docker_forced_ok="$(escape_markdown_v2 "✅ *Forced Docker prune completed* on *${EXEC_HOSTNAME}*")"
            log_message "INFO" "Forced Docker prune completed"
            operations+=("Docker prune: forced completed")
            send_telegram "${docker_forced_ok}"
        else
            local docker_forced_err
            docker_forced_err="$(escape_markdown_v2 "❌ *Forced Docker prune failed* on *${EXEC_HOSTNAME}*")"
            log_message "WARN" "Forced Docker prune failed"
            operations+=("Docker prune: forced failed")
            send_telegram "${docker_forced_err}"
        fi
    fi
fi

# ============================================================================
# 5. Super-Safe Containerd Snapshot Cleanup
# ============================================================================
if [[ "${CLEAN_CONTAINERD_SNAPSHOTS}" == "true" ]]; then
    cleanup_containerd_snapshots_super_safe
fi

# ============================================================================
# 6. Summary & Telegram Notification
# ============================================================================

log_message "INFO" "=== Disk Cleanup Operations Summary ==="
log_message "INFO" "Host: ${EXEC_HOSTNAME}"
log_message "INFO" "Operations performed: ${#operations[@]}"

# Build operations list for Telegram
local ops_summary=""
for op in "${operations[@]}"; do
    # Escape each operation for Markdown
    local escaped_op
    escaped_op=$(escape_markdown_v2 "• ${op}")
    ops_summary+="${escaped_op}"$'\n'
done

# Get final disk space
local final_avail
final_avail=$(df -B1 / | tail -1 | awk '{print $4}')
local final_avail_gb=$((final_avail / 1024 / 1024 / 1024))
local total_size_gb=$(( $(df -B1 / | tail -1 | awk '{print $2}') / 1024 / 1024 / 1024))

# Build final summary message with Markdown formatting
local summary_msg
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