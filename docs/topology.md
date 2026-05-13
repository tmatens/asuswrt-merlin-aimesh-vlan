# Topology

This is a worked example of the assumed network shape. Adapt freely.

## Example physical layout

```
   Internet
      │
   [WAN]
[upstream router]                  ── Does VLAN routing, DHCP, firewall.
   │  trunk port:                     Examples: OpenWrt, pfSense, OPNsense,
   │    VLAN  1  untagged (LAN)       VyOS, Mikrotik.
   │    VLAN 30  tagged (Guest)
   │    VLAN 40  tagged (IoT)
   │
[managed switch]                   ── e.g. TP-Link TL-SG108E, Mikrotik CRS,
   │                                  Netgear GS308E. Must support 802.1Q.
   ├── port: trunk to root node (same VLAN config as upstream)
   ├── port: untagged VLAN 1 to a wired LAN client
   └── port: untagged VLAN 40 to a wired IoT client (optional)
   │
[root AiMesh node]                 ── Asuswrt-Merlin, AP mode.
   │   eth0 = trunk uplink
   │   wifi: Main / Main-IoT / Main-Guest SSIDs
   │   wireless backhaul ─────┐
   │                          │
[satellite AiMesh node]   <───┘   ── Asuswrt-Merlin, AP mode.
       eth6 = backhaul "trunk"
       wifi: Main / Main-IoT / Main-Guest SSIDs (same names, different VAPs)
```

## Default VLAN layout

These are the values baked into the scripts. Edit the scripts (search for
`IOT_VLAN`, `GUEST_VLAN`) if you want different VLAN IDs.

| VLAN | Purpose | Bridge | Trunk sub-iface (root) | Trunk sub-iface (satellite) |
|------|---------|--------|------------------------|-----------------------------|
| 1    | LAN     | br0    | eth0 (untagged)        | eth6 (untagged)             |
| 30   | Guest   | br30   | eth0.30                | eth6.30                     |
| 40   | IoT     | br40   | eth0.40                | eth6.40                     |

## Default SSID → bridge map

### Root node

| SSID         | 2.4 GHz | 5 GHz | 6 GHz | Bridge |
|--------------|---------|-------|-------|--------|
| Main         | wl0     | wl1   | wl2   | br0    |
| Main-IoT     | wl0.1   | wl1.1 | wl2.1 | br40   |
| Main-Guest   | wl0.2   | wl1.2 | —     | br30   |

### Satellite node

| SSID         | 2.4 GHz | 5 GHz | 6 GHz | Bridge |
|--------------|---------|-------|-------|--------|
| Main         | wl0.1   | wl1.1 | —     | br0    |
| Main-IoT     | wl0.2   | wl1.2 | wl2.2 | br40   |
| Main-Guest   | wl0.3   | wl1.3 | —     | br30   |
| Backhaul SSID| —       | —     | wl2.1 | br0    |
| AiMesh internal | —    | —     | wl2.6 | br0    |

**Note the index shift.** On the root, `wl0` is the primary SSID. On a
satellite, AiMesh uses `wl0` for the backhaul probe and `wl0.1` for the
primary SSID, pushing IoT to `wl0.2` and Guest to `wl0.3`. The scripts
hardcode this difference. If your AiMesh assigns indexes differently, edit
`IOT_IFACES` / `GUEST_IFACES` near the top of each `vlan-bridge-setup`.

## Verifying VAP-to-SSID mapping on your nodes

If you're not sure which `wlN.M` corresponds to which SSID, ssh in and run:

```sh
for iface in wl0 wl0.1 wl0.2 wl0.3 wl1 wl1.1 wl1.2 wl1.3 wl2 wl2.1 wl2.2 wl2.3; do
    name=$(nvram get ${iface}_ssid 2>/dev/null)
    [ -n "$name" ] && echo "$iface = $name"
done
```

That list is what the scripts assume. Adjust the `IOT_IFACES` /
`GUEST_IFACES` constants in `vlan-bridge-setup` to match.
