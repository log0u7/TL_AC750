# TL-WR902AC v3 - OpenWrt + WireGuard travel router

# TL-WR902AC v3 - OpenWrt + WireGuard travel router

Minimal OpenWrt build for the TP-Link TL-WR902AC v3, tailored for travel with
WireGuard. Slider picks the routing profile, facade button acts as a temporary
tunnel kill switch. Configured via `config/files/` overlay and generated site values.

Device: MediaTek MT7628N @580 MHz, 8 MB flash / 64 MB RAM, 2T2R 2.4 GHz + 1T1R
5 GHz (MT7610 via PCIe), 1x 100 Mb/s Ethernet, USB 2.0, micro-USB power 5V/2A.
WireGuard + LuCI fit comfortably in one image.

## Repository layout

```
Makefile                      build + flash toolkit (see `make help`)
config/files/                 static declarative overlay (FILES=, first boot)
config-gen/                   generated per build: site values (LAN_IP, HOSTNAME, TZ)
images/                       built images per variant (manifests + checksums kept in git, payloads excluded)
tftp/tftp-start.sh            dnsmasq-based TFTP server (port 69, root required)
```

Runtime scratch (TFTP root, logs, pidfiles) lives in `/tmp/wr902ac-tftp`
by default: dnsmasq runs as `nobody` and cannot traverse a private `$HOME`,
so the directory must be world-traversable. Override with `TFTP_ROOT`.
Transient key material during `keygen`/`provision` lives under `secrets/`
(chmod 700), never in a world-readable tmp path.

## Requirements

Linux host with `make gcc zstd xz file python3 gawk curl` (`make deps` checks).
TFTP serving needs root (port 69) and, if a firewall is active, an allow rule
for UDP 69 inbound on the cabled interface (the start script adds it for ufw).

## Build

Both variants include `wireguard-tools`, `luci-proto-wireguard`,
`kmod-wireguard` and drop `ppp`/`ppp-mod-pppoe`.

- `min`: no web UI. SSH-only. Smallest footprint.
- `luci`: full LuCI web UI over HTTP. Fits alongside WireGuard.

```
make image-min     # -> images/min/
make image-luci    # -> images/luci/
```

Each build verifies its outputs against `sha256sums` before installing them
into `images/<variant>/`. The image payload `.bin` files are not tracked in
git: rebuild them from this repo (the manifests and checksums pin what was
built).

Site values are injected into a generated `99-site-config` uci-defaults script
(executed once at first boot). Override on the command line or edit the
defaults:

| Variable  | Default            | Effect |
|---|---|---|
| `LAN_IP`  | `192.168.10.254/24` | router LAN address (CIDR required on OpenWrt 25.12) |
| `HOSTNAME`| `tpac750`           | system hostname |
| `TZ`      | `Europe/Paris`      | system timezone |

```
make image-luci LAN_IP=192.168.1.1/24 HOSTNAME=travelrouter
```

Pick any RFC1918 subnet that does not collide with networks you will roam in.
The DHCP pool follows the LAN automatically.

## Flash (U-Boot TFTP recovery)

The stock TP-Link firmware rejects OpenWrt signatures, so the ONLY way in is
the U-Boot TFTP recovery mode. The bootloader requests a file named
`tp_recovery.bin` from a TFTP server hardcoded at `192.168.0.66`.

```
make tftp-prepare VARIANT=luci   # stage the tftp-recovery image
make pc-ip                       # DEV: 192.168.0.66 + 192.168.10.66
make tftp-serve                  # sudo: start dnsmasq TFTP-only on 192.168.0.66
make flash-watch                 # live log: router request + file sent
```

`make pc-ip` uses the recovery address plus the address matching the LAN_IP
plan below; it collides with nothing else. Then, physically:

1. Router unplugged, LEDs dark.
2. Hold the reset pinhole.
3. Plug USB power WHILE holding, keep held ~8 s (fast LED flicker = recovery
   mode / download starting), release once it flickers fast.
4. Write takes ~1 min (occasional LED blinks), auto-reboot. DO NOT cut power.

## Addressing plan

| Role | Address |
|---|---|
| Recovery (U-Boot TFTP, hardcoded) | `192.168.0.66` on the PC |
| Router LAN (build default) | `192.168.10.254/24` |
| PC on the router LAN | `192.168.10.66/24` |

Keep exactly one interface per subnet on the flash host: a second interface on
a subnet already reached by another path blackholes that path (connected route
with lower metric wins).

## First boot

The declarative overlay applies once at first boot: hostname, LAN address,
WireGuard `wg0` skeleton (no keys, no peer) with a dedicated firewall zone and
lan->wgvpn forwarding, no factory SSID, WiFi radios disabled, `green:wps` LED
dark. What stays blank is configured post-flash:

| Setting | How |
|---|---|
| root password | `passwd` over SSH, or first LuCI login |
| WiFi SSID/PSK | LuCI > Network > Wireless, or uci |
| WG peer (server pubkey, endpoint) | LuCI > Network > Interfaces > wg0, or uci |
| split-tunnel subnets | `uci set network.wg0.split_ips='a.b.c.d/e ...'` |

## WireGuard

### Key provisioning

Keys are generated with `wg genkey` on the device itself and stored under
`secrets/` (gitignored, chmod 600); nothing hand-typed, nothing committed.

```
make keygen       # keypair generated ON the device, stored in secrets/
make provision    # push wg_router.key into the device wg0 config over SSH
                  # prints the router pubkey: use it in the SERVER peer config
```

