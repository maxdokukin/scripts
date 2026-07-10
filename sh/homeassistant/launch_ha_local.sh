#!/usr/bin/env bash
set -euo pipefail

# LaunchDaemons do not always provide HOME.
HOME="${HOME:-/var/root}"
export HOME

# launch_ha.sh
# Manage a Home Assistant OS VM on macOS using QEMU + HVF.
#
# Bridge/localhost-mode version with dedicated launchd mode.

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
  CONF_DIR="$DIR"
elif [[ -f "$DEFAULT_CONF" ]]; then
  # shellcheck source=/dev/null
  source "$DEFAULT_CONF"
  CONF_DIR="$(cd "$(dirname "$DEFAULT_CONF")" && pwd)"
else
  die "vm.conf not found. Run ./setup_ha.sh first."
fi

VM_NAME="${VM_NAME:-homeassistant}"
# Anchor the install to the directory vm.conf was loaded from. This overrides any
# absolute HA_DIR baked into vm.conf by setup_ha.sh, so the whole folder can be
# relocated (e.g. moved under /Library/Application Support) without regenerating
# the config. DISK_PATH/EFI_VARS stored in vm.conf are validated for existence
# elsewhere and fall back to HA_DIR-relative locations when stale.
HA_DIR="$CONF_DIR"
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

NETWORK_MODE="${NETWORK_MODE:-bridged}"
BRIDGE_IF="${BRIDGE_IF:-en2}"
VM_MAC="${VM_MAC:-52:54:00:6b:92:98}"
HA_LAN_IP="${HA_LAN_IP:-192.168.1.206}"

# USB passthrough controls.
# These defaults match the original hardcoded passthrough devices:
#   0x10c4:0xea60  CP210x / Silicon Labs USB serial adapter
#   0x2357:0x0604  TP-Link UB500 Bluetooth adapter
# On system boot, launchd can run before macOS has fully enumerated USB.
# Keep REQUIRE_USB_ON_START=1 if Home Assistant depends on these adapters.
PASSTHROUGH_CP210X="${PASSTHROUGH_CP210X:-1}"
PASSTHROUGH_UB500="${PASSTHROUGH_UB500:-1}"
USB_WAIT_SECONDS="${USB_WAIT_SECONDS:-180}"
USB_WAIT_INTERVAL_SECONDS="${USB_WAIT_INTERVAL_SECONDS:-5}"
REQUIRE_USB_ON_START="${REQUIRE_USB_ON_START:-1}"
SKIP_PASSTHROUGH=0

# Localhost test mode controls.
# --localhost switches from vmnet-bridged networking to QEMU user-mode NAT
# and forwards host 127.0.0.1:8123 to guest port 8123.
LOCALHOST_MODE=0
LOCALHOST_BIND_ADDR="${LOCALHOST_BIND_ADDR:-127.0.0.1}"

parse_cli_args() {
  local parsed_args=()
  local arg

  for arg in "$@"; do
    case "$arg" in
      --skip_passthrough|--skip-passthrough)
        SKIP_PASSTHROUGH=1
        PASSTHROUGH_CP210X=0
        PASSTHROUGH_UB500=0
        USB_WAIT_SECONDS=0
        ;;
      --localhost)
        LOCALHOST_MODE=1
        NETWORK_MODE="localhost"
        HA_LAN_IP="$LOCALHOST_BIND_ADDR"
        ;;
      *)
        parsed_args+=("$arg")
        ;;
    esac
  done

  if [[ "$SKIP_PASSTHROUGH" == "1" ]]; then
    export SKIP_PASSTHROUGH PASSTHROUGH_CP210X PASSTHROUGH_UB500 USB_WAIT_SECONDS
  fi

  if [[ "$LOCALHOST_MODE" == "1" ]]; then
    export LOCALHOST_MODE NETWORK_MODE HA_LAN_IP LOCALHOST_BIND_ADDR
  fi

  set -- "${parsed_args[@]}"
  PARSED_CMD="${1:-start}"
}

parse_cli_args "$@"

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
    QEMU_MACHINE="${QEMU_MACHINE:-virt,accel=hvf,highmem=on}"
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

