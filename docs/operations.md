# Operations

How to verify everything is healthy and what to look at when it isn't.

## Health check (one-liner per node)

```sh
ssh admin@<node-ip> "
  echo '=== bridges ==='; brctl show
  echo '=== watcher  ==='; pid=\$(cat /tmp/vlan-bridge-watcher.pid 2>/dev/null);
    if [ -n \"\$pid\" ] && kill -0 \"\$pid\" 2>/dev/null; then
      echo \"running PID \$pid, repairs since boot: \$(cat /tmp/vlan-bridge-watcher.repairs 2>/dev/null || echo 0)\"
    else
      echo \"NOT RUNNING\"
    fi
  echo '=== setup log (tail) ==='; tail -20 /tmp/vlan-bridge-setup.log
"
```

## What healthy looks like

### Root node

```
br0    eth0  wl0  wl1  wl2  wds0.0.1 wds1.0.1 wds2.0.1
br40   eth0.40  wl0.1  wl1.1  wl2.1  wds0.0.1.40  wds1.0.1.40  wds2.0.1.40
br30   eth0.30  wl0.2  wl1.2          wds0.0.1.30  wds1.0.1.30  wds2.0.1.30
```

The `wds*.0.1.{30,40}` entries only appear for backhaul bands that are
actually up. AiMesh does not always establish all three bands; missing 2.4
GHz backhaul (`wds0.0.1`) when 5 and 6 GHz are healthy is normal band
selection, not a failure.

### Satellite node

```
br0    eth6  wl0.1  wl1.1  wl2.1  wl2.6
br40   eth6.40  wl0.2  wl1.2  wl2.2
br30   eth6.30  wl0.3  wl1.3
```

`wl2.1` is the AiMesh backhaul SSID and `wl2.6` is an AiMesh internal
interface; both belong in `br0` and the scripts deliberately do not touch
them.

## Watcher logs

The setup script appends a heartbeat line every hour:

```
[14:07:14] vlan-bridge: watcher: heartbeat — all VAPs healthy (repairs since boot: 3)
```

Drift looks like:

```
[12:34:56] vlan-bridge: watcher: drift — wl1.2 is in br0, expected br40
[12:34:56] vlan-bridge: watcher: repaired wl1.2 -> br40
```

A small number of repairs (1–5) per boot is normal for AiMesh satellites —
the controller does an initial sync, then occasional pushes for client
roaming or topology changes, and each one can briefly drop VAPs into `br0`.

A repair count that climbs continuously (e.g. tens of repairs per hour)
means something is fighting the watcher. Most likely causes:

- Wrong VAP→bridge mapping in `IOT_IFACES` / `GUEST_IFACES`; the watcher
  keeps moving an interface AiMesh keeps moving back.
- An NVRAM `wlN.M_bridge` value pointing somewhere the watcher disagrees
  with.

## Backhaul log (root node only)

`monitor-backhaul.sh` writes to `/tmp/backhaul-monitor.log`. Transitions
look like:

```
2026-05-11 23:04:13 — wds1.0.1: up -> missing
2026-05-11 23:04:23 — WARNING: ALL backhaul links down — satellite isolated
2026-05-11 23:04:33 — wds1.0.1: missing -> up
```

Heartbeats every hour confirm all monitored bands are still up:

```
2026-05-12 14:20:22 — heartbeat: wds0.0.1=up wds1.0.1=up wds2.0.1=up
```

A short flap (under a minute) every few days is common in AiMesh as the
controller reselects backhaul bands. Sustained outages are worth tracing.

## When to suspect something other than this code

- **Clients on Guest/IoT SSIDs can ping each other** — that's L2 isolation
  inside the bridge, controlled by `ap_isolate` and Merlin's "AP isolation"
  setting, not by this code.
- **Clients on Guest/IoT SSIDs can reach the main LAN** — that's L3 routing
  on your upstream router, not a bridge problem.
- **Clients on Guest/IoT SSIDs get a wrong IP** — DHCP runs on your
  upstream router, not on the AP.
- **6 GHz clients have weird issues with `ap_isolate`** — the Broadcom 6E
  driver silently ignores runtime `wl ap_isolate` changes; this is a
  driver limitation, not a script bug.
