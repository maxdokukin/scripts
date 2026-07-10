#!/bin/sh

# setup.sh for ASUS / Asuswrt-Merlin /jffs/scripts LAN no-WAN policy.
#
# Policy installed by this setup:
#   - When /jffs/scripts/lan_no_wan.sh apply is run:
#       empty whitelist     -> block all 192.168.1.0/24 clients from IPv4 WAN
#       non-empty whitelist -> allow listed MACs, block all other 192.168.1.0/24 clients from IPv4 WAN
#   - LAN-to-LAN and client-to-router traffic are not intentionally blocked.
#   - IPv6 is not touched by this setup.
#
# Safety defaults:
#   - Running this setup does NOT apply firewall rules.
#   - Running this setup does NOT enable boot autostart.
#   - Existing whitelist_mac.txt is preserved unless --reset-whitelist is used.
#   - Existing firewall-start is backed up and replaced only if it is missing,
#     already references lan_no_wan.sh, is already LAN_NO_WAN_MANAGED,
#     or --replace-firewall-start is supplied.
#
# Normal use:
#   sh setup.sh
#   /jffs/scripts/lan_no_wan.sh apply
#
# Optional:
#   sh setup.sh --apply-now
#   sh setup.sh --enable-autostart
#   sh setup.sh --replace-firewall-start
#   sh setup.sh --reset-whitelist
#   sh setup.sh --disable-autostart

PATH=/sbin:/bin:/usr/sbin:/usr/bin

SCRIPT_DIR="/jffs/scripts"
WHITELIST="$SCRIPT_DIR/whitelist_mac.txt"
POLICY="$SCRIPT_DIR/lan_no_wan.sh"
APPEND="$SCRIPT_DIR/append_whitelist.sh"
FWSTART="$SCRIPT_DIR/firewall-start"
AUTOSTART="$SCRIPT_DIR/lan_no_wan.autostart"
DISABLE_FILE="$SCRIPT_DIR/lan_no_wan.disable"
STAMP="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
[ -n "$STAMP" ] || STAMP="unknown-time"

APPLY_NOW=0
ENABLE_AUTOSTART=0
DISABLE_AUTOSTART=0
REPLACE_FIREWALL_START=0
RESET_WHITELIST=0

usage() {
    cat <<USAGE
Usage:
  sh setup.sh [options]

Options:
  --apply-now                Install scripts, then run lan_no_wan.sh apply.
                             If whitelist is empty, this blocks all 192.168.1.0/24 IPv4 WAN.

  --enable-autostart         Create /jffs/scripts/lan_no_wan.autostart.
                             firewall-start will apply the policy during firewall startup.

  --disable-autostart        Remove /jffs/scripts/lan_no_wan.autostart and run policy cleanup.

  --replace-firewall-start   Replace an existing unknown firewall-start after backing it up.
                             Without this, unknown existing firewall-start is not overwritten.

  --reset-whitelist          Back up and replace whitelist_mac.txt with an empty file.

  -h, --help                 Show this help.

Default behavior:
  Installs lan_no_wan.sh and append_whitelist.sh.
  Preserves whitelist_mac.txt if it exists.
  Installs a safe firewall-start wrapper only if safe to replace.
  Does not apply firewall rules.
  Does not enable boot autostart.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply-now)
            APPLY_NOW=1
            ;;
        --enable-autostart)
            ENABLE_AUTOSTART=1
            ;;
        --disable-autostart)
            DISABLE_AUTOSTART=1
            ;;
        --replace-firewall-start)
            REPLACE_FIREWALL_START=1
            ;;
        --reset-whitelist)
            RESET_WHITELIST=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

say() {
    printf '%s\n' "$*"
}

backup_file() {
    f="$1"
    [ -e "$f" ] || return 0
    b="$f.bak.$STAMP"
    cp -p "$f" "$b"
    say "Backed up $f -> $b"
}

mkdir -p "$SCRIPT_DIR"

