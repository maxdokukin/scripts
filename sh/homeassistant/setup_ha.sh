cat > setup_ha.sh <<'EOF_SETUP'
#!/usr/bin/env bash
set -euo pipefail

# setup_ha.sh
# Home Assistant OS VM setup for macOS using QEMU + HVF.
#
# Key fix:
#   On Intel/x86_64 Macs this downloads the supported VM/KVM image:
#     haos_ova-<version>.qcow2.xz
#   not the bare-metal generic-x86-64 .img.xz image.
#
# This script intentionally does not overwrite launch_ha.sh. It writes vm.conf
# and prepares the correct qcow2 disk. The launcher can be revised separately.
#
# Usage:
#   chmod +x setup_ha.sh
#   ./setup_ha.sh
#
# Common overrides:
#   HA_DIR="$HOME/haos-vm" ./setup_ha.sh
#   RAM_MB=8192 CPUS=4 DISK_SIZE=96G ./setup_ha.sh
#   HAOS_VERSION=17.3 ./setup_ha.sh
#   FORCE_RECREATE_DISK=1 ./setup_ha.sh
#   ALLOW_SOURCE_BUILDS=1 ./setup_ha.sh
#   AUTO_INSTALL_MACPORTS=0 ./setup_ha.sh
#   INSTALL_HOMEBREW=1 ./setup_ha.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VM_NAME="${VM_NAME:-homeassistant}"
HA_DIR="${HA_DIR:-$SCRIPT_DIR}"
RAM_MB="${RAM_MB:-4096}"
CPUS="${CPUS:-2}"
DISK_SIZE="${DISK_SIZE:-64G}"
HA_PORT="${HA_PORT:-8123}"

AUTO_INSTALL_MACPORTS="${AUTO_INSTALL_MACPORTS:-1}"
ALLOW_SOURCE_BUILDS="${ALLOW_SOURCE_BUILDS:-0}"
FORCE_REINSTALL_QEMU="${FORCE_REINSTALL_QEMU:-0}"
FORCE_RECREATE_DISK="${FORCE_RECREATE_DISK:-0}"
INSTALL_HOMEBREW="${INSTALL_HOMEBREW:-0}"
BREW_AUTO_UPDATE="${BREW_AUTO_UPDATE:-0}"
HAOS_VERSION="${HAOS_VERSION:-latest}"

RELEASES_API="https://api.github.com/repos/home-assistant/operating-system/releases"
LATEST_RELEASE_API="$RELEASES_API/latest"
MACPORTS_INSTALL_PAGE="https://www.macports.org/install.php"

log() {
  printf '[setup-ha] %s\n' "$*"
}

die() {
  printf '[setup-ha] ERROR: %s\n' "$*" >&2
  exit 1
}

bootstrap_path() {
  if [[ -x /opt/local/bin/port ]]; then
    export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
  fi

  if [[ -x /opt/homebrew/bin/brew ]] && ! command -v brew >/dev/null 2>&1; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]] && ! command -v brew >/dev/null 2>&1; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This script is intended for macOS."
  command -v curl >/dev/null 2>&1 || die "curl not found."
  command -v shasum >/dev/null 2>&1 || die "shasum not found."
}

detect_macos() {
  MACOS_VERSION="$(sw_vers -productVersion)"
  MACOS_MAJOR="$(printf '%s\n' "$MACOS_VERSION" | cut -d. -f1)"

  case "$MACOS_MAJOR" in
    11) MACOS_CODENAME="BigSur" ;;
    12) MACOS_CODENAME="Monterey" ;;
    13) MACOS_CODENAME="Ventura" ;;
    14) MACOS_CODENAME="Sonoma" ;;
    15) MACOS_CODENAME="Sequoia" ;;
    26) MACOS_CODENAME="Tahoe" ;;
    *) MACOS_CODENAME="" ;;
  esac

  log "macOS version: $MACOS_VERSION"
}