ha_host() {
  if [[ "${LOCALHOST_MODE:-0}" == "1" || "${NETWORK_MODE:-}" == "localhost" ]]; then
    printf '%s\n' "${LOCALHOST_BIND_ADDR:-127.0.0.1}"
  else
    printf '%s\n' "$HA_LAN_IP"
  fi
}

ha_url() {
  printf 'http://%s:%s\n' "$(ha_host)" "$HA_PORT"
}

log_network_config() {
  if [[ "${LOCALHOST_MODE:-0}" == "1" || "${NETWORK_MODE:-}" == "localhost" ]]; then
    log "Network mode: localhost"
    log "Host forward: ${LOCALHOST_BIND_ADDR:-127.0.0.1}:${HA_PORT} -> guest:${HA_PORT}"
  else
    log "Network mode: bridged"
    log "Bridge interface: $BRIDGE_IF"
    log "VM MAC: $VM_MAC"
  fi
}

print_network_config() {
  if [[ "${LOCALHOST_MODE:-0}" == "1" || "${NETWORK_MODE:-}" == "localhost" ]]; then
    echo "Network mode: localhost"
    echo "Host forward: ${LOCALHOST_BIND_ADDR:-127.0.0.1}:${HA_PORT} -> guest:${HA_PORT}"
  else
    echo "Network mode: bridged"
    echo "Bridge interface: $BRIDGE_IF"
    echo "VM MAC: $VM_MAC"
    echo "HA LAN IP: $HA_LAN_IP"
  fi
}

tcp_port_open() {
  local host="$1"
  local port="$2"

  if nc -z -G 5 "$host" "$port" >/dev/null 2>&1; then
    return 0
  fi

  nc -z "$host" "$port" >/dev/null 2>&1
}

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

check_network_permissions() {
  if [[ "${LOCALHOST_MODE:-0}" == "1" || "${NETWORK_MODE:-}" == "localhost" ]]; then
    [[ -n "${LOCALHOST_BIND_ADDR:-}" ]] || die "LOCALHOST_BIND_ADDR is empty. Example: LOCALHOST_BIND_ADDR=127.0.0.1"
    return 0
  fi

  if [[ "$NETWORK_MODE" != "bridged" ]]; then
    die "Unsupported NETWORK_MODE='$NETWORK_MODE'. Use NETWORK_MODE=bridged, or pass --localhost for local NAT testing."
  fi

  [[ -n "$BRIDGE_IF" ]] || die "BRIDGE_IF is empty. Example: BRIDGE_IF=en2"
  [[ -n "$VM_MAC" ]] || die "VM_MAC is empty. Example: VM_MAC=52:54:00:6b:92:98"
  [[ -n "$HA_LAN_IP" ]] || die "HA_LAN_IP is empty. Example: HA_LAN_IP=192.168.1.206"

  if [[ "$(id -u)" -ne 0 ]]; then
    die "vmnet-bridged requires administrator/root privileges. Start with sudo, or run through the system LaunchDaemon. Use --localhost to test without vmnet-bridged."
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

list_usb_passthrough_devices() {
  if [[ "${PASSTHROUGH_CP210X:-1}" == "1" ]]; then
    printf '0x10c4 0xea60 CP210x_USB_serial_adapter\n'
  fi

  if [[ "${PASSTHROUGH_UB500:-1}" == "1" ]]; then
    printf '0x2357 0x0604 TP-Link_UB500_Bluetooth_adapter\n'
  fi
}

hex_to_dec() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="${value#0x}"
  printf '%d\n' "$((16#$value))"
}

usb_device_present_system_profiler() {
  local vendor="$1"
  local product="$2"
  local profile

  command -v system_profiler >/dev/null 2>&1 || return 1
  profile="$(system_profiler SPUSBDataType 2>/dev/null || true)"
  [[ -n "$profile" ]] || return 1

  vendor="$(printf '%s' "$vendor" | tr '[:upper:]' '[:lower:]')"
  product="$(printf '%s' "$product" | tr '[:upper:]' '[:lower:]')"

  printf '%s\n' "$profile" | awk -v vendor="$vendor" -v product="$product" '
    BEGIN { RS=""; found=0 }
    {
      block=tolower($0)
      if (index(block, "vendor id: " vendor) && index(block, "product id: " product)) {
        found=1
      }
    }
    END { exit found ? 0 : 1 }
  '
}

