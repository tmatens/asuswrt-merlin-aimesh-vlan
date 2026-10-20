# asuswrt-merlin-aimesh-vlan

VLAN-tag your AiMesh Guest and IoT SSIDs on Asuswrt-Merlin, **without losing
them on every `restart_wireless` or AiMesh re-sync**.

## What this is

Drop-in `/jffs/scripts/` for Asuswrt-Merlin nodes (Asus AiMesh-capable APs)
that:

- Creates dedicated bridges (`br30`, `br40`) for Guest and IoT SSIDs.
- Tags their traffic out a trunk port (`eth0` on the wired root; on satellites,
  whichever interface AiMesh is using as the backhaul — `eth6` wireless, `eth0`
  wired — followed live as it changes) for an upstream router/firewall to handle.
- **Survives `service restart_wireless`** via a `service-event-end` post-hook.
- **Survives AiMesh mid-runtime VAP re-syncs** via a 10 s drift watcher
  that moves VAPs back to the correct bridge when AiMesh dumps them into
  `br0`.
- **Survives backhaul reconnects** by recreating VLAN sub-interfaces on each
  backhaul band (`wds*.0.1`) when they reappear.
- **Survives its own death**: a `vlan-watch-guard` cron relaunches the
  watcher within 5 minutes if it ever dies.