if [ "$RESET_WHITELIST" -eq 1 ]; then
    backup_file "$WHITELIST"
    cat > "$WHITELIST" <<'WHITELIST_EOF'
# WAN whitelist by MAC.
#
# Policy semantics when /jffs/scripts/lan_no_wan.sh apply is run:
#   empty file        -> block all 192.168.1.0/24 clients from IPv4 WAN
#   one or more MACs  -> allow those MACs, block all other 192.168.1.0/24 clients from IPv4 WAN
#
# One MAC per line. Comments are allowed.
# Example:
# aa:bb:cc:dd:ee:ff  # laptop
WHITELIST_EOF
    chmod 644 "$WHITELIST"
else
    if [ ! -f "$WHITELIST" ]; then
        cat > "$WHITELIST" <<'WHITELIST_EOF'
# WAN whitelist by MAC.
#
# Policy semantics when /jffs/scripts/lan_no_wan.sh apply is run:
#   empty file        -> block all 192.168.1.0/24 clients from IPv4 WAN
#   one or more MACs  -> allow those MACs, block all other 192.168.1.0/24 clients from IPv4 WAN
#
# One MAC per line. Comments are allowed.
# Example:
# aa:bb:cc:dd:ee:ff  # laptop
WHITELIST_EOF
        chmod 644 "$WHITELIST"
        say "Created $WHITELIST"
    else
        say "Preserved existing $WHITELIST"
    fi
fi

backup_file "$POLICY"
cat > "$POLICY" <<'LAN_NO_WAN_EOF'
#!/bin/sh

# LAN no-WAN policy for Asuswrt-Merlin style /jffs/scripts.
#
# What this script does when run with "apply":
#   - Finds the interface for LAN_NET, default 192.168.1.0/24.
#   - Finds the current WAN egress interface.
#   - Creates an IPv4 filter chain named LAN_NO_WAN4.
#   - Adds RETURN rules for MACs in whitelist_mac.txt.
#   - Adds a final DROP.
#   - Hooks only routed traffic matching:
#       input interface = LAN interface
#       source subnet   = 192.168.1.0/24
#       output interface = WAN interface
#
# Important behavior:
#   - Empty whitelist means default-deny for WAN: all 192.168.1.x clients lose IPv4 internet.
#   - Non-empty whitelist means listed MACs keep IPv4 internet; others lose IPv4 internet.
#   - Router access and LAN-to-LAN traffic are not intentionally matched because the hook uses -o WAN_IF.
#   - IPv6 is not touched.
#
# Emergency off:
#   /jffs/scripts/lan_no_wan.sh off
#   touch /jffs/scripts/lan_no_wan.disable

PATH=/sbin:/bin:/usr/sbin:/usr/bin

SCRIPTS_DIR="/jffs/scripts"
TAG="lan-no-wan"
CHAIN="LAN_NO_WAN4"
TEST_CHAIN="LAN_NO_WAN4_TEST"

LAN_NET="${LAN_NET:-192.168.1.0/24}"
WHITELIST="${WHITELIST:-$SCRIPTS_DIR/whitelist_mac.txt}"
DISABLE_FILE="$SCRIPTS_DIR/lan_no_wan.disable"
LOG_FILE="/tmp/lan-no-wan.log"
LOCKDIR="/tmp/lan-no-wan.lock"

IPT="$(command -v iptables 2>/dev/null)"
[ -z "$IPT" ] && IPT="iptables"

WAIT=""
if "$IPT" -w 1 -L >/dev/null 2>&1; then
    WAIT="-w 5"
fi

log() {
    msg="$*"
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    [ -n "$ts" ] || ts="date-unavailable"

    printf '%s [%s] %s\n' "$ts" "$TAG" "$msg" >&2
    printf '%s [%s] %s\n' "$ts" "$TAG" "$msg" >> "$LOG_FILE" 2>/dev/null
    logger -t "$TAG" "$msg" 2>/dev/null
}