usb_device_present_ioreg() {
  local vendor="$1"
  local product="$2"
  local vendor_dec product_dec ioreg_out

  command -v ioreg >/dev/null 2>&1 || return 1
  vendor_dec="$(hex_to_dec "$vendor")"
  product_dec="$(hex_to_dec "$product")"
  ioreg_out="$(ioreg -p IOUSB -l -w 0 2>/dev/null || true)"
  [[ -n "$ioreg_out" ]] || return 1

  # This is a fallback check. It is intentionally simple because the two IDs are
  # specific to the passthrough adapters used by this VM configuration.
  printf '%s\n' "$ioreg_out" | grep -q '"idVendor" = '"$vendor_dec" || return 1
  printf '%s\n' "$ioreg_out" | grep -q '"idProduct" = '"$product_dec" || return 1
}

usb_device_present() {
  local vendor="$1"
  local product="$2"

  usb_device_present_system_profiler "$vendor" "$product" && return 0
  usb_device_present_ioreg "$vendor" "$product" && return 0
  return 1
}

usb_passthrough_enabled() {
  if [[ "${SKIP_PASSTHROUGH:-0}" == "1" ]]; then
    return 1
  fi

  [[ -n "$(list_usb_passthrough_devices)" ]]
}

wait_for_usb_devices() {
  if [[ "${SKIP_PASSTHROUGH:-0}" == "1" ]]; then
    log "USB passthrough disabled by --skip_passthrough. Skipping USB wait."
    return 0
  fi

  if ! usb_passthrough_enabled; then
    log "USB passthrough disabled. Skipping USB wait."
    return 0
  fi

  if [[ "${USB_WAIT_SECONDS:-180}" == "0" ]]; then
    warn "USB wait disabled with USB_WAIT_SECONDS=0."
    return 0
  fi

  local timeout="${USB_WAIT_SECONDS:-180}"
  local interval="${USB_WAIT_INTERVAL_SECONDS:-5}"
  local elapsed=0
  local vendor product label missing

  log "Waiting up to ${timeout}s for USB passthrough devices."

  while (( elapsed <= timeout )); do
    missing=0

    while read -r vendor product label; do
      [[ -n "$vendor" ]] || continue

      if usb_device_present "$vendor" "$product"; then
        log "USB present: $label ($vendor:$product)"
      else
        missing=1
        log "USB not ready yet: $label ($vendor:$product)"
      fi
    done < <(list_usb_passthrough_devices)

    if (( missing == 0 )); then
      log "All USB passthrough devices are present."
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  if [[ "${REQUIRE_USB_ON_START:-1}" == "1" ]]; then
    die "USB passthrough devices were not ready after ${timeout}s. Refusing to start QEMU. Set REQUIRE_USB_ON_START=0 to start anyway."
  fi

  warn "USB passthrough devices were not ready after ${timeout}s. Starting QEMU anyway because REQUIRE_USB_ON_START=0."
  return 0
}


