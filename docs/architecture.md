# Architecture

## The problem

Asuswrt-Merlin and AiMesh put **every wireless interface into a single bridge,
`br0`**, regardless of which SSID a client joined. Merlin's "Guest Network"
feature controls client isolation but does not VLAN-tag traffic — every
client lands on the main LAN at L2.

Several things make this hard to fix by hand:

1. **`restart_wireless` wipes manual `brctl` changes.** Any time you flip a
   wireless setting in the UI, run `service restart_wireless`, or have AiMesh
   re-sync, Merlin rebuilds `br0` from scratch and re-attaches every wireless
   interface. Manual fixes survive seconds.
2. **AiMesh satellites silently re-sync mid-runtime.** Even without an
   explicit wireless restart, satellites occasionally drop VAPs back into
   `br0` when the controller pushes a config update. The window can be
   minutes after boot, sometimes longer.
3. **`lan_ifnames` does not work on AiMesh satellites.** Merlin's
   conventional mechanism for changing default bridge membership is ignored
   by `cfg_client`, which manages wireless directly.
4. **The wireless backhaul carries multiple bands simultaneously**, each
   exposed as a `wds*.0.1` interface. Tagged frames must be able to traverse
   any band, so each backhaul interface needs its own VLAN sub-interface.

## The approach

Three cooperating layers, on both the wired root node and each AiMesh
satellite:

### 1. Boot-time setup

`/jffs/scripts/services-start` launches `vlan-bridge-setup` in the
background. The setup script:

- waits for the relevant `wlN.M` interfaces to appear,
- creates `brXX` bridges for each VLAN,
- creates VLAN-tagged sub-interfaces on the trunk (`eth0` on the root,
  `eth6` — the wireless backhaul — on satellites),
- moves the right VAPs out of `br0` and into their VLAN bridge.

On satellites, `/jffs/scripts/init-start` pre-creates the bridges *before*
Merlin's wireless init runs. The NVRAM keys `wlN.M_bridge=brXX` are honoured
at wireless init time **if** the target bridge already exists, so this lets
AiMesh place VAPs directly into the correct bridge instead of having to move
them after the fact.

### 2. `restart_wireless` recovery

`/jffs/scripts/service-event-end` watches Merlin's service events. When a
wireless restart completes, it re-runs `vlan-bridge-setup` to reapply the
bridge layout.

Note that this is the **post-hook**, not `service-event` (the pre-hook).
The pre-hook fires before Merlin rebuilds `br0`, so any work done there is
immediately wiped. The post-hook fires after Merlin is done, giving the
setup script a clean slate to operate on.

### 3. Background drift watcher

The setup script forks a watcher that polls every 30 s and checks whether
each VAP is in its expected bridge. If not, it `brctl delif` from the wrong
bridge and `brctl addif` into the right one, then verifies. Repair count is
preserved in `/tmp/vlan-bridge-watcher.repairs` so you can quantify how
often AiMesh causes drift.

The watcher is essential on AiMesh satellites — without it, mid-runtime VAP
re-syncs leak Guest/IoT clients onto VLAN 1 until the next reboot or
explicit `restart_wireless`.

On the wired root node, the watcher mainly catches a kernel race: bringing
up a new VLAN sub-interface on a bridge-member parent (e.g.
`wds2.0.1.40` on `wds2.0.1`) causes the kernel to auto-add the new
sub-interface to the parent's bridge (`br0`) just before our `brctl addif`
runs.

## Trunk topology

The model assumed by this code:

```
[your upstream router / firewall]
       │  trunk: VLAN1 untagged, VLAN30/40 tagged
       │
[managed switch] ── port to root node (trunk)
       │
[root ET-class node]
   eth0  = trunk uplink to switch
   br0   = untagged (VLAN 1)
   br40  = VLAN 40 → eth0.40
   br30  = VLAN 30 → eth0.30
   wds*.0.1 = wireless backhaul to satellites
                  ├─ untagged  → br0
                  ├─ .40 (VLAN 40 sub) → br40
                  └─ .30 (VLAN 30 sub) → br30

[satellite node]
   eth6  = wireless backhaul to root (trunk-like)
   br0   = untagged (VLAN 1)
   br40  = VLAN 40 → eth6.40
   br30  = VLAN 30 → eth6.30
```

VLAN-aware routing/DHCP happens on your upstream device. This code only
takes care of getting tagged frames off the ET-class APs and onto the wire.

## What you have to supply

- A managed switch (or a router that can accept tagged frames on its uplink).
- An upstream router or firewall that does inter-VLAN routing, DHCP per
  VLAN, and L3 firewalling. OpenWrt, pfSense, OPNsense, VyOS, or a Mikrotik
  all work.
- Asuswrt-Merlin firmware on every ET-class node, JFFS enabled, script
  execution enabled.

## What this code does **not** do

- It does not configure your upstream router. You define VLAN30/VLAN40
  subnets, gateways, and inter-VLAN policy there.
- It does not configure your managed switch.
- It does not write to NVRAM for you (except where you choose to set
  `wlN.M_bridge` keys to optimise satellite boot — that's optional and
  documented in `architecture.md` above).
- It does not provide L3 isolation. Bridges keep traffic separate at L2;
  whether VLAN30 can reach VLAN40 is entirely up to your upstream router's
  firewall.