ipt() {
    log "+ $IPT $WAIT $*"
    out="$("$IPT" $WAIT "$@" 2>&1)"
    rc=$?

    if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do
            log "| $line"
        done
    fi

    log "rc=$rc"
    return "$rc"
}

qipt() {
    "$IPT" $WAIT "$@" >/dev/null 2>&1
}

cleanup_lock() {
    rmdir "$LOCKDIR" 2>/dev/null
}

clean_mac() {
    printf '%s\n' "$1" \
        | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/-/:/g' \
        | tr 'A-F' 'a-f'
}

valid_mac() {
    printf '%s\n' "$1" | awk -F: '
        NF != 6 { exit 1 }
        {
            for (i = 1; i <= 6; i++) {
                if ($i !~ /^[0-9a-fA-F][0-9a-fA-F]$/) exit 1
            }
            exit 0
        }
    '
}

count_valid_macs() {
    count=0

    [ -f "$WHITELIST" ] || {
        printf '0\n'
        return
    }

    while IFS= read -r raw || [ -n "$raw" ]; do
        mac="$(clean_mac "$raw")"
        [ -z "$mac" ] && continue

        if valid_mac "$mac"; then
            count=$((count + 1))
        else
            log "ignored invalid whitelist entry while counting: $raw"
        fi
    done < "$WHITELIST"

    printf '%s\n' "$count"
}