configure_speed() {
  local cores
  cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

  export HOMEBREW_MAKE_JOBS="${HOMEBREW_MAKE_JOBS:-$cores}"
  export HOMEBREW_NO_INSTALL_CLEANUP="${HOMEBREW_NO_INSTALL_CLEANUP:-1}"

  if [[ "$BREW_AUTO_UPDATE" != "1" ]]; then
    export HOMEBREW_NO_AUTO_UPDATE=1
  fi

  log "Homebrew build jobs: $HOMEBREW_MAKE_JOBS"
  log "Homebrew auto-update: $BREW_AUTO_UPDATE"
  log "Allow source builds: $ALLOW_SOURCE_BUILDS"
}

detect_platform() {
  HOST_ARCH="$(uname -m)"

  case "$HOST_ARCH" in
    x86_64)
      # Correct image for an Intel Mac VM: Open Virtual Appliance / KVM qcow2.
      HA_BOARD="ova"
      HAOS_ASSET_PREFIX="haos_ova"
      HAOS_IMAGE_KIND="qcow2"
      HAOS_IMAGE_IS_VIRTUAL="1"
      QEMU_SYSTEM_NAME="qemu-system-x86_64"
      QEMU_REQUIRED_VARIANT="+target_x86_64"
      QEMU_MACHINE="${QEMU_MACHINE:-q35,accel=hvf}"
      QEMU_CPU="${QEMU_CPU:-host}"
      FIRMWARE_MODE="${FIRMWARE_MODE:-auto}"
      FIRMWARE_PATTERNS=("OVMF_CODE.fd" "OVMF.fd" "edk2-x86_64-code.fd")
      EFI_VAR_PATTERNS=("edk2-x86_64-vars.fd" "OVMF_VARS.fd" "OVMF_VARS_4M.fd" "OVMF_VARS.ms.fd")
      ;;
    arm64)
      # Apple Silicon cannot boot the x86_64 OVA under HVF. Use the ARM64 qcow2.
      HA_BOARD="generic-aarch64"
      HAOS_ASSET_PREFIX="haos_generic-aarch64"
      HAOS_IMAGE_KIND="qcow2"
      HAOS_IMAGE_IS_VIRTUAL="1"
      QEMU_SYSTEM_NAME="qemu-system-aarch64"
      QEMU_REQUIRED_VARIANT="+target_arm"
      QEMU_MACHINE="${QEMU_MACHINE:-virt,accel=hvf,highmem=off}"
      QEMU_CPU="${QEMU_CPU:-host}"
      FIRMWARE_MODE="${FIRMWARE_MODE:-auto}"
      FIRMWARE_PATTERNS=("edk2-aarch64-code.fd" "QEMU_EFI.fd")
      EFI_VAR_PATTERNS=()
      ;;
    *)
      die "Unsupported Mac architecture: $HOST_ARCH"
      ;;
  esac

  DISK_PATH="${DISK_PATH:-$HA_DIR/${VM_NAME}-${HA_BOARD}.qcow2}"

  log "Host architecture: $HOST_ARCH"
  log "Selected HAOS VM board: $HA_BOARD"
  log "Selected HAOS asset prefix: $HAOS_ASSET_PREFIX"
  log "Required QEMU target: $QEMU_REQUIRED_VARIANT"
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

ensure_ruby_json() {
  command -v ruby >/dev/null 2>&1 || die "Ruby is required to parse GitHub release JSON, but ruby was not found."
  ruby -rjson -e 'JSON.parse("{\"ok\":true}")' >/dev/null 2>&1 || die "Ruby JSON support is not available."
}

ensure_homebrew_optional() {
  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$INSTALL_HOMEBREW" == "1" ]]; then
    log "Homebrew not found. Installing Homebrew because INSTALL_HOMEBREW=1."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    bootstrap_path
  fi

  command -v brew >/dev/null 2>&1
}

brew_install_bottle_only() {
  local pkg="$1"

  command -v brew >/dev/null 2>&1 || return 1

  if brew list "$pkg" >/dev/null 2>&1; then
    log "$pkg already installed via Homebrew."
    return 0
  fi

  log "Trying Homebrew bottle for $pkg."
  brew install --force-bottle "$pkg"
}