normalize_arm64_memory_mode() {
  if [[ "$HOST_ARCH" != "arm64" ]]; then
    return 0
  fi

  # QEMU aarch64 virt with highmem=off has a 32-bit address-space limit.
  # On macOS/HVF this typically fails at RAM_MB=4096 with:
  # "Addressing limited to 32 bits, but memory exceeds it by 1073741824 bytes".
  local max_lowmem="${ARM64_MAX_RAM_WITH_HIGHMEM_OFF:-3072}"
  local auto_highmem="${ARM64_AUTO_ENABLE_HIGHMEM:-1}"

  if [[ "$QEMU_MACHINE" == *"highmem=off"* && "$RAM_MB" =~ ^[0-9]+$ && "$RAM_MB" -gt "$max_lowmem" ]]; then
    if [[ "$auto_highmem" == "1" ]]; then
      warn "ARM64 RAM is ${RAM_MB} MB but QEMU_MACHINE has highmem=off. Switching to highmem=on."
      QEMU_MACHINE="${QEMU_MACHINE//highmem=off/highmem=on}"
    else
      die "ARM64 RAM is ${RAM_MB} MB with highmem=off. Set RAM_MB=${max_lowmem} or use QEMU_MACHINE=virt,accel=hvf,highmem=on."
    fi
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
  )

  if [[ "${LOCALHOST_MODE:-0}" == "1" || "${NETWORK_MODE:-}" == "localhost" ]]; then
    QEMU_ARGS+=(
      -netdev "user,id=net0,hostfwd=tcp:${LOCALHOST_BIND_ADDR:-127.0.0.1}:${HA_PORT}-:${HA_PORT}"
      -device "virtio-net-pci,netdev=net0,mac=${VM_MAC}"
    )
  else
    QEMU_ARGS+=(
      -netdev "vmnet-bridged,id=net0,ifname=${BRIDGE_IF}"
      -device "virtio-net-pci,netdev=net0,mac=${VM_MAC}"
    )
  fi

  QEMU_ARGS+=(
    -device "virtio-rng-pci"
    -device "qemu-xhci,id=usbhub"
  )

  if [[ "${SKIP_PASSTHROUGH:-0}" == "1" ]]; then
    log "Skipping all USB passthrough QEMU devices because --skip_passthrough was used."
  else
    if [[ "${PASSTHROUGH_CP210X:-1}" == "1" ]]; then
      QEMU_ARGS+=(
        -device "usb-host,bus=usbhub.0,vendorid=0x10c4,productid=0xea60"
      )
    fi

    if [[ "${PASSTHROUGH_UB500:-1}" == "1" ]]; then
      QEMU_ARGS+=(
        -device "usb-host,bus=usbhub.0,id=usb_bt_ub500,vendorid=0x2357,productid=0x0604"
      )
    fi
  fi

  QEMU_ARGS+=(
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
  check_network_permissions
  normalize_arm64_memory_mode
  wait_for_usb_devices
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
  local url
  url="$(ha_url)"

  log "Waiting for Home Assistant on $url"

  while (( elapsed < max_seconds )); do
    if ! is_running; then
      log "QEMU exited before Home Assistant opened port $HA_PORT."
      show_recent_logs
      return 1
    fi

    if tcp_port_open "$(ha_host)" "$HA_PORT"; then
      log "Home Assistant port is open: $url"
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
  log "Open manually when ready: $url"
  return 0
}

start_background() {
  preflight

  if is_running; then
    log "$VM_NAME is already running. PID: $(cat "$PID_FILE")"
    log "URL: $(ha_url)"
    return 0
  fi

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
  log_network_config
  log "URL: $(ha_url)"

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

  rm -f "$QMP_SOCKET"
  touch "$SERIAL_LOG" "$QEMU_LOG"
  echo "$$" > "$PID_FILE"

  log "Starting $VM_NAME in foreground."
  log "QEMU: $QEMU_BIN"
  log "Disk: $DISK_PATH"
  log "Firmware: $EFI_CODE"
  [[ -n "${EFI_VARS:-}" ]] && log "Firmware vars: $EFI_VARS"
  log_network_config
  log "URL after boot: $(ha_url)"
  log "Exit QEMU console with Ctrl-A then X."

  exec "$QEMU_BIN" \
    "${QEMU_ARGS[@]}" \
    -display none \
    -serial mon:stdio
}