detect_lan_if() {
    ip route show "$LAN_NET" 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

detect_wan_if() {
    # Merlin firewall-start normally passes WAN interface as $1.
    if [ -n "$1" ]; then
        printf '%s\n' "$1"
        return
    fi

    # Manual-run fallback.
    ip route get 1.1.1.1 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

test_mac_match() {
    qipt -N "$TEST_CHAIN"
    qipt -F "$TEST_CHAIN"

    if qipt -A "$TEST_CHAIN" -m mac --mac-source 00:11:22:33:44:55 -j RETURN; then
        qipt -F "$TEST_CHAIN"
        qipt -X "$TEST_CHAIN"
        return 0
    fi

    qipt -F "$TEST_CHAIN"
    qipt -X "$TEST_CHAIN"
    return 1
}

remove_hooks() {
    tmp="/tmp/${CHAIN}.forward.$$"

    "$IPT" $WAIT -S FORWARD > "$tmp" 2>/dev/null || return 0

    grep " -j $CHAIN" "$tmp" 2>/dev/null | while IFS= read -r rule; do
        case "$rule" in
            -A\ FORWARD*)
                del="$(printf '%s\n' "$rule" | sed 's/^-A /-D /')"
                log "+ $IPT $WAIT $del"
                "$IPT" $WAIT $del >> "$LOG_FILE" 2>&1
                ;;
        esac
    done

    rm -f "$tmp"
}

cleanup_policy() {
    log "cleanup: removing only $CHAIN hooks/chains"
    remove_hooks
    qipt -F "$CHAIN"
    qipt -X "$CHAIN"
}

load_whitelist() {
    count=0

    [ -f "$WHITELIST" ] || : > "$WHITELIST"

    while IFS= read -r raw || [ -n "$raw" ]; do
        mac="$(clean_mac "$raw")"
        [ -z "$mac" ] && continue

        if valid_mac "$mac"; then
            if ! ipt -A "$CHAIN" -m mac --mac-source "$mac" -j RETURN; then
                log "ERROR: failed to add allow rule for MAC $mac"
                return 1
            fi
            count=$((count + 1))
            log "allow MAC loaded: $mac"
        else
            log "ignored invalid whitelist entry while loading: $raw"
        fi
    done < "$WHITELIST"

    log "valid whitelist MACs loaded: $count"
    return 0
}

apply_policy() {
    wan_arg="$1"

    log "----- apply requested -----"
    log "LAN_NET=$LAN_NET"
    log "WHITELIST=$WHITELIST"
    log "wan_arg=${wan_arg:-none}"
    log "default route: $(ip route show default 2>/dev/null | tr '\n' '; ')"

    if [ -f "$DISABLE_FILE" ]; then
        log "disable file exists: $DISABLE_FILE; removing policy"
        cleanup_policy
        return 0
    fi

    mkdir -p "$SCRIPTS_DIR" 2>/dev/null
    [ -f "$WHITELIST" ] || : > "$WHITELIST"
    chmod 644 "$WHITELIST" 2>/dev/null

    wan_if="$(detect_wan_if "$wan_arg")"
    lan_if="$(detect_lan_if)"
    valid_count="$(count_valid_macs)"
    [ -n "$valid_count" ] || valid_count="0"

    log "detected WAN_IF=${wan_if:-none}"
    log "detected LAN_IF=${lan_if:-none}"
    log "valid whitelist MAC count=$valid_count"

    if [ -z "$wan_if" ]; then
        log "ERROR: no WAN interface; not installing policy"
        cleanup_policy
        return 1
    fi

    if [ -z "$lan_if" ]; then
        log "ERROR: no LAN interface for $LAN_NET; not installing policy"
        cleanup_policy
        return 1
    fi

    if [ "$wan_if" = "$lan_if" ]; then
        log "ERROR: WAN_IF equals LAN_IF ($wan_if); not installing policy"
        cleanup_policy
        return 1
    fi

    case "$wan_if" in
        br*|wl*)
            log "ERROR: WAN_IF looks like LAN/wireless interface ($wan_if); not installing policy"
            cleanup_policy
            return 1
            ;;
    esac

    # MAC match is only required if valid whitelist MACs exist.
    # Empty whitelist mode uses only a final DROP, so MAC match is not required.
    if [ "$valid_count" -gt 0 ]; then
        if ! test_mac_match; then
            log "ERROR: iptables MAC match unavailable; not installing policy because whitelist cannot be honored"
            cleanup_policy
            return 1
        fi
    fi

    cleanup_policy

    qipt -N "$CHAIN"
    if ! ipt -F "$CHAIN"; then
        log "ERROR: could not create/flush $CHAIN"
        cleanup_policy
        return 1
    fi

    if ! load_whitelist; then
        log "ERROR: failed loading whitelist"
        cleanup_policy
        return 1
    fi

    # Critical policy rule:
    # Empty whitelist still reaches this DROP, which blocks all LAN_NET clients from IPv4 WAN.
    # Non-empty whitelist gets RETURN rules above this DROP.
    if ! ipt -A "$CHAIN" -j DROP; then
        log "ERROR: could not add default DROP"
        cleanup_policy
        return 1
    fi

    if ! ipt -I FORWARD 1 -i "$lan_if" -s "$LAN_NET" -o "$wan_if" -j "$CHAIN"; then
        log "ERROR: could not insert FORWARD hook"
        cleanup_policy
        return 1
    fi

    log "ACTIVE: $LAN_NET from $lan_if to WAN $wan_if is blocked except whitelist MACs"
    log "----- apply complete -----"
    return 0
}

status_policy() {
    echo "LAN_NET: $LAN_NET"
    echo "Whitelist: $WHITELIST"
    cat "$WHITELIST" 2>/dev/null || echo "missing"
    echo
    echo "Valid MAC count: $(count_valid_macs)"
    echo
    echo "Detected LAN interface: $(detect_lan_if)"
    echo "Detected WAN interface: $(detect_wan_if '')"
    echo
    echo "FORWARD hooks:"
    "$IPT" $WAIT -S FORWARD 2>/dev/null | grep "$CHAIN" || echo "none"
    echo
    echo "Chain:"
    "$IPT" $WAIT -vnL "$CHAIN" 2>/dev/null || echo "chain not present"
}

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "another instance already running; exiting"
    exit 0
fi
trap cleanup_lock EXIT INT TERM