macports_pkg_url() {
  local version
  version="$(curl -fsSL "$MACPORTS_INSTALL_PAGE" | sed -nE 's/.*MacPorts version ([0-9.]+) is.*/\1/p' | head -n 1)"
  [[ -n "$version" ]] || version="${MACPORTS_VERSION:-2.12.5}"
  [[ -n "$MACOS_CODENAME" ]] || die "Unknown MacPorts codename for macOS major version $MACOS_MAJOR. Install MacPorts manually or set MACPORTS_VERSION."

  printf 'https://github.com/macports/macports-base/releases/download/v%s/MacPorts-%s-%s-%s.pkg\n' \
    "$version" "$version" "$MACOS_MAJOR" "$MACOS_CODENAME"
}

install_macports_if_needed() {
  if find_port_bin; then
    log "MacPorts found: $PORT_BIN"
    return 0
  fi

  [[ "$AUTO_INSTALL_MACPORTS" == "1" ]] || die "MacPorts is not installed. Install it or rerun with AUTO_INSTALL_MACPORTS=1."

  mkdir -p "$HA_DIR/downloads"

  local url pkg
  url="$(macports_pkg_url)"
  pkg="$HA_DIR/downloads/$(basename "$url")"

  log "Downloading MacPorts installer: $url"
  curl -fL --retry 3 -o "$pkg" "$url"

  log "Installing MacPorts. sudo may ask for your password."
  sudo installer -pkg "$pkg" -target /

  export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
  find_port_bin || die "MacPorts installation finished, but port was not found at /opt/local/bin/port."
}

macports_install_or_fix_qemu() {
  install_macports_if_needed

  local installed=0
  if "$PORT_BIN" installed qemu >/dev/null 2>&1; then
    installed=1
  fi

  if [[ "$FORCE_REINSTALL_QEMU" == "1" ]]; then
    log "FORCE_REINSTALL_QEMU=1 set. Reinstalling qemu with $QEMU_REQUIRED_VARIANT."
    sudo "$PORT_BIN" -N deactivate qemu >/dev/null 2>&1 || true
    sudo "$PORT_BIN" -N uninstall qemu >/dev/null 2>&1 || true
    installed=0
  fi

  if [[ "$installed" == "1" ]] && find_program "$QEMU_SYSTEM_NAME" >/dev/null 2>&1 && find_program qemu-img >/dev/null 2>&1; then
    log "MacPorts qemu has required binaries."
    return 0
  fi

  if [[ "$installed" == "1" ]]; then
    log "MacPorts qemu is installed but missing $QEMU_SYSTEM_NAME. Fixing variant."
    if sudo "$PORT_BIN" -N upgrade --enforce-variants qemu "$QEMU_REQUIRED_VARIANT"; then
      :
    else
      log "Variant upgrade failed. Reinstalling qemu with $QEMU_REQUIRED_VARIANT."
      sudo "$PORT_BIN" -N deactivate qemu >/dev/null 2>&1 || true
      sudo "$PORT_BIN" -N uninstall qemu >/dev/null 2>&1 || true
      installed=0
    fi
  fi

  if [[ "$installed" == "0" ]]; then
    log "Installing qemu with MacPorts and $QEMU_REQUIRED_VARIANT."
    if [[ "$ALLOW_SOURCE_BUILDS" == "1" ]]; then
      sudo "$PORT_BIN" -N install qemu "$QEMU_REQUIRED_VARIANT"
    else
      if ! sudo "$PORT_BIN" -N -b install qemu "$QEMU_REQUIRED_VARIANT"; then
        die "MacPorts binary-only qemu install failed. Rerun with ALLOW_SOURCE_BUILDS=1 if you accept a source build."
      fi
    fi
  fi

  QEMU_BIN="$(find_program "$QEMU_SYSTEM_NAME" || true)"
  QEMU_IMG="$(find_program qemu-img || true)"

  [[ -n "${QEMU_BIN:-}" && -x "$QEMU_BIN" ]] || die "$QEMU_SYSTEM_NAME was still not found after QEMU install."
  [[ -n "${QEMU_IMG:-}" && -x "$QEMU_IMG" ]] || die "qemu-img was still not found after QEMU install."

  log "QEMU binary: $QEMU_BIN"
  log "qemu-img: $QEMU_IMG"
}

