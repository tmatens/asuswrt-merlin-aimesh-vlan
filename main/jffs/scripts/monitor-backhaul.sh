#!/bin/sh
# =============================================================================
# monitor-backhaul.sh — Log backhaul link state changes with timestamps
#
# Location on router : /jffs/scripts/monitor-backhaul.sh  (main node only)
# Started by         : services-start (background)
#
# Purpose: Track backhaul stability to diagnose client connectivity issues on
#          satellite nodes, whichever way the satellites are attached.
#
# Wireless backhaul — interfaces monitored (one per backhaul radio band; if
# all drop simultaneously, every client on a satellite loses connectivity):
#   wds0.0.1 = 2.4 GHz backhaul
#   wds1.0.1 = 5 GHz backhaul
#   wds2.0.1 = 6 GHz backhaul
#
# Wired backhaul — with AiMesh "Ethernet Backhaul Mode" on (nvram
# amas_eap_bhmode != 0; observed 0 -> 3100 when the toggle is enabled) the wds
# interfaces do not exist at all, so judging by them reports a permanent
# outage. In that mode the monitor counts AiMesh nodes (MACs from nvram
# cfg_device_list) that are LLDP neighbours on a non-wds interface instead.
# lldpd sends every 10 s with a 20 s hold, so a node must be absent for
# WIRED_DOWN_POLLS consecutive polls before it counts as down.
#
# Output: /tmp/backhaul-monitor.log (lost on reboot — only recent history
# is useful for correlating with incident reports)
# =============================================================================

LOGFILE="/tmp/backhaul-monitor.log"
PIDFILE="/tmp/backhaul-monitor.pid"
INTERVAL=10
HEARTBEAT_INTERVAL=360          # heartbeat every 360 polls = 3600s = 1 hour
BACKHAUL_IFACES="wds0.0.1 wds1.0.1 wds2.0.1"
WIRED_DOWN_POLLS=3              # 3 polls = 30s without any wired node
WARN_REPEAT_POLLS=30            # while down, repeat the WARNING every 5 min

# Number of AiMesh nodes currently seen as LLDP neighbours over Ethernet.
wired_nodes_seen() {
    local macs n=0 m
    macs=$(lldpcli show neighbors summary 2>/dev/null | awk '
        /^Interface:/ { wired = ($2 !~ /^wds/) }
        /ChassisID:/  { if (wired) print toupper($NF) }')
    for m in $macs; do
        nvram get cfg_device_list 2>/dev/null | tr 'a-f' 'A-F' | grep -q ">$m>" && n=$((n + 1))
    done
    echo "$n"
}

# Kill any previous instance
if [ -f "$PIDFILE" ]; then
    oldpid=$(cat "$PIDFILE")
    [ -d "/proc/$oldpid" ] && kill "$oldpid" 2>/dev/null
fi
echo $$ > "$PIDFILE"

logger -t backhaul-monitor "Started (PID $$), polling every ${INTERVAL}s"
echo "$(date '+%Y-%m-%d %H:%M:%S') — monitor started (PID $$)" >> "$LOGFILE"

# Initialize previous state for each interface
for iface in $BACKHAUL_IFACES; do
    eval "prev_${iface//[.-]/_}=unknown"
done

poll_count=0
prev_all_down=false
prev_mode=""
wired_missing=0
down_polls=0

while true; do
    all_down=true
    poll_count=$((poll_count + 1))

    ebm=$(nvram get amas_eap_bhmode 2>/dev/null)
    if [ -n "$ebm" ] && [ "$ebm" != "0" ]; then mode="wired"; else mode="wireless"; fi
    if [ "$mode" != "$prev_mode" ]; then
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$timestamp — backhaul mode: ${prev_mode:-unknown} -> $mode" >> "$LOGFILE"
        logger -t backhaul-monitor "backhaul mode: ${prev_mode:-unknown} -> $mode"
        prev_mode="$mode"
        wired_missing=0
        # Wired mode judges the backhaul by LLDP. Without lldpcli the state is
        # unknown, not down: say so once instead of reporting a false outage.
        # (`which`, not `command -v`: the firmware's BusyBox sh lacks `command`.)
        if [ "$mode" = "wired" ] && ! which lldpcli >/dev/null 2>&1; then
            echo "$timestamp — wired mode: lldpcli not found, backhaul state not monitored" >> "$LOGFILE"
            logger -t backhaul-monitor "wired mode: lldpcli not found, backhaul state not monitored"
        fi
    fi

    if [ "$mode" = "wired" ] && ! which lldpcli >/dev/null 2>&1; then
        all_down=false
    elif [ "$mode" = "wired" ]; then
        if [ "$(wired_nodes_seen)" -gt 0 ]; then
            wired_missing=0
            all_down=false
        else
            wired_missing=$((wired_missing + 1))
            [ "$wired_missing" -lt "$WIRED_DOWN_POLLS" ] && all_down=false
        fi
    fi

    [ "$mode" = "wireless" ] && for iface in $BACKHAUL_IFACES; do
        varname="prev_${iface//[.-]/_}"

        if [ -d "/sys/class/net/$iface" ]; then
            operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "error")
            carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo "0")

            if [ "$carrier" = "1" ]; then
                current="up"
                all_down=false
            else
                current="down(operstate=$operstate,carrier=$carrier)"
            fi
        else
            current="missing"
        fi

        eval "prev=\$$varname"
        if [ "$current" != "$prev" ]; then
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo "$timestamp — $iface: $prev -> $current" >> "$LOGFILE"
            logger -t backhaul-monitor "$iface: $prev -> $current"
            eval "${varname}='$current'"
        fi
    done

    # Log a warning if ALL backhaul links are down simultaneously. The sev-marker
    # fires ONCE per outage (on the transition into all-down), for a log collector
    # to alert on (see the README's Monitoring section) — this is the event behind
    # a satellite losing service; single-band flaps stay informational.
    if $all_down; then
        # The WARNING line repeats every WARN_REPEAT_POLLS while the outage
        # lasts (it used to repeat every poll: ~8,600 syslog lines a day).
        if [ "$prev_all_down" != "true" ] || [ "$down_polls" -ge "$WARN_REPEAT_POLLS" ]; then
            down_polls=0
            timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            echo "$timestamp — WARNING: ALL backhaul links down ($mode) — satellite isolated" >> "$LOGFILE"
            logger -t backhaul-monitor "WARNING: ALL backhaul links down ($mode)"
        fi
        down_polls=$((down_polls + 1))
        if [ "$prev_all_down" != "true" ]; then
            if [ "$mode" = "wired" ]; then detail="no_wired_node_lldp"; else detail="all_wds_links_down"; fi
            logger -t backhaul-monitor "BACKHAUL_DOWN sev=warn node=$(uname -n) detail=$detail"
        fi
        prev_all_down=true
    else
        if [ "$prev_all_down" = "true" ]; then
            logger -t backhaul-monitor "backhaul restored (was fully down)"
        fi
        prev_all_down=false
    fi

    # Hourly heartbeat: log current state of all interfaces
    if [ "$poll_count" -ge "$HEARTBEAT_INTERVAL" ]; then
        poll_count=0
        summary=""
        for iface in $BACKHAUL_IFACES; do
            hb_var="prev_${iface//[.-]/_}"
            eval "hb_state=\$$hb_var"
            summary="$summary $iface=$hb_state"
        done
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        [ "$mode" = "wired" ] && summary=" mode=wired nodes_seen=$(wired_nodes_seen)"
        echo "$timestamp — heartbeat:$summary" >> "$LOGFILE"
    fi

    sleep "$INTERVAL"
done