case "${1:-apply}" in
    apply)
        shift
        apply_policy "${1:-}"
        ;;
    status)
        status_policy
        ;;
    off|cleanup)
        cleanup_policy
        ;;
    *)
        echo "Usage: $0 {apply [wan_if]|status|off|cleanup}" >&2
        exit 2
        ;;
esac

exit 0
LAN_NO_WAN_EOF
chmod 755 "$POLICY"
say "Installed $POLICY"

backup_file "$APPEND"
cat > "$APPEND" <<'APPEND_WHITELIST_EOF'
#!/bin/sh

# Append a device MAC to whitelist_mac.txt by looking up its current IPv4 address.
#
# Usage:
#   /jffs/scripts/append_whitelist.sh 192.168.1.57
#
# Shortcut, while SSHed from the client to whitelist:
#   /jffs/scripts/append_whitelist.sh
#
# Behavior:
#   - Resolves IP -> MAC using neighbor table, ARP table, dnsmasq lease, then one ping.
#   - Shows IP, MAC, hostname if known.
#   - Requires typing "yes".
#   - Appends only the MAC.
#   - If LAN_NO_WAN4 is already active, reapplies policy so the new MAC takes effect.
#   - If policy is not active, it only saves the MAC.

PATH=/sbin:/bin:/usr/sbin:/usr/bin

SCRIPTS_DIR="/jffs/scripts"
TAG="append-whitelist"
CHAIN="LAN_NO_WAN4"
WHITELIST="$SCRIPTS_DIR/whitelist_mac.txt"
POLICY="$SCRIPTS_DIR/lan_no_wan.sh"
LOG_FILE="/tmp/append-whitelist.log"

log() {
    msg="$*"
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    [ -n "$ts" ] || ts="date-unavailable"

    printf '%s [%s] %s\n' "$ts" "$TAG" "$msg" >&2
    printf '%s [%s] %s\n' "$ts" "$TAG" "$msg" >> "$LOG_FILE" 2>/dev/null
    logger -t "$TAG" "$msg" 2>/dev/null
}

clean_mac() {
    printf '%s\n' "$1" \
        | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/-/:/g' \
        | tr 'A-F' 'a-f'
}

valid_mac() {
    printf '%s\n' "$1" | awk -F: '
        NF != 6 { exit 1 }
        {
            for (i = 1; i <= 6; i++) {
                if ($i !~ /^[0-9a-fA-F][0-9a-fA-F]$/) exit 1
            }
            exit 0
        }
    '
}

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
            }
            exit 0
        }
    '
}

lease_name() {
    ip="$1"

    for f in /var/lib/misc/dnsmasq.leases /tmp/dnsmasq.leases; do
        [ -r "$f" ] || continue
        awk -v ip="$ip" '$3 == ip { print $4; exit }' "$f"
    done | awk 'NF && $0 != "*" { print; exit }'
}

lease_mac() {
    ip="$1"

    for f in /var/lib/misc/dnsmasq.leases /tmp/dnsmasq.leases; do
        [ -r "$f" ] || continue
        awk -v ip="$ip" '$3 == ip { print $2; exit }' "$f"
    done | awk 'NF { print; exit }'
}

neigh_mac() {
    ip="$1"

    ip neigh show "$ip" 2>/dev/null | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "lladdr") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
}

arp_mac() {
    ip="$1"

    awk -v ip="$ip" '$1 == ip && $4 != "00:00:00:00:00:00" { print $4; exit }' /proc/net/arp 2>/dev/null
}

