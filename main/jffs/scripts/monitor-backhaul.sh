#!/bin/sh
# =============================================================================
# monitor-backhaul.sh — Log backhaul link state changes with timestamps
#
# Location on router : /jffs/scripts/monitor-backhaul.sh  (main node only)
# Started by         : services-start (background)
#
# Purpose: Track wireless backhaul stability to diagnose client connectivity
#          issues on satellite nodes. Each wds interface represents one
#          backhaul radio band; if all drop simultaneously, every client on
#          a satellite loses connectivity.
#
# Interfaces monitored:
#   wds0.0.1 = 2.4 GHz backhaul
#   wds1.0.1 = 5 GHz backhaul
#   wds2.0.1 = 6 GHz backhaul
#
# Output: /tmp/backhaul-monitor.log (lost on reboot — only recent history
# is useful for correlating with incident reports)
# =============================================================================

LOGFILE="/tmp/backhaul-monitor.log"
PIDFILE="/tmp/backhaul-monitor.pid"
INTERVAL=10
HEARTBEAT_INTERVAL=360          # heartbeat every 360 polls = 3600s = 1 hour
BACKHAUL_IFACES="wds0.0.1 wds1.0.1 wds2.0.1"

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

while true; do
    all_down=true
    poll_count=$((poll_count + 1))

    for iface in $BACKHAUL_IFACES; do
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

    # Log a warning if ALL backhaul links are down simultaneously
    if $all_down; then
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$timestamp — WARNING: ALL backhaul links down — satellite isolated" >> "$LOGFILE"
        logger -t backhaul-monitor "WARNING: ALL backhaul links down"
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
        echo "$timestamp — heartbeat:$summary" >> "$LOGFILE"
    fi

    sleep "$INTERVAL"
done
