cat > launch_ha.sh <<'EOF_LAUNCH'
#!/usr/bin/env bash
set -euo pipefail

# launch_ha.sh
# Manage a Home Assistant OS VM on macOS using QEMU + HVF.
#
# Designed to pair with the revised setup_ha.sh that prepares a supported
# Home Assistant OS VM qcow2 disk, especially:
#   Intel/x86_64 Mac: haos_ova-<version>.qcow2.xz
#
# Usage:
#   ./launch_ha.sh start
#   ./launch_ha.sh status
#   ./launch_ha.sh logs
#   ./launch_ha.sh stop
#
# Environment overrides:
#   HA_PORT=8124 ./launch_ha.sh start
#   RAM_MB=8192 CPUS=4 ./launch_ha.sh start
#   ALLOW_UNSUPPORTED_HAOS_IMAGE=1 ./launch_ha.sh start

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$DIR/vm.conf"
DEFAULT_CONF="$HOME/haos-vm/vm.conf"

log() {
  printf '[launch-ha] %s\n' "$*"
}

warn() {
  printf '[launch-ha] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[launch-ha] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  source "$CONF"
elif [[ -f "$DEFAULT_CONF" ]]; then
  # shellcheck source=/dev/null
  source "$DEFAULT_CONF"
else
  die "vm.conf not found. Run ./setup_ha.sh first."
fi

VM_NAME="${VM_NAME:-homeassistant}"
HA_DIR="${HA_DIR:-$DIR}"
RAM_MB="${RAM_MB:-4096}"
CPUS="${CPUS:-2}"
HA_PORT="${HA_PORT:-8123}"
HOST_ARCH="${HOST_ARCH:-$(uname -m)}"
HA_BOARD="${HA_BOARD:-}"
HAOS_IMAGE_KIND="${HAOS_IMAGE_KIND:-qcow2}"
HAOS_IMAGE_IS_VIRTUAL="${HAOS_IMAGE_IS_VIRTUAL:-}"
HAOS_ASSET_NAME="${HAOS_ASSET_NAME:-}"
DISK_PATH="${DISK_PATH:-}"
EFI_CODE="${EFI_CODE:-}"
EFI_VARS="${EFI_VARS:-}"
FIRMWARE_MODE="${FIRMWARE_MODE:-auto}"
ALLOW_UNSUPPORTED_HAOS_IMAGE="${ALLOW_UNSUPPORTED_HAOS_IMAGE:-0}"

case "$HOST_ARCH" in
  x86_64)
    QEMU_SYSTEM_NAME="qemu-system-x86_64"
    QEMU_MACHINE="${QEMU_MACHINE:-q35,accel=hvf}"
    QEMU_CPU="${QEMU_CPU:-host}"
    FIRMWARE_PATTERNS=("OVMF_CODE.fd" "OVMF.fd" "edk2-x86_64-code.fd")
    EFI_VAR_PATTERNS=("edk2-x86_64-vars.fd" "OVMF_VARS.fd" "OVMF_VARS_4M.fd" "OVMF_VARS.ms.fd")
    ;;
  arm64)
    QEMU_SYSTEM_NAME="qemu-system-aarch64"
    QEMU_MACHINE="${QEMU_MACHINE:-virt,accel=hvf,highmem=off}"
    QEMU_CPU="${QEMU_CPU:-host}"
    FIRMWARE_PATTERNS=("edk2-aarch64-code.fd" "QEMU_EFI.fd")
    EFI_VAR_PATTERNS=()
    ;;
  *)
    die "Unsupported host architecture: $HOST_ARCH"
    ;;
esac

QEMU_BIN="${QEMU_BIN:-$QEMU_SYSTEM_NAME}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"

LOG_DIR="$HA_DIR/logs"
PID_FILE="$HA_DIR/${VM_NAME}.pid"
QMP_SOCKET="$HA_DIR/${VM_NAME}.qmp.sock"
SERIAL_LOG="$LOG_DIR/${VM_NAME}.serial.log"
QEMU_LOG="$LOG_DIR/${VM_NAME}.qemu.log"

mkdir -p "$LOG_DIR"