resolve_mac() {
    ip="$1"

    mac="$(clean_mac "$(neigh_mac "$ip")")"
    if valid_mac "$mac"; then
        log "resolved MAC using ip neigh: $mac"
        printf '%s\n' "$mac"
        return 0
    fi

    mac="$(clean_mac "$(arp_mac "$ip")")"
    if valid_mac "$mac"; then
        log "resolved MAC using /proc/net/arp: $mac"
        printf '%s\n' "$mac"
        return 0
    fi

    mac="$(clean_mac "$(lease_mac "$ip")")"
    if valid_mac "$mac"; then
        log "resolved MAC using dnsmasq lease: $mac"
        printf '%s\n' "$mac"
        return 0
    fi

    log "pinging $ip once to populate neighbor table"
    ping -c 1 -W 1 "$ip" >/dev/null 2>&1

    mac="$(clean_mac "$(neigh_mac "$ip")")"
    if valid_mac "$mac"; then
        log "resolved MAC using ip neigh after ping: $mac"
        printf '%s\n' "$mac"
        return 0
    fi

    mac="$(clean_mac "$(arp_mac "$ip")")"
    if valid_mac "$mac"; then
        log "resolved MAC using /proc/net/arp after ping: $mac"
        printf '%s\n' "$mac"
        return 0
    fi

    return 1
}

already_listed() {
    want="$1"

    [ -f "$WHITELIST" ] || return 1

    awk -v want="$want" '
        function clean(s) {
            sub(/[[:space:]]*#.*/, "", s)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/-/, ":", s)
            return tolower(s)
        }
        clean($0) == tolower(want) { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$WHITELIST"
}

policy_active() {
    iptables -S FORWARD 2>/dev/null | grep -q " -j $CHAIN"
}

ip="${1:-}"

if [ -z "$ip" ] && [ -n "$SSH_CLIENT" ]; then
    ip="$(printf '%s\n' "$SSH_CLIENT" | awk '{ print $1 }')"
    log "no IP argument supplied; using SSH_CLIENT IP: $ip"
fi

if ! valid_ipv4 "$ip"; then
    echo "Usage: $0 <client-ipv4>" >&2
    exit 2
fi

case "$ip" in
    192.168.1.*)
        ;;
    *)
        log "WARNING: $ip is outside 192.168.1.0/24; this MAC may not be the MAC used on the target LAN SSID"
        ;;
esac

host="$(lease_name "$ip")"
mac="$(resolve_mac "$ip")"
mac="$(clean_mac "$mac")"

if ! valid_mac "$mac"; then
    log "ERROR: could not resolve valid MAC for $ip"
    exit 1
fi

printf '\nConfirm whitelist addition:\n'
printf '  IP:   %s\n' "$ip"
printf '  MAC:  %s\n' "$mac"
printf '  Host: %s\n' "${host:-unknown}"
printf 'Type yes to append: '

IFS= read -r answer

case "$answer" in
    yes|YES|Yes)
        ;;
    *)
        log "not confirmed; no change"
        exit 1
        ;;
esac

mkdir -p "$SCRIPTS_DIR" 2>/dev/null
[ -f "$WHITELIST" ] || : > "$WHITELIST"

if already_listed "$mac"; then
    log "MAC already listed: $mac"
else
    now="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    [ -n "$now" ] || now="date-unavailable"
    printf '%s  # added %s from %s host %s\n' "$mac" "$now" "$ip" "${host:-unknown}" >> "$WHITELIST"
    log "appended MAC to whitelist: $mac"
fi

chmod 644 "$WHITELIST" 2>/dev/null

if policy_active; then
    if [ -x "$POLICY" ]; then
        log "policy is active; reapplying so whitelist change takes effect"
        "$POLICY" apply
    else
        log "WARNING: policy active but $POLICY is not executable"
    fi
else
    log "policy is not active; saved whitelist only. Run $POLICY apply to activate."
fi

exit 0
APPEND_WHITELIST_EOF
chmod 755 "$APPEND"
say "Installed $APPEND"