ensure_qemu() {
  if QEMU_BIN="$(find_program "$QEMU_SYSTEM_NAME")" && QEMU_IMG="$(find_program qemu-img)"; then
    log "QEMU found: $QEMU_BIN"
    log "qemu-img found: $QEMU_IMG"
    return 0
  fi

  if ensure_homebrew_optional; then
    log "Trying Homebrew QEMU bottle only."
    if brew_install_bottle_only qemu; then
      QEMU_BIN="$(find_program "$QEMU_SYSTEM_NAME" || true)"
      QEMU_IMG="$(find_program qemu-img || true)"
      if [[ -n "${QEMU_BIN:-}" && -x "$QEMU_BIN" && -n "${QEMU_IMG:-}" && -x "$QEMU_IMG" ]]; then
        log "QEMU installed via Homebrew bottle: $QEMU_BIN"
        return 0
      fi
    else
      log "Homebrew QEMU bottle unavailable or failed. Skipping Homebrew source build."
    fi
  fi

  macports_install_or_fix_qemu
}

ensure_xz() {
  if XZ_BIN="$(find_program xz)"; then
    log "xz found: $XZ_BIN"
    return 0
  fi

  if ensure_homebrew_optional && brew_install_bottle_only xz; then
    XZ_BIN="$(find_program xz || true)"
    if [[ -n "${XZ_BIN:-}" && -x "$XZ_BIN" ]]; then
      log "xz installed via Homebrew: $XZ_BIN"
      return 0
    fi
  fi

  install_macports_if_needed

  if ! "$PORT_BIN" installed xz >/dev/null 2>&1; then
    log "Installing xz with MacPorts."
    sudo "$PORT_BIN" -N -b install xz || sudo "$PORT_BIN" -N install xz
  fi

  XZ_BIN="$(find_program xz)" || die "xz install completed, but xz was not found."
  log "xz installed/found: $XZ_BIN"
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

find_firmware() {
  EFI_CODE="${EFI_CODE:-}"

  if [[ -n "$EFI_CODE" && -r "$EFI_CODE" && -s "$EFI_CODE" ]]; then
    log "UEFI firmware supplied: $EFI_CODE"
    return 0
  fi

  local pattern root candidate
  for pattern in "${FIRMWARE_PATTERNS[@]}"; do
    while IFS= read -r root; do
      [[ -d "$root" ]] || continue
      candidate="$(find "$root" -type f -name "$pattern" 2>/dev/null | head -n 1 || true)"
      if [[ -n "$candidate" && -r "$candidate" && -s "$candidate" ]]; then
        EFI_CODE="$candidate"
        log "UEFI firmware found: $EFI_CODE"
        return 0
      fi
    done < <(firmware_roots)
  done

  log "Could not find UEFI firmware in standard paths. Trying MacPorts edk2."
  install_macports_if_needed
  sudo "$PORT_BIN" -N -b install edk2 || sudo "$PORT_BIN" -N install edk2 || true

  for pattern in "${FIRMWARE_PATTERNS[@]}"; do
    candidate="$(find /opt/local -type f -name "$pattern" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$candidate" && -r "$candidate" && -s "$candidate" ]]; then
      EFI_CODE="$candidate"
      log "UEFI firmware found after edk2 install: $EFI_CODE"
      return 0
    fi
  done

  die "Could not find QEMU UEFI firmware. Tried: ${FIRMWARE_PATTERNS[*]}"
}

prepare_efi_vars() {
  EFI_VARS="${EFI_VARS:-}"

  if [[ "$HOST_ARCH" != "x86_64" ]]; then
    EFI_VARS=""
    return 0
  fi

  if [[ "$FIRMWARE_MODE" == "bios" ]]; then
    EFI_VARS=""
    return 0
  fi

  if [[ -n "$EFI_VARS" && -r "$EFI_VARS" && -s "$EFI_VARS" ]]; then
    log "UEFI vars supplied: $EFI_VARS"
    return 0
  fi

  local vm_vars="$HA_DIR/${VM_NAME}.efi_vars.fd"
  if [[ -r "$vm_vars" && -s "$vm_vars" ]]; then
    EFI_VARS="$vm_vars"
    log "UEFI vars found: $EFI_VARS"
    return 0
  fi

  local pattern root template
  for pattern in "${EFI_VAR_PATTERNS[@]}"; do
    while IFS= read -r root; do
      [[ -d "$root" ]] || continue
      template="$(find "$root" -type f -name "$pattern" 2>/dev/null | head -n 1 || true)"
      if [[ -n "$template" && -r "$template" && -s "$template" ]]; then
        mkdir -p "$HA_DIR"
        cp "$template" "$vm_vars.tmp"
        chmod u+w "$vm_vars.tmp" 2>/dev/null || true
        mv "$vm_vars.tmp" "$vm_vars"
        EFI_VARS="$vm_vars"
        log "UEFI vars created: $EFI_VARS"
        return 0
      fi
    done < <(firmware_roots)
  done

  log "UEFI vars template not found. Continuing with code-only pflash."
  EFI_VARS=""
}

