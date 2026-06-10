#!/usr/bin/env bash
# =============================================================================
# iot-isolate.sh — Toggle AP isolation and ebtables on IoT SSIDs
#
# Usage:
#   ./tools/iot-isolate.sh <main-host> <secondary-host> {disable|enable|status}
#
# Optional env vars:
#   SSH_USER         (default: admin)
#   MAIN_IFACES      (default: "wl0.1 wl1.1")     — IoT VAPs on the wired root
#   SECONDARY_IFACES (default: "wl0.2 wl1.2")     — IoT VAPs on the satellite
#
# Examples:
#   ./tools/iot-isolate.sh 192.168.1.1 192.168.1.2 status
#   ./tools/iot-isolate.sh 192.168.1.1 192.168.1.2 disable
#
# What this script does
# ---------------------
# Two Asuswrt-Merlin mechanisms block client-to-client communication on
# "guest" / IoT VAPs. Both must be lifted for many IoT devices (e.g. cleaning
# robots, doorbells) to discover and pair with each other or with a phone:
#
#   1. AP isolation (ap_isolate=1)
#      Wireless-driver-level block: clients on the same SSID cannot talk to
#      each other directly — each device can only reach the gateway.
#
#   2. ebtables rules from lanaccess=off
#      Merlin treats Guest/IoT VAPs as "guest" interfaces and installs
#      ebtables (L2 firewall) rules that filter broadcast/multicast and
#      inter-client traffic at the interface level — before frames reach the
#      bridge. This blocks the mDNS/SSDP/UDP discovery many IoT devices
#      depend on during pairing.
#
# Both are security features that limit lateral movement on the IoT network.
# This script temporarily lifts both so pairing can succeed, then re-enables
# them.
#
# Safety
# ------
# AP isolation changes are made with the 'wl' driver command, which modifies
# the RUNNING state only — it does NOT write to NVRAM. ebtables rules are
# flushed at runtime and are also not persistent. A router reboot will
# always restore both ap_isolate=1 and the ebtables rules. This makes the
# "disable" action safe: even if you forget to re-enable, the next reboot
# fixes it.
#
# Note on satellite VAP numbering
# -------------------------------
# AiMesh satellites use different VAP indexes than the wired root:
#   Root:       wl0.1 = IoT     wl0.2 = Guest
#   Satellite:  wl0.1 = Main    wl0.2 = IoT     wl0.3 = Guest
# Defaults assume this layout. Override via the env vars above if yours
# differs.
#
# Limitation: 6 GHz (wl2)
# -----------------------
# The Broadcom 6E driver silently ignores runtime ap_isolate changes via
# 'wl'. Since virtually all IoT devices pair over 2.4 / 5 GHz, this has no
# practical impact in most setups.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Args / defaults
# ---------------------------------------------------------------------------
if [ $# -lt 3 ]; then
    echo "Usage: $0 <main-host> <secondary-host> {disable|enable|status}"
    exit 1
fi

MAIN_HOST="$1"
SECONDARY_HOST="$2"
ACTION="$3"

SSH_USER="${SSH_USER:-admin}"
MAIN_IFACES="${MAIN_IFACES:-wl0.1 wl1.1}"
SECONDARY_IFACES="${SECONDARY_IFACES:-wl0.2 wl1.2}"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[error]${NC} $*" >&2; }

# Interface names come from the environment (MAIN_IFACES/SECONDARY_IFACES) and
# are interpolated into the command strings we run on the router over SSH
# (e.g. "wl -i ${iface} ap_isolate 0"). Reject anything outside a strict
# allowlist so a crafted value such as 'wl0.1$(reboot)' or 'wl0.1; rm -rf /'
# cannot inject commands onto the router. Real VAP names are just letters,
# digits and '.' (e.g. wl0.1); '_' and '-' are allowed for other iface styles.
validate_ifaces() {
    local label="$1" ifaces="$2" iface
    for iface in $ifaces; do
        case "$iface" in
            *[!a-zA-Z0-9._-]*)
                err "Invalid interface name in ${label}: '${iface}'"
                err "Allowed characters: letters, digits, '.', '_', '-'"
                exit 1
                ;;
        esac
    done
}

ssh_cmd() {
    # $1 = host, $2 = command string
    ssh $SSH_OPTS "${SSH_USER}@${1}" "$2"
}

flush_ebtables() {
    local host="$1" label="$2"
    info "Flushing ebtables rules on ${label} node (${host}) ..."
    if ssh_cmd "$host" "ebtables -F; ebtables -t broute -F; ebtables -t nat -F"; then
        ok "${label}: ebtables rules FLUSHED"
    else
        err "${label}: failed to flush ebtables (is the node reachable?)"
        return 1
    fi
}