install_firewall_start_wrapper() {
    target="$1"
    cat > "$target" <<'FIREWALL_START_EOF'
#!/bin/sh

# LAN_NO_WAN_MANAGED
# Safe firewall-start wrapper.
#
# This wrapper does NOT apply LAN no-WAN policy unless this marker exists:
#   /jffs/scripts/lan_no_wan.autostart
#
# Emergency boot disable marker:
#   /jffs/scripts/lan_no_wan.disable

PATH=/sbin:/bin:/usr/sbin:/usr/bin

TAG="lan-no-wan-start"
POLICY="/jffs/scripts/lan_no_wan.sh"
AUTOSTART="/jffs/scripts/lan_no_wan.autostart"
DISABLE_FILE="/jffs/scripts/lan_no_wan.disable"

logger -t "$TAG" "firewall-start called; wan_arg=${1:-none}"

if [ -f "$DISABLE_FILE" ]; then
    logger -t "$TAG" "disable marker exists; running cleanup only"
    [ -x "$POLICY" ] && "$POLICY" off
    exit 0
fi

if [ ! -f "$AUTOSTART" ]; then
    logger -t "$TAG" "autostart marker missing; not applying LAN no-WAN policy"
    exit 0
fi

if [ ! -x "$POLICY" ]; then
    logger -t "$TAG" "policy script missing or not executable: $POLICY"
    exit 0
fi

"$POLICY" apply "${1:-}"
exit 0
FIREWALL_START_EOF
    chmod 755 "$target"
}

FWSTART_EXAMPLE="$SCRIPT_DIR/firewall-start.lan_no_wan.example"
install_firewall_start_wrapper "$FWSTART_EXAMPLE"

if [ -f "$FWSTART" ]; then
    if grep -q 'LAN_NO_WAN_MANAGED' "$FWSTART" 2>/dev/null || grep -q 'lan_no_wan.sh' "$FWSTART" 2>/dev/null || [ "$REPLACE_FIREWALL_START" -eq 1 ]; then
        backup_file "$FWSTART"
        install_firewall_start_wrapper "$FWSTART"
        say "Installed managed $FWSTART"
    else
        say "Existing $FWSTART is not recognized and was NOT overwritten."
        say "A safe wrapper was written to $FWSTART_EXAMPLE"
        say "To replace existing firewall-start, rerun: sh setup.sh --replace-firewall-start"
    fi
else
    install_firewall_start_wrapper "$FWSTART"
    say "Installed managed $FWSTART"
fi

if [ "$DISABLE_AUTOSTART" -eq 1 ]; then
    rm -f "$AUTOSTART"
    : > "$DISABLE_FILE"
    say "Disabled autostart marker and created $DISABLE_FILE"
    if [ -x "$POLICY" ]; then
        "$POLICY" off || true
    fi
fi

if [ "$ENABLE_AUTOSTART" -eq 1 ]; then
    rm -f "$DISABLE_FILE"
    : > "$AUTOSTART"
    say "Enabled autostart marker: $AUTOSTART"
else
    if [ "$DISABLE_AUTOSTART" -eq 0 ]; then
        say "Autostart not enabled. To enable later: touch $AUTOSTART"
    fi
fi

if [ "$APPLY_NOW" -eq 1 ]; then
    rm -f "$DISABLE_FILE"
    say "Applying policy now. Empty whitelist means all 192.168.1.0/24 clients lose IPv4 WAN."
    "$POLICY" apply
else
    say "Policy not applied by setup. To apply manually: $POLICY apply"
fi

say ""
say "Installed files:"
say "  $POLICY"
say "  $APPEND"
say "  $WHITELIST"
say "  $FWSTART_EXAMPLE"
[ -f "$FWSTART" ] && say "  $FWSTART"
say ""
say "Useful commands:"
say "  $POLICY status"
say "  $POLICY apply"
say "  $POLICY off"
say "  $APPEND 192.168.1.X"
say "  tail -80 /tmp/lan-no-wan.log"
say ""
say "Semantics when policy is active:"
say "  empty whitelist -> block all 192.168.1.0/24 IPv4 WAN"
say "  whitelist with MACs -> listed MACs allowed, all other 192.168.1.0/24 IPv4 WAN blocked"

exit 0
