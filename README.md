# asuswrt-merlin-aimesh-vlan

VLAN-tag your AiMesh Guest and IoT SSIDs on Asuswrt-Merlin, **without losing
them on every `restart_wireless` or AiMesh re-sync**.

## What this is

Drop-in `/jffs/scripts/` for Asuswrt-Merlin nodes (Asus AiMesh-capable APs)
that:

- Creates dedicated bridges (`br30`, `br40`) for Guest and IoT SSIDs.
- Tags their traffic out a trunk port (`eth0` on the wired root, `eth6` on
  wireless-backhaul satellites) for an upstream router/firewall to handle.
- **Survives `service restart_wireless`** via a `service-event-end` post-hook.
- **Survives AiMesh mid-runtime VAP re-syncs** via a 30 s drift watcher
  that moves VAPs back to the correct bridge when AiMesh dumps them into
  `br0`.
- **Survives backhaul reconnects** by recreating VLAN sub-interfaces on each
  backhaul band (`wds*.0.1`) when they reappear.

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

- Does not configure your upstream router, switch, DHCP, or firewall.
- Does not provide L3 isolation between VLANs — that's your upstream
  router's job.
- Does not write to NVRAM. All state is recreated at boot and after every
  `restart_wireless`.

## Defaults

| VLAN | Purpose | Bridge |
|------|---------|--------|
| 1    | LAN (untagged) | br0  |
| 30   | Guest          | br30 |
| 40   | IoT            | br40 |

Edit `IOT_VLAN` / `GUEST_VLAN` / `IOT_IFACES` / `GUEST_IFACES` at the top
of each `vlan-bridge-setup` script if you want different VLAN IDs or
different VAPs.

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

Two ways:

### From your workstation

```sh
git clone https://github.com/tmatens/asuswrt-merlin-aimesh-vlan.git
cd asuswrt-merlin-aimesh-vlan

# Step 0: take backups (see "Pre-install backup" above) — do not skip.

# Edit IOT_VLAN / GUEST_VLAN / IOT_IFACES / GUEST_IFACES in:
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

## Extras

- **`tools/iot-isolate.sh`** — temporarily disable AP isolation and
  ebtables on IoT SSIDs across both nodes so IoT devices can pair. Reboot
  restores normal security automatically; the script doesn't write to
  NVRAM.
- **`main/jffs/scripts/monitor-backhaul.sh`** — logs `wds*.0.1` link
  transitions on the wired root, so you can correlate satellite outages
  with backhaul flaps.

## Tested on

- ASUS ZenWiFi ET8 (2-node AiMesh, wireless backhaul) on Asuswrt-Merlin
  gnuton fork 3004.388.10_2.

It should work on any Asuswrt-Merlin AP with the standard `wlN.M`
interface naming and `wds*.0.1` backhaul. If you try it on a different
model, edit `IOT_IFACES` / `GUEST_IFACES` and the `TRUNK` value to match —
they're the only model-specific bits.

## Status / support

No-promise codebase. Issues and PRs welcome but I won't always have time
to respond. If something's broken on your hardware, the scripts are short
(<300 lines each) and the comments are extensive — read and adapt.

## License

[MIT](LICENSE).