restore_ebtables() {
    local host="$1" label="$2"
    info "Restoring ebtables rules on ${label} node (${host}) ..."
    if ssh_cmd "$host" "service restart_firewall >/dev/null 2>&1"; then
        ok "${label}: ebtables rules RESTORED (firewall restarted)"
    else
        err "${label}: failed to restart firewall (is the node reachable?)"
        return 1
    fi
}

show_ebtables() {
    local host="$1" label="$2"
    local output
    if ! output=$(ssh_cmd "$host" "echo filter=\$(ebtables -L 2>/dev/null | grep -c '^-'); echo broute=\$(ebtables -t broute -L 2>/dev/null | grep -c '^-'); echo nat=\$(ebtables -t nat -L 2>/dev/null | grep -c '^-')" 2>&1); then
        err "${label}: SSH failed — ${output}"
        return 1
    fi

    local line table count
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        table="${line%%=*}"
        count="${line#*=}"
        if [ "$count" = "0" ]; then
            echo -e "  ebtables ${table}: ${YELLOW}no rules (pairing mode)${NC}"
        else
            echo -e "  ebtables ${table}: ${GREEN}${count} rules (normal)${NC}"
        fi
    done <<< "$output"
}

set_isolate() {
    local host="$1" label="$2" ifaces="$3" value="$4"
    local state_word
    if [ "$value" = "0" ]; then state_word="DISABLED"; else state_word="ENABLED"; fi

    info "Setting ap_isolate=${value} on ${label} node (${host}) ..."

    local cmds=""
    for iface in $ifaces; do
        cmds="${cmds}wl -i ${iface} ap_isolate ${value}; "
    done

    if ssh_cmd "$host" "$cmds"; then
        ok "${label}: AP isolation ${state_word} on [${ifaces}]"
    else
        err "${label}: failed to set ap_isolate (is the node reachable?)"
        return 1
    fi
}

show_status() {
    local host="$1" label="$2" ifaces="$3"

    local remote_cmd=""
    for iface in $ifaces; do
        remote_cmd="${remote_cmd}echo ${iface}=\$(wl -i ${iface} ap_isolate); "
    done

    info "${label} node (${host}):"
    local output
    if ! output=$(ssh_cmd "$host" "$remote_cmd" 2>&1); then
        err "${label}: SSH failed — ${output}"
        return 1
    fi

    local line iface val
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        iface="${line%%=*}"
        val="${line#*=}"
        if [ "$val" = "1" ]; then
            echo -e "  ${iface}: ${GREEN}isolated (ap_isolate=1)${NC}"
        elif [ "$val" = "0" ]; then
            echo -e "  ${iface}: ${YELLOW}open (ap_isolate=0) — pairing mode${NC}"
        else
            echo -e "  ${iface}: ${RED}unknown (${val})${NC}"
        fi
    done <<< "$output"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
validate_ifaces "MAIN_IFACES"      "$MAIN_IFACES"
validate_ifaces "SECONDARY_IFACES" "$SECONDARY_IFACES"

case "$ACTION" in
    disable)
        echo ""
        warn "Disabling AP isolation and flushing ebtables on IoT SSIDs (both nodes)."
        warn "IoT clients will be able to communicate directly with each other."
        warn "Remember to re-enable when pairing is done:  $0 ... enable"
        echo ""
        set_isolate "$MAIN_HOST"      "main"      "$MAIN_IFACES"      0
        set_isolate "$SECONDARY_HOST" "secondary" "$SECONDARY_IFACES" 0
        echo ""
        flush_ebtables "$MAIN_HOST"      "main"
        flush_ebtables "$SECONDARY_HOST" "secondary"
        echo ""
        ok "AP isolation DISABLED + ebtables FLUSHED. IoT devices can now pair."
        warn "Run '$0 ... enable' when done, or reboot the router to restore automatically."
        ;;
    enable)
        echo ""
        info "Re-enabling AP isolation and restoring ebtables on IoT SSIDs (both nodes)."
        echo ""
        set_isolate "$MAIN_HOST"      "main"      "$MAIN_IFACES"      1
        set_isolate "$SECONDARY_HOST" "secondary" "$SECONDARY_IFACES" 1
        echo ""
        restore_ebtables "$MAIN_HOST"      "main"
        restore_ebtables "$SECONDARY_HOST" "secondary"
        echo ""
        ok "AP isolation ENABLED + ebtables RESTORED. Normal IoT security restored."
        ;;
    status)
        echo ""
        show_status   "$MAIN_HOST"      "main"      "$MAIN_IFACES"
        show_ebtables "$MAIN_HOST"      "main"
        echo ""
        show_status   "$SECONDARY_HOST" "secondary" "$SECONDARY_IFACES"
        show_ebtables "$SECONDARY_HOST" "secondary"
        echo ""
        ;;
    *)
        echo "Usage: $0 <main-host> <secondary-host> {disable|enable|status}"
        exit 1
        ;;
esac
