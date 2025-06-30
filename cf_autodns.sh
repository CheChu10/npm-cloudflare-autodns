#!/usr/bin/env bash

# ==============================================================================
# Cloudflare Auto-DNS for Nginx Proxy Manager (Final Version)
# ==============================================================================
#
# Description:
# This script monitors a directory of Nginx Proxy Manager configurations
# and automatically manages Cloudflare CNAME records. It is designed
# to run as a robust and secure systemd daemon.
#
# Architecture and Key Features:
#
# 1.  GUARANTEED SINGLETON (Atomicity):
#     - The script uses `flock` on a file descriptor to ensure only one
#       instance can run at a time. It's inherently atomic and safe against
#       multiple executions, and provides a clear error message if a second
#       instance is attempted.
#
# 2.  RACE CONDITION PREVENTION (Per-File Locking):
#     - It employs an atomic `mkdir` lock system for each configuration file.
#       This prevents bursts of `inotify` events from launching duplicate
#       processing jobs for the same file.
#
# 3.  INTELLIGENT EVENT HANDLING (Debouncing):
#     - Ignores redundant events while a file is being processed.
#     - It intelligently distinguishes between a real deletion and an atomic
#       save (delete + recreate) via a strategic pause, preventing
#       unnecessary DNS cleanups.
#
# 4.  IDEMPOTENCY AND EFFICIENCY:
#     - Calculates a hash of the domains within each file. It only contacts
#       the Cloudflare API if the relevant content has actually changed.
#
# 5.  SECURE BY DESIGN:
#     - The API token (`CF_API_TOKEN`) is loaded exclusively from an environment
#       variable, keeping secrets out of the code. Designed to be securely
#       injected by systemd.
#
# ==============================================================================

set -euo pipefail

# --- Global Lock Mechanism (Singleton) ---
# Uses flock on a file descriptor to ensure that only one instance of the script
# is running. The lock is automatically released when the script exits.
# It will fail with an error message if a re-execution is attempted.
exec 200>"/tmp/cf_autodns.lock"
flock -n 200 || { echo "[ERROR] Another instance of the script is already running. Aborting." >&2; exit 1; }

# --- Configuration & Validation (from Environment Variables) ---
# These variables MUST be set for the script to run.
# BASE_DIR:     The script's working directory for state files (hashes, locks).
# WATCH_DIR:    The directory where Nginx Proxy Manager stores its .conf files.
# CF_API_TOKEN: Your Cloudflare API token for authentication.

if [[ -z "${BASE_DIR:-}" ]]; then
    echo "[ERROR] Configuration error: BASE_DIR is not set. Please set it as an environment variable." >&2
    exit 1
fi
if [[ -z "${WATCH_DIR:-}" ]]; then
    echo "[ERROR] Configuration error: WATCH_DIR is not set. Please set it as an environment variable." >&2
    exit 1
fi
if [[ -z "${CF_API_TOKEN:-}" ]]; then
    echo "[ERROR] Configuration error: CF_API_TOKEN is not set. Please set it as an environment variable." >&2
    exit 1
fi

# Optional environment variable for debug mode
DEBUG_MODE="${DEBUG_MODE:-false}"

# --- Derived Variables ---
HASH_DIR="$BASE_DIR/hashes"
LOCK_DIR="$BASE_DIR/locks"

# --- Prerequisites ---
# Check that the required tools (jq, curl, inotifywait) are installed.
command -v jq >/dev/null 2>&1 || { echo "Error: 'jq' is not installed. Please install it."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: 'curl' is not installed. Please install it."; exit 1; }
command -v inotifywait >/dev/null 2>&1 || { echo "Error: 'inotifywait' is not installed. Please install it."; exit 1; }

# --- Core Functions ---

log() {
    local type="$1"; shift
    # Don't print DEBUG messages if DEBUG_MODE is not true
    if [[ "$type" == "DEBUG" && "$DEBUG_MODE" != "true" ]]; then
        return
    fi
    
    local pid="$BASHPID"
    local emoji=""
    case "$type" in
        INFO)  emoji="ℹ️" ;;
        OK)    emoji="✅" ;;
        SKIP)  emoji="⏭️" ;;
        WARN)  emoji="⚠️" ;;
        ERROR) emoji="❌" ;;
        LOCK)  emoji="🔒" ;;
        API)   emoji="☁️" ;;
        DEBUG) emoji="🐞" ;;
    esac
    printf '[%s] [%s] [%s] %s\n' "$(date +'%F %T')" "$pid" "$emoji $type" "$*"
}