start_launchd() {
  preflight

  if is_running; then
    log "$VM_NAME is already running. PID: $(cat "$PID_FILE")"
    log "URL: $(ha_url)"
    return 0
  fi

  rm -f "$QMP_SOCKET"
  touch "$SERIAL_LOG" "$QEMU_LOG"
  echo "$$" > "$PID_FILE"

  log "Starting $VM_NAME for launchd."
  log "RAM: ${RAM_MB} MB"
  log "CPUs: $CPUS"
  log "Disk: $DISK_PATH"
  log "QEMU: $QEMU_BIN"
  log "Machine: $QEMU_MACHINE"
  log "CPU: $QEMU_CPU"
  log "Firmware: $EFI_CODE"
  [[ -n "${EFI_VARS:-}" ]] && log "Firmware vars: $EFI_VARS"
  [[ -n "${HAOS_ASSET_NAME:-}" ]] && log "HAOS asset: $HAOS_ASSET_NAME"
  log_network_config
  log "URL after boot: $(ha_url)"
  log "Serial log: $SERIAL_LOG"
  log "QEMU log: $QEMU_LOG"

  exec "$QEMU_BIN" \
    "${QEMU_ARGS[@]}" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    >>"$QEMU_LOG" 2>&1
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
    echo "URL: $(ha_url)"
    print_network_config
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

    if tcp_port_open "$(ha_host)" "$HA_PORT"; then
      echo "Home Assistant port: open"
    else
      echo "Home Assistant port: not open yet"
    fi
  else
    echo "$VM_NAME is not running."
    echo "URL: $(ha_url)"
    print_network_config
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
  print_network_config
  echo "URL: $(ha_url)"
}

tail_logs() {
  refresh_runtime_paths
  touch "$SERIAL_LOG" "$QEMU_LOG"
  log "Tailing logs. Press Ctrl-C to stop."
  tail -n 120 -f "$SERIAL_LOG" "$QEMU_LOG"
}

print_url() {
  ha_url
}

open_url() {
  local url
  url="$(ha_url)"
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
  $0 [--skip_passthrough] [--localhost] [command]
  $0 [command] [--skip_passthrough] [--localhost]

Commands:
  start       Start VM in background
  launchd     Start VM in non-interactive foreground mode for LaunchDaemon
  foreground  Start VM in interactive foreground console
  stop        Gracefully stop VM
  kill        Force-kill VM
  restart     Restart VM
  status      Show VM status
  doctor      Run preflight checks
  logs        Tail VM logs
  url         Print Home Assistant URL
  open        Open Home Assistant URL in browser
  help        Show this help

Options:
  --skip_passthrough  Ignore all USB passthrough config for this run.
                      Equivalent to PASSTHROUGH_CP210X=0 PASSTHROUGH_UB500=0 USB_WAIT_SECONDS=0.
  --localhost         Use QEMU user-mode NAT and expose Home Assistant at http://127.0.0.1:8123.
                      This bypasses vmnet-bridged, BRIDGE_IF, and HA_LAN_IP for local testing.

Environment overrides:
  RAM_MB=8192 CPUS=4 $0 start
  RAM_MB=3072 $0 --localhost --skip_passthrough start
  ALLOW_UNSUPPORTED_HAOS_IMAGE=1 $0 start
  USB_WAIT_SECONDS=180 $0 start
  REQUIRE_USB_ON_START=0 $0 start
  PASSTHROUGH_CP210X=0 $0 start
  PASSTHROUGH_UB500=0 $0 start
  $0 --skip_passthrough start
  $0 --localhost start
  $0 --localhost --skip_passthrough start
  $0 launchd --skip_passthrough
  $0 launchd --localhost

Network settings in vm.conf:
  NETWORK_MODE=bridged
  BRIDGE_IF=en2
  VM_MAC=52:54:00:6b:92:98
  HA_LAN_IP=192.168.1.206
  LOCALHOST_BIND_ADDR=127.0.0.1

USB settings in vm.conf:
  PASSTHROUGH_CP210X=1
  PASSTHROUGH_UB500=1
  USB_WAIT_SECONDS=180
  USB_WAIT_INTERVAL_SECONDS=5
  REQUIRE_USB_ON_START=1

ARM64 memory settings:
  QEMU_MACHINE=virt,accel=hvf,highmem=on
  ARM64_AUTO_ENABLE_HIGHMEM=1
  ARM64_MAX_RAM_WITH_HIGHMEM_OFF=3072
EOF_USAGE
}

cmd="${PARSED_CMD:-start}"

case "$cmd" in
  start) start_background ;;
  launchd) start_launchd ;;
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
