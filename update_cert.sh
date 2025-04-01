#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -e

# Constants
readonly CERT_DIR="/etc/letsencrypt/live/mail.test.com"
readonly SSL_DIR="/etc/ssl/mail"
readonly HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
readonly PASSWORD_FILE="/etc/ssl/password"
readonly CHECKSUM_FILE="/etc/ssl/combined_cert_checksum"
readonly LOCK_FILE="/var/lock/haproxy_cert.lock"
readonly LOG_FILE="/var/log/cert_renewal.log"
readonly DATE=$(date +%Y%m%d)
readonly CERT_NAME="cert_${DATE}"
readonly COMBINED_CERT="${SSL_DIR}/${CERT_NAME}.pem"
readonly PFX_CERT="${SSL_DIR}/${CERT_NAME}.pfx"
readonly REQUIRED_TOOLS=("openssl" "certbot" "haproxy" "md5sum")

# Configuration
readonly MIN_DISK_SPACE_MB=100
readonly TIMEOUT_SECONDS=300
readonly NOTIFY_EMAIL="admin@example.com"

# Ensure SSL directory exists with secure permissions
mkdir -p "${SSL_DIR}"
chmod 700 "${SSL_DIR}"

# Logging function with file output
log() {
  local level="$1"
  shift
  local message="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$message" >> "$LOG_FILE"
  case "$level" in
    error) echo -e "\e[31m$message\e[0m" ;;  # Red
    warn)  echo -e "\e[33m$message\e[0m" ;;  # Yellow
    info)  echo -e "\e[32m$message\e[0m" ;;  # Green
    *)     echo "$message" ;;
  esac
}

# Check prerequisites
check_prerequisites() {
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      log "error" "Required tool $tool not found"
      exit 1
    fi
  done

  local disk_space=$(df -m / | tail -1 | awk '{print $4}')
  if [ "$disk_space" -lt "$MIN_DISK_SPACE_MB" ]; then
    log "error" "Insufficient disk space: ${disk_space}MB available, ${MIN_DISK_SPACE_MB}MB required"
    exit 1
  fi
}

# Acquire lock with timeout
acquire_lock() {
  local timeout=30
  local waited=0
  while [ -e "$LOCK_FILE" ] && [ "$waited" -lt "$timeout" ]; do
    PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
    if ! ps -p "$PID" > /dev/null 2>&1; then
      log "warn" "Removing stale lock file (PID: $PID)"
      rm -f "$LOCK_FILE"
      break
    fi
    sleep 1
    ((waited++))
  done
  
  if [ -e "$LOCK_FILE" ]; then
    log "error" "Could not acquire lock after ${timeout}s (PID: $(cat "$LOCK_FILE"))"
    exit 1
  fi
  echo $$ > "$LOCK_FILE"
  chmod 600 "$LOCK_FILE"
}

# Release lock
release_lock() {
  [ -e "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
}

# Send notification
notify() {
  local subject="$1"
  local message="$2"
  if [ -n "$NOTIFY_EMAIL" ]; then
    #echo "$message" | mail -s "$subject" "$NOTIFY_EMAIL"
    echo "$message" 
  fi
}

# Cleanup on exit
cleanup() {
  release_lock
  rm -f "$TEMP_FILE" "$TEMP_FILE.add" "$TEMP_FILE.remove" 2>/dev/null
  log "info" "Cleanup completed"
}

# Handle errors
handle_error() {
  local exit_code=$?
  local error_msg="Script failed with exit code $exit_code"
  log "error" "$error_msg"
  notify "Certificate Renewal Failure" "$error_msg\nCheck $LOG_FILE for details"
  cleanup
  exit $exit_code
}

# Certbot renewal with timeout
renew_certificate() {
  log "info" "Renewing certificate with certbot..."
  timeout "$TIMEOUT_SECONDS" certbot renew --cert-name mail.test.com --quiet
  local status=$?
  if [ $status -eq 0 ]; then
    log "info" "Certificate renewal successful"
    return 0
  else
    log "error" "Certificate renewal failed (status: $status)"
    return 1
  fi
}

# Generate secure password file
generate_password_file() {
  if [ ! -f "$PASSWORD_FILE" ] || [ ! -s "$PASSWORD_FILE" ]; then
    log "info" "Generating new password file..."
    openssl rand -base64 32 > "${PASSWORD_FILE}"
    chmod 600 "${PASSWORD_FILE}"
    log "info" "New password file created"
  fi
}

# Main execution
main() {
  TEMP_FILE=$(mktemp)
  touch "$LOG_FILE" && chmod 640 "$LOG_FILE"

  trap handle_error ERR
  trap cleanup EXIT

  check_prerequisites
  acquire_lock

  log "info" "Starting certificate renewal process"

  # Check and renew certificate
  if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/privkey.pem" ]; then
    renew_certificate || exit 1
  fi

  # Generate password file if needed
  generate_password_file
  local EXPORT_PASSWORD=$(cat "${PASSWORD_FILE}")

  # Create combined certificate
  log "info" "Creating combined certificate..."
  cat "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" > "${COMBINED_CERT}"
  chmod 600 "${COMBINED_CERT}"
  chown haproxy:haproxy "${COMBINED_CERT}"

  # Check checksum
  local CURRENT_CHECKSUM=$(md5sum "${COMBINED_CERT}" | awk '{print $1}')
  local PREV_CHECKSUM=$(cat "$CHECKSUM_FILE" 2>/dev/null || echo "")
  
  if [ "$CURRENT_CHECKSUM" = "$PREV_CHECKSUM" ] && [ -n "$PREV_CHECKSUM" ]; then
    log "info" "No certificate changes detected"
    exit 0
  fi

  # Create PFX with modern encryption
  log "info" "Creating PFX certificate..."
  openssl pkcs12 -export \
    -out "${PFX_CERT}" \
    -inkey "${CERT_DIR}/privkey.pem" \
    -in "${COMBINED_CERT}" \
    -certpbe AES-256-CBC \
    -keypbe AES-256-CBC \
    -macalg SHA256 \
    -password pass:"${EXPORT_PASSWORD}"
  chmod 600 "${PFX_CERT}"
  chown haproxy:haproxy "${PFX_CERT}"

  # Update HAProxy configuration
  local HAPROXY_CFG_BAK="${HAPROXY_CFG}.${DATE}.bak"
  cp -p "${HAPROXY_CFG}" "${HAPROXY_CFG_BAK}"
  
  sed -i "s|bind \*:443 ssl crt .*|bind \*:443 ssl crt ${COMBINED_CERT} alpn h2,http/1.1|g" "${HAPROXY_CFG}"
  
  if haproxy -c -f "$HAPROXY_CFG" >/dev/null 2>&1; then
    log "info" "Reloading HAProxy..."
    systemctl reload haproxy || {
      log "error" "HAProxy reload failed"
      cp -p "${HAPROXY_CFG_BAK}" "${HAPROXY_CFG}"
      exit 1
    }
  else
    log "error" "Invalid HAProxy configuration"
    cp -p "${HAPROXY_CFG_BAK}" "${HAPROXY_CFG}"
    exit 1
  fi

  echo "$CURRENT_CHECKSUM" > "$CHECKSUM_FILE"
  chmod 600 "$CHECKSUM_FILE"
  
  log "info" "Certificate update completed successfully"
  notify "Certificate Renewal Success" "Certificate updated successfully on $(date)"
}

# Execute
main