cf_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="https://api.cloudflare.com/client/v4/$endpoint"
    log API "Call: $method $url"

    local response
    if [[ -n "$data" ]]; then
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" --data "$data")
    else
        response=$(curl -s -X "$method" "$url" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json")
    fi

    if ! echo "$response" | jq -e '.success' >/dev/null; then
        log ERROR "Cloudflare API call failed. Endpoint: $endpoint. Response: $(echo "$response" | jq -c '.errors')"
        return 1
    fi

    echo "$response"
}

process_file_logic() {
    local file_path="$1"
    local filename
    filename=$(basename "$file_path")

    declare -A ZONE_ID_CACHE
    declare -A ZONE_RECORDS_CACHE

    get_zone_id() {
        local root_domain="$1"
        if [[ -n "${ZONE_ID_CACHE[$root_domain]:-}" ]]; then
            log DEBUG "($filename) Using cached zone_id for $root_domain: ${ZONE_ID_CACHE[$root_domain]}"
            echo "${ZONE_ID_CACHE[$root_domain]}"
            return
        fi
        log DEBUG "($filename) Querying zone_id for $root_domain"
        local response
        response=$(cf_api_call "GET" "zones?name=$root_domain&status=active") || return 1
        local zone_id
        zone_id=$(echo "$response" | jq -r '.result[0].id')
        if [[ -z "$zone_id" || "$zone_id" == "null" ]]; then
            log ERROR "($filename) Zone not found for root domain: $root_domain"
            return 1
        fi
        ZONE_ID_CACHE["$root_domain"]="$zone_id"
        echo "$zone_id"
    }

    load_dns_records_for_zone() {
        local zone_id="$1"
        if [[ -z "$zone_id" ]]; then return 1; fi
        if [[ -n "${ZONE_RECORDS_CACHE[$zone_id]:-}" ]]; then return 0; fi
        log DEBUG "($filename) Loading CNAME records for zone_id=$zone_id"
        local response
        response=$(cf_api_call "GET" "zones/$zone_id/dns_records?type=CNAME&per_page=5000") || return 1
        ZONE_RECORDS_CACHE["$zone_id"]=$(echo "$response" | jq -c '.result')
        log DEBUG "($filename) Loaded and cached $(echo "${ZONE_RECORDS_CACHE[$zone_id]}" | jq '. | length') records"
    }

    get_record_id_from_cache() {
        local zone_id="$1"
        local domain_name="$2"
        echo "${ZONE_RECORDS_CACHE[$zone_id]}" | jq -r --arg name "$domain_name" '.[] | select(.name == $name) | .id'
    }

    run_update() {
        log INFO "($filename) Processing file for update/creation."
        local domains
        domains=$(grep -E 'server_name|proxy_pass' "$file_path" | grep -v '#' | sed -e 's/server_name//' -e 's/proxy_pass//' -e 's/;//' | tr -s ' ' '\n' | grep -vE '^\s*$')
        local domain_list
        domain_list=$(echo "$domains" | sort -u | tr '\n' ' ' | sed 's/ $//')

        if [[ -z "$domain_list" ]]; then
            log SKIP "($filename) File is empty or contains no valid domains."
            return
        fi

        local new_hash
        new_hash=$(echo -n "$domain_list" | sha256sum | awk '{print $1}')
        local hash_file="$HASH_DIR/$filename.sha256"
        local old_hash=""
        [[ -f "$hash_file" ]] && old_hash=$(<"$hash_file")
        if [[ "$new_hash" == "$old_hash" ]]; then
            log SKIP "($filename) No changes detected (hash: ${new_hash:0:7}). Domains: $(echo "$domain_list" | tr ' ' ',')"
            return
        fi

        declare -A domains_by_zone
        for domain in $domain_list; do
            local root_domain
            root_domain=$(echo "$domain" | rev | cut -d. -f1,2 | rev)
            local zone_id
            zone_id=$(get_zone_id "$root_domain") || continue
            domains_by_zone["$zone_id"]+="$domain "
        done

        for zone_id in "${!domains_by_zone[@]}"; do
            load_dns_records_for_zone "$zone_id" || continue
            for domain in ${domains_by_zone[$zone_id]}; do
                local record_id
                record_id=$(get_record_id_from_cache "$zone_id" "$domain")
                local payload
                payload=$(jq -n --arg name "$domain" --arg content "$domain" '{"type":"CNAME", "name":$name, "content":$content, "ttl":1, "proxied":true}')
                if [[ -n "$record_id" ]]; then
                    cf_api_call "PUT" "zones/$zone_id/dns_records/$record_id" "$payload" >/dev/null
                else
                    cf_api_call "POST" "zones/$zone_id/dns_records" "$payload" >/dev/null
                fi
            done
        done

        echo "$new_hash" > "$hash_file"
        log OK "($filename) Domains updated: $(echo "$domain_list" | tr ' ' ',')"
    }

    run_cleanup() {
        log INFO "($filename) Processing file for deletion."
        local hash_file="$HASH_DIR/$filename.sha256"
        if [[ ! -f "$hash_file" ]]; then
            log SKIP "($filename) No hash file found, nothing to clean up."
            return
        fi

        local domains
        domains=$(grep -E 'server_name|proxy_pass' "$file_path" | grep -v '#' | sed -e 's/server_name//' -e 's/proxy_pass//' -e 's/;//' | tr -s ' ' '\n' | grep -vE '^\s*$')
        local domain_list
        domain_list=$(echo "$domains" | sort -u | tr '\n' ' ' | sed 's/ $//')

        declare -A domains_by_zone
        for domain in $domain_list; do
            local root_domain
            root_domain=$(echo "$domain" | rev | cut -d. -f1,2 | rev)
            local zone_id
            zone_id=$(get_zone_id "$root_domain") || continue
            domains_by_zone["$zone_id"]+="$domain "
        done

        for zone_id in "${!domains_by_zone[@]}"; do
            load_dns_records_for_zone "$zone_id" || continue
            for domain in ${domains_by_zone[$zone_id]}; do
                local record_id
                record_id=$(get_record_id_from_cache "$zone_id" "$domain")
                if [[ -n "$record_id" ]]; then
                    cf_api_call "DELETE" "zones/$zone_id/dns_records/$record_id" >/dev/null
                fi
            done
        done

        rm -f "$hash_file"
        log OK "($filename) Cleanup completed for domains: $(echo "$domain_list" | tr ' ' ',')"
    }

    if [[ -f "$file_path" ]]; then
        run_update
    else
        run_cleanup
    fi
}

