#!/bin/bash
# Improved Script to Update HAProxy OWA Blocklist from the Ipsum Repository
set -euo pipefail

# Configuration
BLOCKLIST_FILE="/etc/haproxy/spamblocklist.lst"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
IPSUM_URL="https://raw.githubusercontent.com/stamparm/ipsum/master/ipsum.txt"
CURL_RETRIES=3
CURL_RETRY_DELAY=5
LOCK_FILE="/var/lock/haproxy_blocklist.lock"
METRICS_FILE="/var/log/haproxy_blocklist_metrics.json"
MIN_THRESHOLD=100

# Logging function
log() {
  local level="$1"
  shift
  local message="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  case "$level" in
    error) echo -e "\e[31m$message\e[0m" ;;  # Red
    warn)  echo -e "\e[33m$message\e[0m" ;;  # Yellow
    info)  echo -e "\e[32m$message\e[0m" ;;  # Green
    *)     echo "$message" ;;
  esac
}

# Acquire lock
acquire_lock() {
  if [ -e "$LOCK_FILE" ]; then
    log "warn" "Lock file exists. Another instance might be running."
    exit 1
  fi
  echo $$ > "$LOCK_FILE"
}

# Release lock
release_lock() {
  rm -f "$LOCK_FILE"
}

# Cleanup on exit
cleanup() {
  release_lock
  rm -f "$DOWNLOADED_FILE" "$TEMP_FILE" "$TEMP_FILE.add" "$TEMP_FILE.remove"
}
trap cleanup EXIT

# Main execution
main() {
  acquire_lock

  DOWNLOADED_FILE=$(mktemp)
  TEMP_FILE=$(mktemp)
  START_TIME=$(date +%s)
  SUCCESS=true

  # Download and filter IPs
  log "info" "Fetching IP list..."
  if ! curl -s --retry $CURL_RETRIES --retry-delay $CURL_RETRY_DELAY "$IPSUM_URL" | grep -v "^#" | awk '$2 > 2 {print $1}' > "$DOWNLOADED_FILE"; then
    log "error" "Failed to fetch IP list."
    SUCCESS=false
    exit 1
  fi

  DOWNLOADED_COUNT=$(wc -l < "$DOWNLOADED_FILE")
  log "info" "Downloaded $DOWNLOADED_COUNT IPs."

  if [ "$DOWNLOADED_COUNT" -lt "$MIN_THRESHOLD" ]; then
    log "error" "Too few IPs ($DOWNLOADED_COUNT), possible download error."
    SUCCESS=false
    exit 1
  fi

  # Backup existing blocklist
  cp "$BLOCKLIST_FILE" "${BLOCKLIST_FILE}.bak"
  log "info" "Backup created."

  # Extract and compare IPs
  sort -u "$DOWNLOADED_FILE" > "${DOWNLOADED_FILE}.sorted"
  sort -u "$BLOCKLIST_FILE" > "${BLOCKLIST_FILE}.sorted"

  comm -23 "${DOWNLOADED_FILE}.sorted" "${BLOCKLIST_FILE}.sorted" > "$TEMP_FILE.add"
  comm -13 "${DOWNLOADED_FILE}.sorted" "${BLOCKLIST_FILE}.sorted" > "$TEMP_FILE.remove"

  ADDED_COUNT=$(wc -l < "$TEMP_FILE.add")
  REMOVED_COUNT=$(wc -l < "$TEMP_FILE.remove")
  FINAL_COUNT=$((DOWNLOADED_COUNT + ADDED_COUNT - REMOVED_COUNT))
  log "info" "Added: $ADDED_COUNT, Removed: $REMOVED_COUNT, Total: $FINAL_COUNT"

  # Update blocklist
  grep -v -F -f "$TEMP_FILE.remove" "$BLOCKLIST_FILE" > "$TEMP_FILE"
  cat "$TEMP_FILE.add" >> "$TEMP_FILE"
  sort -u "$TEMP_FILE" -o "$BLOCKLIST_FILE"
  log "info" "Blocklist updated."

# Validate HAProxy configuration
if /usr/sbin/haproxy -c -f "$HAPROXY_CFG"; then
    log "info" "HAProxy configuration valid. Reloading..."
    systemctl reload haproxy || log "warn" "Failed to reload HAProxy."
else
    log "error" "HAProxy configuration invalid. Reverting..."
    mv "${BLOCKLIST_FILE}.bak" "$BLOCKLIST_FILE"
    SUCCESS=false
    exit 1
fi
  log "info" "Update complete."
}

main