json_get_tag() {
  ruby -rjson -e 'data = JSON.parse(STDIN.read); puts(data["tag_name"] || "")'
}

json_get_asset_url() {
  local name="$1"
  ruby -rjson -e '
    name = ARGV[0]
    data = JSON.parse(STDIN.read)
    asset = data["assets"].find { |a| a["name"] == name }
    puts(asset ? asset["browser_download_url"] : "")
  ' "$name"
}

json_get_asset_digest() {
  local name="$1"
  ruby -rjson -e '
    name = ARGV[0]
    data = JSON.parse(STDIN.read)
    asset = data["assets"].find { |a| a["name"] == name }
    digest = asset && asset["digest"] ? asset["digest"] : ""
    puts digest.sub(/^sha256:/, "")
  ' "$name"
}

json_list_qcow2_assets() {
  ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    data["assets"].select { |a| a["name"].end_with?(".qcow2.xz") }.each { |a| puts "  - #{a["name"]}" }
  '
}

load_release_metadata() {
  mkdir -p "$HA_DIR/downloads"

  local api_url
  if [[ "$HAOS_VERSION" == "latest" || -z "$HAOS_VERSION" ]]; then
    api_url="$LATEST_RELEASE_API"
    log "Reading latest Home Assistant OS release metadata."
  else
    api_url="$RELEASES_API/tags/$HAOS_VERSION"
    log "Reading Home Assistant OS release metadata for tag: $HAOS_VERSION"
  fi

  RELEASE_JSON="$(curl -fsSL "$api_url")"
  RELEASE_TAG="$(printf '%s' "$RELEASE_JSON" | json_get_tag)"
  RELEASE_VERSION="${RELEASE_TAG#v}"

  [[ -n "$RELEASE_VERSION" && "$RELEASE_VERSION" != "null" ]] || die "Could not determine HAOS release version."

  ASSET_NAME="${HAOS_ASSET_PREFIX}-${RELEASE_VERSION}.${HAOS_IMAGE_KIND}.xz"
  ASSET_URL="$(printf '%s' "$RELEASE_JSON" | json_get_asset_url "$ASSET_NAME")"
  ASSET_DIGEST="$(printf '%s' "$RELEASE_JSON" | json_get_asset_digest "$ASSET_NAME")"

  if [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]]; then
    log "Could not find expected asset: $ASSET_NAME"
    log "Available .qcow2.xz assets in this release:"
    printf '%s' "$RELEASE_JSON" | json_list_qcow2_assets | sed 's/^/[setup-ha] /'
    die "No matching HAOS VM image asset found for $HOST_ARCH."
  fi

  log "HAOS release: $RELEASE_VERSION"
  log "HAOS VM image asset: $ASSET_NAME"
}