# --- Event Handler with Locking ---
handle_event() {
    local event_types="$1"
    local file_path="$2"
    local filename
    filename=$(basename "$file_path")
    local lock_dir="$LOCK_DIR/$filename.lock"

    if ! mkdir "$lock_dir" 2>/dev/null; then
        log LOCK "($filename) Lock in use. Another process is already working. Event ignored: [$event_types]"
        return
    fi
    echo "$BASHPID" > "$lock_dir/pid"
    trap 'rm -rf "$lock_dir"' RETURN

    log LOCK "($filename) Lock acquired. Processing event(s): [$event_types]"

    if [[ "$event_types" == *"DELETE"* ]]; then
        log DEBUG "($filename) DELETE event detected. Waiting 1 second to confirm..."
        sleep 1
    fi
    
    process_file_logic "$file_path"
}

# --- Main Execution ---

# Create necessary directories
mkdir -p "$HASH_DIR" "$LOCK_DIR"

# Initial cleanup of old per-file locks
log INFO "Cleaning up old lock files (if any)..."
rm -rf "$LOCK_DIR"/*

# Initial sync (synchronous, to ensure base state)
log INFO "Performing initial sync..."
find "$WATCH_DIR" -type f -name "*.conf" -print0 | while IFS= read -r -d $'\0' file; do
    # Use the event handler for consistency
    handle_event "INITIAL_SYNC" "$file"
done
log INFO "Initial sync complete. Listening for changes..."

# Asynchronous monitoring loop
# Listen for all relevant events. The handler will manage the logic.
inotifywait -m -q -e close_write -e delete -e moved_to --format '%e %w%f' "$WATCH_DIR" | while read -r EVENT FILE; do
  if ! [[ "$FILE" =~ \.conf$ ]]; then
    log DEBUG "Ignoring event on non-.conf file: $FILE"
    continue
  fi
  handle_event "$EVENT" "$FILE" &
done
