# TP-AC750

Travel router config for TP-Link TL-WR902AC v3 (tpac750).

## Quick access
- SSH: `ssh tpac750` (key auth)
- LuCI: http://192.168.10.254

## WireGuard
- Interface: `wg0`
- WPS button toggles `wg0` on/off. `green:wps` LED = WireGuard state (on = up).
- Acts as a quick kill/switch.

## Mode switch (3-position)
Marked on case: `Share ETH * Share HotSpot * AP/Rng Ext / Client`

## LEDs
See `/etc/config/led`. `green:wps` repurposed for WG state.

## Build/flash
```sh
make image-luci
make tftp-prepare && make tftp-serve
# or sysupgrade -n from LuCI/SSH
```