download_correct_haos_vm_disk() {
  mkdir -p "$HA_DIR/images" "$HA_DIR/logs" "$HA_DIR/downloads"

  XZ_PATH="$HA_DIR/images/$ASSET_NAME"

  if [[ ! -f "$XZ_PATH" ]]; then
    log "Downloading $ASSET_NAME."
    curl -fL --retry 3 --continue-at - -o "$XZ_PATH" "$ASSET_URL"
  else
    log "Using existing download: $XZ_PATH"
  fi

  if [[ -n "$ASSET_DIGEST" ]]; then
    log "Verifying SHA-256 digest."
    printf '%s  %s\n' "$ASSET_DIGEST" "$XZ_PATH" | shasum -a 256 -c -
  else
    log "No release digest found in GitHub API response; skipping checksum verification."
  fi

  if [[ -f "$DISK_PATH" ]]; then
    if [[ "$FORCE_RECREATE_DISK" == "1" ]]; then
      local stamp backup
      stamp="$(date +%Y%m%d-%H%M%S)"
      backup="$DISK_PATH.backup-$stamp"
      log "Existing disk found. Moving it to: $backup"
      mv "$DISK_PATH" "$backup"
    else
      log "Disk already exists and will not be overwritten: $DISK_PATH"
      log "Set FORCE_RECREATE_DISK=1 to rebuild it from $ASSET_NAME."
      return 0
    fi
  fi

  log "Decompressing supported VM qcow2 image to: $DISK_PATH"
  "$XZ_BIN" -T0 -dc "$XZ_PATH" > "$DISK_PATH.tmp"
  "$QEMU_IMG" info "$DISK_PATH.tmp" >/dev/null
  mv "$DISK_PATH.tmp" "$DISK_PATH"

  log "Growing qcow2 virtual disk to $DISK_SIZE if possible."
  "$QEMU_IMG" resize "$DISK_PATH" "$DISK_SIZE" >/dev/null || log "Resize skipped. Existing disk may already be larger than $DISK_SIZE."
}

write_config() {
  mkdir -p "$HA_DIR"

  {
    printf '# Generated by setup_ha.sh on %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# This config points the launcher at a supported Home Assistant OS VM disk.\n'
    printf 'VM_NAME=%q\n' "$VM_NAME"
    printf 'HOST_ARCH=%q\n' "$HOST_ARCH"
    printf 'HA_BOARD=%q\n' "$HA_BOARD"
    printf 'HAOS_IMAGE_KIND=%q\n' "$HAOS_IMAGE_KIND"
    printf 'HAOS_IMAGE_IS_VIRTUAL=%q\n' "$HAOS_IMAGE_IS_VIRTUAL"
    printf 'HAOS_ASSET_NAME=%q\n' "$ASSET_NAME"
    printf 'HAOS_ASSET_URL=%q\n' "$ASSET_URL"
    printf 'RELEASE_VERSION=%q\n' "$RELEASE_VERSION"
    printf 'HA_DIR=%q\n' "$HA_DIR"
    printf 'DISK_PATH=%q\n' "$DISK_PATH"
    printf 'RAM_MB=%q\n' "$RAM_MB"
    printf 'CPUS=%q\n' "$CPUS"
    printf 'DISK_SIZE=%q\n' "$DISK_SIZE"
    printf 'HA_PORT=%q\n' "$HA_PORT"
    printf 'QEMU_BIN=%q\n' "$QEMU_BIN"
    printf 'QEMU_IMG=%q\n' "$QEMU_IMG"
    printf 'QEMU_MACHINE=%q\n' "$QEMU_MACHINE"
    printf 'QEMU_CPU=%q\n' "$QEMU_CPU"
    printf 'EFI_CODE=%q\n' "$EFI_CODE"
    printf 'EFI_VARS=%q\n' "${EFI_VARS:-}"
    printf 'FIRMWARE_MODE=%q\n' "$FIRMWARE_MODE"
  } > "$HA_DIR/vm.conf"

  log "Wrote config: $HA_DIR/vm.conf"
}

print_finish() {
  cat <<EOF_FINISH

Done.

Correct VM image prepared:
  Asset: $ASSET_NAME
  Board: $HA_BOARD
  Disk:  $DISK_PATH

Install directory:
  $HA_DIR

Config written:
  $HA_DIR/vm.conf

Launch script status:
  This setup script did not overwrite launch_ha.sh.
  Next step is to revise launch_ha.sh to use this vm.conf cleanly.

Useful checks now:
  cd "$HA_DIR"
  cat vm.conf
  ls -lh "$DISK_PATH"

QEMU:
  $QEMU_BIN

qemu-img:
  $QEMU_IMG

HAOS:
  Version: $RELEASE_VERSION
  Image:   supported VM qcow2
EOF_FINISH
}

main() {
  bootstrap_path
  require_macos
  detect_macos
  configure_speed
  ensure_ruby_json
  detect_platform
  ensure_xz
  ensure_qemu
  find_firmware
  prepare_efi_vars
  load_release_metadata
  download_correct_haos_vm_disk
  write_config
  print_finish
}

main "$@"
EOF_SETUP

chmod +x setup_ha.sh