find_port_bin() {
  if command -v port >/dev/null 2>&1; then
    PORT_BIN="$(command -v port)"
    return 0
  fi

  if [[ -x /opt/local/bin/port ]]; then
    PORT_BIN="/opt/local/bin/port"
    export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
    return 0
  fi

  return 1
}

find_program() {
  local name="$1"

  if [[ -n "$name" && -x "$name" ]]; then
    printf '%s\n' "$name"
    return 0
  fi

  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi

  local p
  for p in \
    "/opt/local/bin/$name" \
    "/opt/local/libexec/qemu/$name" \
    "/usr/local/bin/$name" \
    "/opt/homebrew/bin/$name"
  do
    if [[ -x "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done

  if find_port_bin >/dev/null 2>&1; then
    local from_contents
    from_contents="$("$PORT_BIN" contents qemu 2>/dev/null | awk -v n="/$name" '$0 ~ n "$" {print $0; exit}' || true)"
    if [[ -n "$from_contents" && -x "$from_contents" ]]; then
      printf '%s\n' "$from_contents"
      return 0
    fi
  fi

  return 1
}

refresh_runtime_paths() {
  HA_DIR="$(cd "$HA_DIR" && pwd)"
  LOG_DIR="$HA_DIR/logs"
  PID_FILE="$HA_DIR/${VM_NAME}.pid"
  QMP_SOCKET="$HA_DIR/${VM_NAME}.qmp.sock"
  SERIAL_LOG="$LOG_DIR/${VM_NAME}.serial.log"
  QEMU_LOG="$LOG_DIR/${VM_NAME}.qemu.log"
  mkdir -p "$LOG_DIR"
}

resolve_disk_path() {
  if [[ -n "${DISK_PATH:-}" && -f "$DISK_PATH" ]]; then
    DISK_PATH="$(cd "$(dirname "$DISK_PATH")" && pwd)/$(basename "$DISK_PATH")"
    HA_DIR="$(cd "$(dirname "$DISK_PATH")" && pwd)"
    refresh_runtime_paths
    return 0
  fi

  local candidates=()

  if [[ "$HOST_ARCH" == "x86_64" ]]; then
    candidates+=(
      "$DIR/${VM_NAME}-ova.qcow2"
      "$HA_DIR/${VM_NAME}-ova.qcow2"
      "$HOME/haos-vm/${VM_NAME}-ova.qcow2"
      "$HOME/haos-vm/homeassistant-ova.qcow2"
    )
  fi

  if [[ "$HOST_ARCH" == "arm64" ]]; then
    candidates+=(
      "$DIR/${VM_NAME}-generic-aarch64.qcow2"
      "$HA_DIR/${VM_NAME}-generic-aarch64.qcow2"
      "$HOME/haos-vm/${VM_NAME}-generic-aarch64.qcow2"
      "$HOME/haos-vm/homeassistant-generic-aarch64.qcow2"
    )
  fi

  if [[ "$ALLOW_UNSUPPORTED_HAOS_IMAGE" == "1" ]]; then
    candidates+=(
      "$DIR/${VM_NAME}.qcow2"
      "$HA_DIR/${VM_NAME}.qcow2"
      "$HOME/haos-vm/${VM_NAME}.qcow2"
      "$HOME/haos-vm/homeassistant.qcow2"
    )
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      DISK_PATH="$candidate"
      DISK_PATH="$(cd "$(dirname "$DISK_PATH")" && pwd)/$(basename "$DISK_PATH")"
      HA_DIR="$(cd "$(dirname "$DISK_PATH")" && pwd)"
      refresh_runtime_paths
      log "Using VM disk: $DISK_PATH"
      return 0
    fi
  done

  die "VM disk not found. Run ./setup_ha.sh first. Expected the supported VM qcow2 disk, for example: $DIR/${VM_NAME}-ova.qcow2"
}

validate_supported_image() {
  if [[ "$ALLOW_UNSUPPORTED_HAOS_IMAGE" == "1" ]]; then
    warn "ALLOW_UNSUPPORTED_HAOS_IMAGE=1 is set. Skipping HAOS image validation."
    return 0
  fi

  if [[ "$HAOS_IMAGE_KIND" != "qcow2" ]]; then
    die "vm.conf does not describe a qcow2 VM disk. Run the revised ./setup_ha.sh first."
  fi

  if [[ "$HOST_ARCH" == "x86_64" ]]; then
    if [[ "$HA_BOARD" != "ova" ]]; then
      die "Intel/x86_64 VM should use HA_BOARD=ova. Current HA_BOARD='$HA_BOARD'. Run the revised ./setup_ha.sh."
    fi

    if [[ -n "$HAOS_ASSET_NAME" && "$HAOS_ASSET_NAME" != haos_ova-*.qcow2.xz ]]; then
      die "Wrong HAOS asset for an Intel VM: $HAOS_ASSET_NAME. Expected haos_ova-<version>.qcow2.xz."
    fi

    if [[ "$DISK_PATH" == *generic-x86-64* || "$HAOS_ASSET_NAME" == *generic-x86-64* ]]; then
      die "This appears to be the bare-metal generic-x86-64 image, not the supported VM image. Re-run setup_ha.sh."
    fi
  fi

  if [[ "$HOST_ARCH" == "arm64" ]]; then
    if [[ "$DISK_PATH" != *.qcow2 ]]; then
      die "Apple Silicon launch requires a qcow2 VM disk. Re-run setup_ha.sh."
    fi
  fi
}

firmware_roots() {
  local roots=()

  if [[ -n "${QEMU_BIN:-}" && -x "$QEMU_BIN" ]]; then
    roots+=("$(cd "$(dirname "$QEMU_BIN")/.." && pwd)")
  fi

  if command -v brew >/dev/null 2>&1; then
    local qemu_prefix
    qemu_prefix="$(brew --prefix qemu 2>/dev/null || true)"
    [[ -n "$qemu_prefix" ]] && roots+=("$qemu_prefix")
  fi

  roots+=(
    "/opt/local"
    "/usr/local"
    "/opt/homebrew"
    "/Applications/UTM.app"
  )

  printf '%s\n' "${roots[@]}"
}

find_efi_firmware() {
  if [[ -n "${EFI_CODE:-}" && -r "$EFI_CODE" && -s "$EFI_CODE" ]]; then
    return 0
  fi

  local pattern root candidate
  for pattern in "${FIRMWARE_PATTERNS[@]}"; do
    while IFS= read -r root; do
      [[ -d "$root" ]] || continue
      candidate="$(find "$root" -type f -name "$pattern" 2>/dev/null | head -n 1 || true)"
      if [[ -n "$candidate" && -r "$candidate" && -s "$candidate" ]]; then
        EFI_CODE="$candidate"
        return 0
      fi
    done < <(firmware_roots)
  done

  die "Could not find readable QEMU UEFI firmware. Re-run setup_ha.sh."
}

ensure_efi_vars() {
  if [[ "$HOST_ARCH" != "x86_64" ]]; then
    EFI_VARS=""
    return 0
  fi

  if [[ "$FIRMWARE_MODE" == "bios" ]]; then
    EFI_VARS=""
    return 0
  fi

  if [[ -n "${EFI_VARS:-}" && -r "$EFI_VARS" && -s "$EFI_VARS" ]]; then
    return 0
  fi

  local vm_vars="$HA_DIR/${VM_NAME}.efi_vars.fd"
  if [[ -r "$vm_vars" && -s "$vm_vars" ]]; then
    EFI_VARS="$vm_vars"
    return 0
  fi

  local pattern root template
  for pattern in "${EFI_VAR_PATTERNS[@]}"; do
    while IFS= read -r root; do
      [[ -d "$root" ]] || continue
      template="$(find "$root" -type f -name "$pattern" 2>/dev/null | head -n 1 || true)"
      if [[ -n "$template" && -r "$template" && -s "$template" ]]; then
        cp "$template" "$vm_vars.tmp"
        chmod u+w "$vm_vars.tmp" 2>/dev/null || true
        mv "$vm_vars.tmp" "$vm_vars"
        EFI_VARS="$vm_vars"
        return 0
      fi
    done < <(firmware_roots)
  done

  EFI_VARS=""
  warn "No UEFI vars template found. Continuing with code-only firmware."
}

build_firmware_args() {
  QEMU_FIRMWARE_ARGS=()

  if [[ "$HOST_ARCH" == "x86_64" && "$FIRMWARE_MODE" != "bios" ]]; then
    QEMU_FIRMWARE_ARGS+=(
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=$EFI_CODE"
    )

    if [[ -n "${EFI_VARS:-}" && -r "$EFI_VARS" && -s "$EFI_VARS" ]]; then
      QEMU_FIRMWARE_ARGS+=(
        -drive "if=pflash,format=raw,unit=1,file=$EFI_VARS"
      )
    fi
  else
    QEMU_FIRMWARE_ARGS+=(
      -bios "$EFI_CODE"
    )
  fi
}

is_running() {
  if [[ ! -f "$PID_FILE" ]]; then
    return 1
  fi

  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1

  if kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  rm -f "$PID_FILE"
  return 1
}

check_port_available() {
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$HA_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      die "Port $HA_PORT is already in use. Stop the conflicting process or run: HA_PORT=8124 $0 start"
    fi
    return 0
  fi

  if nc -z 127.0.0.1 "$HA_PORT" >/dev/null 2>&1; then
    die "Port $HA_PORT is already in use. Stop the conflicting process or run: HA_PORT=8124 $0 start"
  fi
}

check_disk_readable() {
  [[ -r "$DISK_PATH" ]] || die "Disk is not readable: $DISK_PATH"

  if QEMU_IMG="$(find_program "$QEMU_IMG" 2>/dev/null || true)" && [[ -n "$QEMU_IMG" ]]; then
    "$QEMU_IMG" info "$DISK_PATH" >/dev/null || die "qemu-img cannot read disk as a valid image: $DISK_PATH"
  else
    warn "qemu-img not found. Skipping disk validation."
  fi
}

build_qemu_args() {
  build_firmware_args

  QEMU_ARGS=(
    -name "$VM_NAME"
    -machine "$QEMU_MACHINE"
    -cpu "$QEMU_CPU"
    -smp "$CPUS"
    -m "$RAM_MB"
    "${QEMU_FIRMWARE_ARGS[@]}"
    -drive "if=none,id=haosdisk,format=qcow2,file=$DISK_PATH,cache=writethrough,discard=unmap"
    -device "virtio-blk-pci,drive=haosdisk,bootindex=0"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${HA_PORT}-:8123"
    -device "virtio-net-pci,netdev=net0"
    -device "virtio-rng-pci"
    -qmp "unix:$QMP_SOCKET,server=on,wait=off"
  )

  if [[ "$HOST_ARCH" == "arm64" ]]; then
    QEMU_ARGS+=(
      -device "virtio-gpu-pci"
    )
  fi
}

preflight() {
  command -v nc >/dev/null 2>&1 || die "nc not found."

  if [[ ! -x "${QEMU_BIN:-}" ]]; then
    QEMU_BIN="$(find_program "$QEMU_SYSTEM_NAME")" || die "QEMU binary not found: $QEMU_SYSTEM_NAME"
  fi

  resolve_disk_path
  validate_supported_image
  check_disk_readable
  find_efi_firmware
  ensure_efi_vars
  build_qemu_args
}

show_recent_logs() {
  log "QEMU log: $QEMU_LOG"
  tail -n 100 "$QEMU_LOG" 2>/dev/null || true

  log "Serial log: $SERIAL_LOG"
  tail -n 100 "$SERIAL_LOG" 2>/dev/null || true
}

wait_for_port() {
  local max_seconds="${1:-600}"
  local elapsed=0

  log "Waiting for Home Assistant on http://127.0.0.1:$HA_PORT"

  while (( elapsed < max_seconds )); do
    if ! is_running; then
      log "QEMU exited before Home Assistant opened port $HA_PORT."
      show_recent_logs
      return 1
    fi

    if nc -z 127.0.0.1 "$HA_PORT" >/dev/null 2>&1; then
      log "Home Assistant port is open: http://127.0.0.1:$HA_PORT"
      return 0
    fi

    sleep 2
    elapsed=$((elapsed + 2))

    if (( elapsed % 20 == 0 )); then
      log "Still waiting. Elapsed: ${elapsed}s. Logs: $SERIAL_LOG and $QEMU_LOG"
    fi
  done

  log "VM is running, but Home Assistant has not opened port $HA_PORT yet."
  log "Check logs with: $0 logs"
  log "Open manually when ready: http://127.0.0.1:$HA_PORT"
  return 0
}

start_background() {
  preflight

  if is_running; then
    log "$VM_NAME is already running. PID: $(cat "$PID_FILE")"
    log "URL: http://127.0.0.1:$HA_PORT"
    return 0
  fi

  check_port_available
  rm -f "$QMP_SOCKET"
  touch "$SERIAL_LOG" "$QEMU_LOG"

  log "Starting $VM_NAME in background."
  log "RAM: ${RAM_MB} MB"
  log "CPUs: $CPUS"
  log "Disk: $DISK_PATH"
  log "QEMU: $QEMU_BIN"
  log "Machine: $QEMU_MACHINE"
  log "CPU: $QEMU_CPU"
  log "Firmware: $EFI_CODE"
  [[ -n "${EFI_VARS:-}" ]] && log "Firmware vars: $EFI_VARS"
  [[ -n "${HAOS_ASSET_NAME:-}" ]] && log "HAOS asset: $HAOS_ASSET_NAME"
  log "URL: http://127.0.0.1:$HA_PORT"

  nohup "$QEMU_BIN" \
    "${QEMU_ARGS[@]}" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    >"$QEMU_LOG" 2>&1 &

  local pid=$!
  echo "$pid" > "$PID_FILE"

  sleep 1

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    rm -f "$PID_FILE"
    echo "QEMU failed to start. Recent log:" >&2
    tail -n 120 "$QEMU_LOG" >&2 || true
    exit 1
  fi

  log "Started. PID: $pid"
  wait_for_port 600
}

start_foreground() {
  preflight

  if is_running; then
    die "$VM_NAME is already running. Stop it first with: $0 stop"
  fi

  check_port_available
  rm -f "$QMP_SOCKET"

  log "Starting $VM_NAME in foreground."
  log "QEMU: $QEMU_BIN"
  log "Disk: $DISK_PATH"
  log "Firmware: $EFI_CODE"
  [[ -n "${EFI_VARS:-}" ]] && log "Firmware vars: $EFI_VARS"
  log "URL after boot: http://127.0.0.1:$HA_PORT"
  log "Exit QEMU console with Ctrl-A then X."

  exec "$QEMU_BIN" \
    "${QEMU_ARGS[@]}" \
    -display none \
    -serial mon:stdio
}

stop_vm() {
  refresh_runtime_paths

  if ! is_running; then
    log "$VM_NAME is not running."
    rm -f "$PID_FILE" "$QMP_SOCKET"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"

  log "Stopping $VM_NAME. PID: $pid"

  if [[ -S "$QMP_SOCKET" ]]; then
    {
      printf '{ "execute": "qmp_capabilities" }\r\n'
      sleep 0.2
      printf '{ "execute": "system_powerdown" }\r\n'
    } | nc -U "$QMP_SOCKET" >/dev/null 2>&1 || true
  else
    warn "QMP socket not found. Falling back to TERM."
    kill "$pid" >/dev/null 2>&1 || true
  fi

  local waited=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( waited >= 60 )); then
      warn "Graceful stop timed out. Forcing shutdown."
      kill -TERM "$pid" >/dev/null 2>&1 || true
      sleep 3
      kill -KILL "$pid" >/dev/null 2>&1 || true
      break
    fi

    sleep 2
    waited=$((waited + 2))
  done

  rm -f "$PID_FILE" "$QMP_SOCKET"
  log "Stopped."
}

kill_vm() {
  refresh_runtime_paths

  if ! is_running; then
    log "$VM_NAME is not running."
    rm -f "$PID_FILE" "$QMP_SOCKET"
    return 0
  fi

  local pid
  pid="$(cat "$PID_FILE")"

  log "Killing $VM_NAME. PID: $pid"
  kill -TERM "$pid" >/dev/null 2>&1 || true
  sleep 2
  kill -KILL "$pid" >/dev/null 2>&1 || true
  rm -f "$PID_FILE" "$QMP_SOCKET"
  log "Killed."
}

status_vm() {
  resolve_disk_path >/dev/null 2>&1 || true
  refresh_runtime_paths

  if is_running; then
    local pid
    pid="$(cat "$PID_FILE")"

    echo "$VM_NAME is running."
    echo "PID: $pid"
    echo "URL: http://127.0.0.1:$HA_PORT"
    echo "Disk: $DISK_PATH"
    echo "QEMU: $QEMU_BIN"
    echo "Machine: $QEMU_MACHINE"
    echo "CPU: $QEMU_CPU"
    echo "Firmware: ${EFI_CODE:-not resolved yet}"
    [[ -n "${EFI_VARS:-}" ]] && echo "Firmware vars: $EFI_VARS"
    [[ -n "${HA_BOARD:-}" ]] && echo "HA board: $HA_BOARD"
    [[ -n "${HAOS_ASSET_NAME:-}" ]] && echo "HAOS asset: $HAOS_ASSET_NAME"
    echo "Serial log: $SERIAL_LOG"
    echo "QEMU log: $QEMU_LOG"

    if nc -z 127.0.0.1 "$HA_PORT" >/dev/null 2>&1; then
      echo "Home Assistant port: open"
    else
      echo "Home Assistant port: not open yet"
    fi
  else
    echo "$VM_NAME is not running."
    echo "URL: http://127.0.0.1:$HA_PORT"
    echo "Disk: ${DISK_PATH:-unknown}"
    [[ -n "${HA_BOARD:-}" ]] && echo "HA board: $HA_BOARD"
    [[ -n "${HAOS_ASSET_NAME:-}" ]] && echo "HAOS asset: $HAOS_ASSET_NAME"
  fi
}

doctor_vm() {
  preflight

  echo "Preflight passed."
  echo "VM name: $VM_NAME"
  echo "Host arch: $HOST_ARCH"
  echo "HA board: ${HA_BOARD:-unknown}"
  echo "HAOS asset: ${HAOS_ASSET_NAME:-unknown}"
  echo "Disk: $DISK_PATH"
  echo "QEMU: $QEMU_BIN"
  echo "qemu-img: ${QEMU_IMG:-not found}"
  echo "Machine: $QEMU_MACHINE"
  echo "CPU: $QEMU_CPU"
  echo "RAM: ${RAM_MB} MB"
  echo "CPUs: $CPUS"
  echo "Firmware: $EFI_CODE"
  [[ -n "${EFI_VARS:-}" ]] && echo "Firmware vars: $EFI_VARS"
  echo "URL: http://127.0.0.1:$HA_PORT"
}

tail_logs() {
  refresh_runtime_paths
  touch "$SERIAL_LOG" "$QEMU_LOG"
  log "Tailing logs. Press Ctrl-C to stop."
  tail -n 120 -f "$SERIAL_LOG" "$QEMU_LOG"
}

print_url() {
  echo "http://127.0.0.1:$HA_PORT"
}

open_url() {
  local url
  url="http://127.0.0.1:$HA_PORT"
  if command -v open >/dev/null 2>&1; then
    open "$url"
  else
    echo "$url"
  fi
}

restart_vm() {
  stop_vm
  start_background
}

usage() {
  cat <<EOF_USAGE
Usage:
  $0 [command]

Commands:
  start       Start VM in background
  foreground  Start VM in foreground console
  stop        Gracefully stop VM
  kill        Force-kill VM
  restart     Restart VM
  status      Show VM status
  doctor      Run preflight checks
  logs        Tail VM logs
  url         Print Home Assistant URL
  open        Open Home Assistant URL in browser
  help        Show this help

Environment overrides:
  HA_PORT=8124 $0 start
  RAM_MB=8192 CPUS=4 $0 start
  ALLOW_UNSUPPORTED_HAOS_IMAGE=1 $0 start
EOF_USAGE
}

cmd="${1:-start}"

case "$cmd" in
  start) start_background ;;
  foreground) start_foreground ;;
  stop) stop_vm ;;
  kill) kill_vm ;;
  restart) restart_vm ;;
  status) status_vm ;;
  doctor) doctor_vm ;;
  logs) tail_logs ;;
  url) print_url ;;
  open) open_url ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac
EOF_LAUNCH

chmod +x launch_ha.sh