Rotation: delete `secrets/wg_router.key` + `wg_router.pub`, re-run both targets.
The peer ships empty on purpose: a wg interface with no valid peer simply
stays down and does not disturb the rest of the network.

### Tunnel controls

`/usr/bin/wg-profile off|split|full|show` flips the wg peer `allowed_ips`:

| Profile | allowed_ips | LED green:wps |
|---|---|---|
| off | interface disabled | dark |
| split | `network.wg0.split_ips` value | blink 5 Hz |
| full | `0.0.0.0/0 ::/0` | solid |

With no split subnets configured, `split` fails loudly instead of guessing.
The selected profile is committed, so it survives reboots. The tunnel only
comes alive once keys and an endpoint exist.

- **3-position slider** (BTN_0 + BTN_1, combos `00` / `01` / `10` left to
  right) drives `wg-profile` through `/etc/hotplug.d/button/90-slider-wg`;
  every move is logged (`logread -f slider`).
- **Facade button** is a hard on/off for the tunnel: each press toggles `wg0`
  down/up regardless of the slider position (`/etc/rc.button/wps`). A kill
  lasts until the next button press, slider move or reboot: `wg-profile` ends
  with `ifup wg0`, so any slider move restores the tunnel with the selected
  profile.

## Optimizations applied

| Change | Why |
|---|---|
| IPv6 off on LAN (`ra`/`dhcpv6`/`ndp` disabled, `lan.ipv6='0'`), `odhcpd` stopped + disabled | no IPv6 use while roaming; less RAM/CPU |
| Software flow offloading (`firewall.@defaults[0].flow_offloading='1'`) | faster NAT on the MT7628 |
| `dnsmasq` `logqueries='0'` | less log noise |
| apk opkg-cheatsheet login notice removed | noise at every SSH login |
| Custom `/etc/banner` + `/etc/motd` | orientation at login |
| `/etc/config/led`: usb=`usbport`, wps=tunnel indicator, wlan=`netdev` | useful signals only |

Persistence: everything above is baked into the overlay (`config/files/`).
The uci tweaks (IPv6, flow offloading, dnsmasq, odhcpd) and the apk-notice
removal run once at first boot via `99-travel-router` (the `FILES=` overlay
can only add/overwrite files, so the notice is deleted by the script
instead). A factory reset or reflash reapplies all of it.

## Upgrades

No OTA. When a new OpenWrt release drops:

1. Bump `VERSION` (and `IB_SHA256` from the matching `sha256sums` file).
2. `make image-luci` (site values regenerated from the current variables).
3. Flash the new `sysupgrade.bin` via LuCI (*System > Backup/Flash firmware*)
   or `scp` + `sysupgrade /tmp/*.bin` - config is preserved.
   Use `-n` only for a factory-reset reflash.

TFTP recovery stays the emergency path; a TFTP reflash wipes the config
(rootfs is rewritten wholesale), so re-run `make provision` afterwards.

## Recovery / brick ladder

1. Failsafe boot: hold reset at power-on until the LED flashes fast early in
   boot. Fixed `192.168.1.1`, no config applied. `ssh root@192.168.1.1`
   (passwordless), `mount_root`, inspect and fix `/etc/config/network`, reboot.
2. U-Boot TFTP recovery (this repo's `tftp-serve` + `flash-watch`): rewrites
   the firmware partition, works whatever the OS state. On a fresh install,
   SSH key auth comes straight from the image (`config/files/etc/dropbear/`).
3. Serial console: 3.3 V, 115200 8N1, pads next to the LAN port (VCC, GND, RX, TX).

Back to stock TP-Link firmware: strip its 512-byte header
(`dd if=stock.bin of=tp_recovery.bin skip=257 bs=512`) and TFTP it.

## Controls

### 3-position slider
The slider selects the default WireGuard routing policy:

| Position | Profile | LED `green:wps` | Usage |
|---|---|---|---|
| **Share ETH** (left) | `split` | Blink 5 Hz | Only traffic to your home network goes through the tunnel. Keeps direct access to the hotel/cafe LAN, printers or captive portals. |
| **Share HotSpot** (middle) | `full` | Solid | All traffic goes through the tunnel. Ideal when sharing this router's connection via WiFi. |
| **AP/Rng Ext / Client** (right) | `off` | Dark | Direct connection with no tunnel. Use the WPS button to re-enable the tunnel quickly without moving the slider. |

### WPS button (facade)
Temporary tunnel kill switch. Pressing it toggles `wg0` up/down regardless of the slider. While killed, the tunnel stays down until the next button press, slider move or reboot.

The native WPS protocol is not used (security liability). While killed, the LED stays dark. On restore, the LED follows the current slider position.

### LEDs
| LED | Meaning |
|---|---|
| `green:wps` | Tunnel state (dark = off/killed, blink 5 Hz = split, solid = full) |
| `green:power` | Power |
| `green:lan` / `green:wan` | LAN/WAN link/activity |
| `green:wlan` / `mt76-phy1` | 2.4GHz / 5GHz activity |
| `green:usb` | USB device present |

## License

MIT - see [LICENSE](LICENSE).

## Sources

- Device page: https://openwrt.org/toh/tp-link/tl-wr902ac_v3
- Original support commit (DTS, buttons/LEDs):
  https://lists.infradead.org/pipermail/lede-dev/2018-March/011566.html
- Current DTS: https://raw.githubusercontent.com/openwrt/openwrt/main/target/linux/ramips/dts/mt76x8/tplink_tl-wr902ac-v3.dts
