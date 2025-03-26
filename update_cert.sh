
#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -e

# Variables
CERT_DIR="/etc/letsencrypt/live/mail.SITE.com"
SSL_DIR="/etc/ssl/mail"
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
PASSWORD_FILE="/etc/ssl/password"
DATE=$(date +%Y%m%d)
CERT_NAME="cert_${DATE}"
COMBINED_CERT="${SSL_DIR}/${CERT_NAME}.pem"
PFX_CERT="${SSL_DIR}/${CERT_NAME}.pfx"
CHECKSUM_FILE="/etc/ssl/combined_cert_checksum"
LOCK_FILE="/var/lock/haproxy_cert.lock"
HAPROXY_CFG_BAK="${HAPROXY_CFG}.bak"

# Ensure SSL directory exists
mkdir -p "${SSL_DIR}"

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
    PID=$(cat "$LOCK_FILE")
    if ps -p "$PID" > /dev/null; then
      log "warn" "Lock file exists (PID: $PID). Another instance is running."
      exit 1
    else
      log "warn" "Stale lock file found. Removing it."
      rm -f "$LOCK_FILE"
    fi
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
  rm -f "$TEMP_FILE" "$TEMP_FILE.add" "$TEMP_FILE.remove"
  log "info" "Cleanup completed."
}

# Handle errors
handle_error() {
  local exit_code=$?
  log "error" "An error occurred (exit code: $exit_code)"
  cleanup
  exit $exit_code
}

# Certbot renewal function
renew_certificate() {
  log "info" "Renewing certificate with certbot..."
  if certbot renew --cert-name mail.kraus-m.ru; then
    log "info" "Certificate renewal successful."
    return 0
  else
    log "error" "Certificate renewal failed."
    return 1
  fi
}

# Generate password file if it doesn't exist
generate_password_file() {
  log "info" "Generating new password file..."
  # Generate a random 16-character password
  openssl rand -base64 12 > "${PASSWORD_FILE}"
  chmod 600 "${PASSWORD_FILE}"
  log "info" "New password file created at ${PASSWORD_FILE}."
}

# Main execution
main() {
  acquire_lock
  TEMP_FILE=$(mktemp)

  trap handle_error ERR
  trap cleanup EXIT

  log "info" "Starting certificate renewal process."

  # Check if certificate files exist, renew if needed
  if [ ! -f "${CERT_DIR}/fullchain.pem" ] || [ ! -f "${CERT_DIR}/privkey.pem" ]; then
    log "info" "Certificate files missing, running renewal..."
    renew_certificate || exit 1
  fi

  # Create SSL directory if it doesn't exist
  if [ ! -d "$SSL_DIR" ]; then
    log "info" "Creating SSL directory: $SSL_DIR"
    mkdir -p "$SSL_DIR"
    chmod 755 "$SSL_DIR"
  fi

  # Generate password file if it doesn't exist
  if [ ! -f "${PASSWORD_FILE}" ]; then
    generate_password_file
  fi

  # Create combined certificate
  log "info" "Creating combined certificate..."
  cat "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem" > "${COMBINED_CERT}"
  chmod 644 "${COMBINED_CERT}"
  chown haproxy:haproxy "${COMBINED_CERT}"
  log "info" "Combined certificate created at ${COMBINED_CERT}."

  # Calculate the current checksum of the combined certificate
  CURRENT_COMBINED_CHECKSUM=$(md5sum "${COMBINED_CERT}" | awk '{ print $1 }')

  # Read the previous checksum
  PREV_COMBINED_CHECKSUM=""
  if [[ -f "$CHECKSUM_FILE" ]]; then
    PREV_COMBINED_CHECKSUM=$(cat "$CHECKSUM_FILE")
  fi

  # Compare the checksums
  if [[ "$CURRENT_COMBINED_CHECKSUM" == "$PREV_COMBINED_CHECKSUM" ]]; then
    log "info" "No changes detected in the combined certificate. Exiting."
    exit 0
  fi

  # Read the export password from the file
  EXPORT_PASSWORD=$(cat "${PASSWORD_FILE}")

  # Convert the combined certificate to .pfx format
  log "info" "Converting certificate to PFX format..."
  openssl pkcs12 -export -out "${PFX_CERT}" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -nomac -inkey "${CERT_DIR}/privkey.pem" -in "${COMBINED_CERT}" -password pass:"${EXPORT_PASSWORD}"
  chmod 755 "${PFX_CERT}"
  log "info" "Converted combined certificate to PFX format at ${PFX_CERT}."

  # Backup HAProxy configuration
  cp "${HAPROXY_CFG}" "${HAPROXY_CFG_BAK}"
  log "info" "Backed up HAProxy configuration to ${HAPROXY_CFG_BAK}."

  # Update the HAProxy configuration file
  sed -i "s|bind \*:443 ssl crt .*|bind \*:443 ssl crt ${COMBINED_CERT} alpn h2,http/1.1|g" "${HAPROXY_CFG}"
  log "info" "Updated HAProxy configuration file."

  # Validate HAProxy configuration
 if /usr/sbin/haproxy -c -f "$HAPROXY_CFG"; then
    log "info" "HAProxy configuration valid. Reloading..."
    if systemctl reload haproxy; then
      log "info" "HAProxy reloaded successfully."
    else
      log "error" "Failed to reload HAProxy."
      # Restore the original configuration
      cp "${HAPROXY_CFG_BAK}" "${HAPROXY_CFG}"
      log "info" "Restored original HAProxy configuration."
      exit 1
    fi
  else
    log "error" "HAProxy configuration invalid. Reverting..."
    cp "${HAPROXY_CFG_BAK}" "${HAPROXY_CFG}"
    log "info" "Restored original HAProxy configuration."
    exit 1
  fi

  # Save the current checksum for future comparison
  echo "${CURRENT_COMBINED_CHECKSUM}" > "$CHECKSUM_FILE"
  chmod 644 "$CHECKSUM_FILE"
  log "info" "Saved new checksum for future comparison."

  log "info" "Certificate renewal and HAProxy update completed successfully."
}

# Run the main function
main