- **Tells you when it acted** (optional): drift repairs and a periodic
  heartbeat are emitted to syslog, so if you forward the node's syslog
  anywhere (Loki, rsyslog, …) you can alert both on leaks *and* on the
  watcher itself silently disappearing. See
  [Monitoring & alerting](#monitoring--alerting-optional).

If you've ever set up VLANs by hand on a Merlin AP, watched them disappear
the next time you toggled a wireless setting, and given up — this is the
fix.

## Why this exists

Merlin and AiMesh put every wireless interface into `br0`. The "Guest
Network" feature does client isolation but not VLAN tagging. Manual `brctl`
work doesn't survive a wireless restart, and AiMesh silently re-syncs
satellites mid-runtime in ways that quietly leak Guest/IoT clients onto
VLAN 1.

See [`docs/architecture.md`](docs/architecture.md) for the full problem
statement and how the three layers (boot setup, `service-event-end` hook,
drift watcher) cooperate.

## Topology assumed

```
[upstream router]                       VLAN routing, DHCP, firewall happens here.
      │  trunk: VLAN1 untagged + 30/40 tagged
[managed switch]
      │
[root AiMesh node, eth0 trunked]
      ├─ wifi: Main, Main-IoT, Main-Guest
      └─ wireless backhaul → satellite
                                  │
                  [satellite AiMesh node, eth6 = backhaul "trunk"]
                       wifi: Main, Main-IoT, Main-Guest
```

See [`docs/topology.md`](docs/topology.md) for the worked example with
VAP indexes.

## What this does NOT do

- **Does not change your existing SSIDs, PSKs, or wireless security
  settings.** Those live in NVRAM, which this code never writes to. All
  this code does is change which Linux bridge each VAP belongs to so its
  traffic exits on a VLAN-tagged trunk port. Configure SSIDs the normal
  way in the Asus/Merlin UI; this code routes them.
- Does not write to NVRAM at all. All bridge/VLAN state is recreated at
  boot and after every `restart_wireless`, so a reboot without these
  scripts in `/jffs/scripts/` returns the node to Merlin's stock
  behaviour. No factory reset ever needed to revert.
- Does not configure your upstream router, switch, DHCP, or firewall.
- Does not provide L3 isolation between VLANs — that's your upstream
  router's job.
- Does not handle IPv6 routing or filtering. Same rule: handled upstream.
  This code operates entirely at L2.

## Defaults

| VLAN | Purpose | Bridge |
|------|---------|--------|
| 1    | LAN (untagged) | br0  |
| 30   | Guest          | br30 |
| 40   | IoT            | br40 |

VAPs are discovered dynamically **by SSID name** — the scripts match
whatever interfaces currently serve `IOT_SSID` / `GUEST_SSID`, so band
toggles and per-node VAP-index differences (root vs. satellite) need no
per-node interface lists. Edit `IOT_VLAN` / `GUEST_VLAN` / `IOT_SSID` /
`GUEST_SSID` at the top of each `vlan-bridge-setup` script to match your
network.

## Backup and recovery — read before installing

These scripts **overwrite** any files in `/jffs/scripts/` with the same
names (`services-start`, `service-event`, `service-event-end`, plus
`init-start` on satellites). If you have existing customisations there,
they will be lost unless you back them up first.

### What this code touches (and what it doesn't)

- **Touches**: files under `/jffs/scripts/` on each node.
- **Does NOT touch**: NVRAM. No `nvram set` or `nvram commit` calls. All
  bridge/VLAN state is recreated at boot and after every
  `restart_wireless`; a reboot of an untouched node always returns to
  Merlin's default behaviour.
- **Does NOT touch**: the primary SSID, the `br0` bridge that carries
  management traffic, or your wired LAN. SSH access to the node continues
  to work over the primary SSID and any wired port even if the scripts
  misbehave.

Because nothing is written to NVRAM, the worst realistic failure mode is
"Guest or IoT SSIDs don't pass traffic correctly until you SSH in and
remove the bad scripts." A factory reset is **not** required to recover.

### Pre-install backup

Before running the installer, snapshot existing `/jffs/scripts/` on every
node and copy it off the router:

```sh
# On each node:
ssh <user>@<node-ip> "tar -czf /jffs/backup-scripts-$(date +%Y%m%d).tgz /jffs/scripts/"

# Then pull the backup onto your workstation so a router reset can't lose it.
# Note the `-O` flag: see "A note on scp -O" below.
scp -O <user>@<node-ip>:/jffs/backup-scripts-*.tgz ./backups/
```

#### A note on `scp -O`

OpenSSH 9.0 (Apr 2022) changed `scp`'s default transport from the legacy
SCP protocol to SFTP. Asuswrt-Merlin uses dropbear, which does **not**
ship an sftp-server, so the default fails with:

```
sh: /opt/libexec/sftp-server: not found
scp: Connection closed
```

The `-O` flag forces the legacy SCP protocol, which dropbear supports.
`tools/install.sh` already passes `-O` internally; you only need to add
it to any manual `scp` commands you run against the nodes (like the
backup line above, and the manual install path below).

Keep the backup tarball until you've validated the new setup over at
least one full `restart_wireless` cycle and one reboot.

### Recovery procedure

If after install your Guest/IoT SSIDs don't behave correctly, or you want
to revert entirely:

```sh
# 1. SSH in (br0 / primary SSID is unchanged, so this still works):
ssh <user>@<node-ip>

# 2. Stop the watcher (if running) so it doesn't interfere:
[ -f /tmp/vlan-bridge-watcher.pid ] && kill "$(cat /tmp/vlan-bridge-watcher.pid)"

# 3. Restore the backup over /jffs/scripts/:
cd / && tar -xzf /jffs/backup-scripts-YYYYMMDD.tgz

# 4. Either restart wireless to undo the bridge layout immediately ...
service restart_wireless

# 5. ... or reboot for a fully clean state:
reboot
```

If SSH is unavailable for some reason, the primary SSID and any wired LAN
port still let you reach the node — these scripts never modify the
default `br0` membership for those. As an absolute last resort, the
hardware reset button performs a factory reset (note: this also wipes
your AiMesh pairing).

## Install

Requirements:

- Asuswrt-Merlin (or a fork like gnuton) on the node.
- JFFS enabled and script execution enabled in the Merlin UI
  (System → Administration).
- SSH key access to the node (recommended).
- **Backup taken** as described above.
- **Guest and IoT SSIDs already created and enabled** in the Asus/Merlin
  UI. This code routes their VAPs to VLAN bridges; it does **not** create
  the SSIDs themselves. Set `IOT_SSID` / `GUEST_SSID` at the top of each
  `vlan-bridge-setup` to your SSID names — VAPs are discovered by SSID, so
  indexes don't matter; [`docs/topology.md`](docs/topology.md) has a
  one-liner that prints every configured VAP and its SSID name via
  `nvram get`.
- *(Untested)* If you use Asus's newer "Guest Network Pro" / "AiMesh Guest"
  feature, the scripts have not been validated against it. The classic
  per-band Guest SSID setup is what's tested.

Two ways:

### From your workstation

```sh
git clone https://github.com/tmatens/asuswrt-merlin-aimesh-vlan.git
cd asuswrt-merlin-aimesh-vlan

# Step 0: take backups (see "Pre-install backup" above) — do not skip.

# Edit IOT_VLAN / GUEST_VLAN / IOT_SSID / GUEST_SSID in:
#   main/jffs/scripts/vlan-bridge-setup
#   secondary/jffs/scripts/vlan-bridge-setup

# Wired root:
./tools/install.sh main      192.168.1.1   admin

# Each AiMesh satellite:
./tools/install.sh secondary 192.168.1.2   admin

# Reboot the node to pick up everything, including init-start on satellites:
ssh admin@192.168.1.1 reboot
ssh admin@192.168.1.2 reboot
```

### Manually

`scp -O` the contents of `main/jffs/scripts/` or `secondary/jffs/scripts/` to
`/jffs/scripts/` on the appropriate node, `chmod +x` everything, and reboot.
Take the backup described above first. (The `-O` flag is required for
modern OpenSSH clients — see "A note on `scp -O`" above.)

## Verify

### 1. L2 plumbing on the AP

After reboot:

```sh
ssh admin@<node-ip> "
  echo '=== bridges ==='; brctl show
  echo '=== watcher ==='; cat /tmp/vlan-bridge-watcher.pid \
    && echo running, repairs: \$(cat /tmp/vlan-bridge-watcher.repairs 2>/dev/null)
  echo '=== log ==='; tail -20 /tmp/vlan-bridge-setup.log
"
```

You should see `br40` and `br30` populated with the right VAPs, and the
watcher running with 0–few repairs. See [`docs/operations.md`](docs/operations.md)
for healthy vs. unhealthy examples.

### 2. End-to-end with a real client

`brctl show` only proves the AP's bridge layout is correct. The real test
is whether a client on each SSID gets a DHCP lease from the right scope:

- **Guest SSID** → client should get an IP in your VLAN 30 subnet
  (e.g. `192.168.30.x`).
- **IoT SSID** → client should get an IP in your VLAN 40 subnet
  (e.g. `192.168.40.x`).

A phone is the easiest test client. If `brctl show` looks correct but
DHCP returns an IP from the LAN scope (VLAN 1) instead, the problem is
**upstream** of the AP — most likely the trunk port on your managed
switch isn't tagging VLAN 30/40, or your upstream router has no DHCP
scope on those VLANs. Nothing more to fix on the AP side.

## Monitoring & alerting (optional)

The watcher is the thing standing between you and Guest/IoT clients
quietly landing on your trusted LAN — so it's worth knowing (a) when it
had to act, and (b) that it's still alive at all. The scripts emit four
syslog markers for exactly this (plain `logger` lines — they cost nothing
and need no extra software on the node):

| Marker | When | Meaning |
|--------|------|---------|
| `vlan1_drift sev=crit vap=… from=… to=…` | a VAP (or backhaul sub-interface) was found outside its bridge mid-runtime | a real, seconds-long VLAN-1 leak occurred and was repaired — one-off after an AiMesh sync is normal, repeats deserve a look |
| `vlan_watch_restart sev=warn reason=watcher-dead` | the guard cron relaunched a dead watcher | protection ran unwatched for up to 5 minutes |
| `vlan_trunk_change [sev=warn] iface=… from=…` | satellite only: AiMesh moved the backhaul and the Guest/IoT trunks followed it | `sev=warn` is present only when the node **left its wired port** for a radio — dead cable/coax or an unplugged adapter; the mesh keeps working on the wireless fallback, slower. Without `sev` (back onto the wire, or radio to radio) it is informational |
| `vlan_watch_hb hb=vlan-watch` | every 5 minutes per node | heartbeat — its **absence** means the watcher died, `/jffs` was wiped (an AiMesh node re-add does this), the AP is down, or syslog forwarding broke |

Boot-time bridge moves are expected (Merlin rebuilds `br0` from NVRAM at
every boot) and deliberately emit **no** marker, so reboots don't page you.

To use them, forward the node's syslog to any collector (Merlin UI:
System Log → Remote Log Server) and alert on two things:

1. **Any `sev=(warn|crit)` line** — e.g. LogQL:
   `{job="syslog"} |~ "sev=(warn|crit)"`
2. **Heartbeat absence** — e.g. LogQL, alerting when fewer hosts report
   than you have nodes (NoData-safe):
   `count(sum by (host) (count_over_time({job="syslog"} |= "vlan_watch_hb" [15m]))) or vector(0)`

The second one matters most: every other failure mode announces itself,
but a dead watcher is silent — and it's the one an AiMesh node re-add
(which wipes `/jffs`, scripts included) actually produces. Without an
absence alert you'd rediscover that during your next security audit
instead of within 15 minutes.

## Extras

- **`tools/iot-isolate.sh`** — temporarily disable AP isolation and
  ebtables on IoT SSIDs across both nodes so IoT devices can pair. Reboot
  restores normal security automatically; the script doesn't write to
  NVRAM.
- **`main/jffs/scripts/monitor-backhaul.sh`** — logs `wds*.0.1` link
  transitions on the wired root, so you can correlate satellite outages
  with backhaul flaps. With AiMesh *Ethernet Backhaul Mode* on it watches
  the wired path instead (AiMesh nodes seen as LLDP neighbours over
  Ethernet), since the `wds` links no longer exist.

## Tested on

- ASUS ZenWiFi ET8 (2-node AiMesh, wireless backhaul) on Asuswrt-Merlin
  gnuton fork 3004.388.10_2 and 3004.388.11_1.

It should work on any Asuswrt-Merlin AP with the standard `wlN.M`
interface naming and `wds*.0.1` backhaul. If you try it on a different
model, edit `IOT_SSID` / `GUEST_SSID` and the `TRUNK` value to match —
they're the only model-specific bits.

## Status / support

No-promise codebase. Issues and PRs welcome but I won't always have time
to respond. If something's broken on your hardware, the scripts are short
(<300 lines each) and the comments are extensive — read and adapt.

## License

[MIT](LICENSE).
