#!/usr/bin/env bash
set -euo pipefail

# launc_onlogin_setup.sh
#
# Sets up Home Assistant VM autostart on macOS using a system LaunchDaemon.
#
# Expected final startup path:
#   /Library/LaunchDaemons/com.homeassistant.vm.plist
#       -> /bin/bash /Users/Shared/homeassistant/launch_ha.sh launchd
#
# This intentionally does NOT use:
#   LaunchAgent -> HALauncher.app -> AppleScript
#
# Run:
#   sudo /bin/bash /Users/Shared/homeassistant/launc_onlogin_setup.sh

LABEL="com.homeassistant.vm"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

HA_DIR="/Users/Shared/homeassistant"
LAUNCH_SCRIPT="${HA_DIR}/launch_ha.sh"
VM_CONF="${HA_DIR}/vm.conf"
LOG_DIR="${HA_DIR}/logs"

OWNER_USER="${SUDO_USER:-}"
if [[ -z "${OWNER_USER}" || "${OWNER_USER}" == "root" ]]; then
  OWNER_USER="$(stat -f '%Su' "${HA_DIR}" 2>/dev/null || echo user)"
fi

OWNER_UID="$(id -u "${OWNER_USER}" 2>/dev/null || true)"

log() {
  printf '[ha-launchd-setup] %s\n' "$*"
}

warn() {
  printf '[ha-launchd-setup] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[ha-launchd-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo /bin/bash "$0" "$@"
fi

[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS only."

[[ -d "${HA_DIR}" ]] || die "Missing Home Assistant directory: ${HA_DIR}"
[[ -f "${LAUNCH_SCRIPT}" ]] || die "Missing launch script: ${LAUNCH_SCRIPT}"
[[ -f "${VM_CONF}" ]] || die "Missing vm.conf: ${VM_CONF}"

if ! grep -q 'launchd) start_launchd' "${LAUNCH_SCRIPT}"; then
  die "launch_ha.sh does not appear to support 'launchd' mode. Replace launch_ha.sh with the current drop-in version first."
fi

if ! grep -Eq '^[[:space:]]*NETWORK_MODE=bridged' "${VM_CONF}"; then
  warn "vm.conf does not contain NETWORK_MODE=bridged"
fi

if ! grep -Eq '^[[:space:]]*HA_LAN_IP=' "${VM_CONF}"; then
  warn "vm.conf does not contain HA_LAN_IP=..."
fi

if ! grep -Eq '^[[:space:]]*VM_MAC=' "${VM_CONF}"; then
  warn "vm.conf does not contain VM_MAC=..."
fi

log "Using owner user: ${OWNER_USER}"
log "Using HA directory: ${HA_DIR}"

chmod +x "${LAUNCH_SCRIPT}"

mkdir -p "${LOG_DIR}"
touch \
  "${LOG_DIR}/launchd.out.log" \
  "${LOG_DIR}/launchd.err.log" \
  "${LOG_DIR}/homeassistant.qemu.log" \
  "${LOG_DIR}/homeassistant.serial.log"

chown -R "${OWNER_USER}:staff" "${LOG_DIR}" 2>/dev/null || true

log "Stopping old user LaunchAgent path if present."

if [[ -n "${OWNER_UID}" ]]; then
  launchctl bootout "gui/${OWNER_UID}" "/Users/${OWNER_USER}/Library/LaunchAgents/com.user.homeassistant.plist" 2>/dev/null || true
fi

rm -f "/Users/${OWNER_USER}/Library/LaunchAgents/com.user.homeassistant.plist"

OLD_STARTUP_DIR="/Users/${OWNER_USER}/Documents/startup"
if [[ -d "${OLD_STARTUP_DIR}" ]]; then
  mkdir -p "${OLD_STARTUP_DIR}/old-homeassistant-startup"

  if [[ -e "${OLD_STARTUP_DIR}/HALauncher.app" ]]; then
    log "Archiving old HALauncher.app"
    mv "${OLD_STARTUP_DIR}/HALauncher.app" "${OLD_STARTUP_DIR}/old-homeassistant-startup/" 2>/dev/null || true
  fi

  if [[ -e "${OLD_STARTUP_DIR}/com.user.homeassistant.plist" ]]; then
    log "Archiving old com.user.homeassistant.plist"
    mv "${OLD_STARTUP_DIR}/com.user.homeassistant.plist" "${OLD_STARTUP_DIR}/old-homeassistant-startup/" 2>/dev/null || true
  fi
fi

log "Stopping existing system LaunchDaemon if loaded."
launchctl bootout "system/${LABEL}" 2>/dev/null || true

sleep 2

if ps axww | grep '[q]emu-system' | grep -F "${HA_DIR}" >/dev/null 2>&1; then
  log "Detected existing Home Assistant QEMU process. Asking launch_ha.sh to stop it."
  /bin/bash "${LAUNCH_SCRIPT}" stop || true
  sleep 3
fi

if ps axww | grep '[q]emu-system' | grep -F "${HA_DIR}" >/dev/null 2>&1; then
  die "A Home Assistant QEMU process is still running from ${HA_DIR}. Stop it manually before continuing."
fi

log "Clearing stale runtime files."
rm -f "${HA_DIR}/homeassistant.pid"
rm -f "${HA_DIR}/homeassistant.qmp.sock"

log "Clearing old log files."
rm -f "${LOG_DIR}"/*.log
touch \
  "${LOG_DIR}/launchd.out.log" \
  "${LOG_DIR}/launchd.err.log" \
  "${LOG_DIR}/homeassistant.qemu.log" \
  "${LOG_DIR}/homeassistant.serial.log"

chown -R "${OWNER_USER}:staff" "${LOG_DIR}" 2>/dev/null || true

log "Writing LaunchDaemon plist: ${PLIST}"

cat > "${PLIST}" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${LAUNCH_SCRIPT}</string>
    <string>launchd</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${HA_DIR}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>/var/root</string>

    <key>PATH</key>
    <string>/opt/local/bin:/opt/local/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd.out.log</string>

  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd.err.log</string>
</dict>
</plist>
EOF_PLIST

chown root:wheel "${PLIST}"
chmod 644 "${PLIST}"

log "Validating plist."
plutil -lint "${PLIST}"

log "Bootstrapping LaunchDaemon."
launchctl bootstrap system "${PLIST}"
launchctl enable "system/${LABEL}"
launchctl kickstart -kp "system/${LABEL}"

sleep 3

log "LaunchDaemon status:"
launchctl print "system/${LABEL}" || true

log "QEMU process:"
ps axww | grep '[q]emu-system' || true

log "Recent launchd stderr:"
tail -n 80 "${LOG_DIR}/launchd.err.log" || true

log "Recent QEMU log:"
tail -n 80 "${LOG_DIR}/homeassistant.qemu.log" || true

log "Done."
log "Check Home Assistant with:"
log "  curl -I http://192.168.1.206:8123/"
log "Check daemon with:"
log "  sudo launchctl print system/${LABEL}"