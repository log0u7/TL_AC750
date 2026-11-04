# TP-LINK TL-WR902AC v3 - OpenWrt + WireGuard toolkit

Everything needed to build, flash, and recover OpenWrt on a TP-Link TL-WR902AC v3
travel router, with WireGuard baked in and a declarative config overlay.

Device: MediaTek MT7628N @580 MHz, 8 MB flash / 64 MB RAM, 2T2R 2.4 GHz + 1T1R
5 GHz (MT7610 via PCIe), 1x 100 Mb/s Ethernet, USB 2.0, micro-USB power 5V/2A.
OpenWrt marks 8/64 devices NOT RECOMMENDED: few extra packages fit, OOM risk
exists. WireGuard + LuCI fit comfortably in one image.

## Repository layout

```
Makefile                      build + flash toolkit (see `make help`)
README.md                     this file
config/files/                 declarative config overlay (FILES=, applied at first boot)
images/
  min/                        build WITHOUT LuCI (WireGuard only)
  luci/                       build WITH LuCI web UI
tftp/tftp-start.sh            dnsmasq-based TFTP server (port 69, root required)
openwrt-imagebuilder-*/       extracted ImageBuilder (488 MB, remove with make clean)
```

Runtime scratch (TFTP root, logs, pidfiles) lives in `/tmp/opencode/wr902ac/tftp`
by default: dnsmasq runs as `nobody` and cannot traverse a private `$HOME`.
Override with `TFTP_ROOT`.

## Requirements

Ubuntu 24.04-ish with: `make gcc zstd xz file python3 gawk curl` (`make deps` checks).
TFTP serving needs root (port 69) and, if ufw is active, a UDP 69 rule
(added automatically by the start script, locale-proof).

## Image variants

Both variants include `wireguard-tools`, `luci-proto-wireguard`, `kmod-wireguard`
and drop `ppp`/`ppp-mod-pppoe` (useless for this use, saves flash).

- `min`: no web UI. SSH-only. Smallest footprint.
- `luci`: full LuCI web UI (`uhttpd` HTTP, no TLS). +400 KB vs min, fits fine.

Build one (or both):

```
make image-min     # -> images/min/
make image-luci    # -> images/luci/
```

Each build verifies the sha256sums of its own outputs before installing them
into `images/<variant>/` alongside the package manifest.

Rebuild with a config overlay once `config/files/` is populated: the overlay is
passed automatically (`FILES=config/files`) and the image ships with its config
applied at first boot.

## Flash procedure (U-Boot TFTP recovery)

The stock TP-Link firmware rejects OpenWrt signatures, so the ONLY way in is the
U-Boot TFTP recovery mode. The bootloader requests a file named `tp_recovery.bin`
from a TFTP server hardcoded at `192.168.0.66`.

```
make tftp-prepare VARIANT=luci   # stage the tftp-recovery image
make pc-ip                       # eth0: 192.168.0.66 + 1.2 + 2.66 (covers all phases)
make tftp-serve                  # sudo: start dnsmasq TFTP-only on 192.168.0.66
make flash-watch                 # live log: router request + file sent
```

Then, physically:

1. Router unplugged, LEDs dark.
2. Hold the reset pinhole.
3. Plug USB power WHILE holding, keep held ~8 s (fast LED flicker = recovery
   mode / download starting), release once it flickers fast.
4. Write takes ~1 min (occasional LED blinks), auto-reboot. DO NOT cut power.

After the reboot the device is OpenWrt factory-fresh: LAN `192.168.1.1`,
DHCP server on, WiFi disabled by default, root with no password.

## Network phases (home LAN is 192.168.1.0/24 - collision handled)

| Phase | PC (eth0) | Router | Used for |
|---|---|---|---|
| Recovery | 192.168.0.66/24 | U-Boot TFTP client | flash |
| Final | 192.168.10.66/24 | LAN 192.168.10.254/24 | normal use |

`make pc-ip` sets both addresses (they collide with nothing, home LAN stays on WiFi).
With the declarative overlay in place, the device boots DIRECTLY on
`192.168.10.254` - no factory-IP phase. `make pc-ip-firstboot` remains as an
escape hatch (temporarily adds `192.168.1.2/24` to reach a factory-default
device, which also blackholes the home LAN on WiFi while set - revert with
`make pc-ip` immediately).

Move the router LAN once, with the CIDR suffix OpenWrt 25.12 expects:

```
uci set network.lan.ipaddr='192.168.2.1/24'
uci commit network
uci show network.lan          # verify BEFORE applying
/etc/init.d/network restart   # kills the SSH session, that is normal
```

Then `make pc-ip` already covers 192.168.2.66/24 on the PC side; LuCI at
`http://192.168.2.1`, first web login forces the root password.
Revert the PC profile with `make pc-ip-restore`.

## First boot checklist

```
passwd                        # set root password (or forced by LuCI)
apk info | grep wireguard     # WG stack is baked in, nothing to install
```

The declarative overlay (`config/files/etc/uci-defaults/99-travel-router`)
applies on first boot: hostname `tpac750`, LAN `192.168.10.254/24` (CIDR form,
OpenWrt 25.12 style), WireGuard `wg0` skeleton + `wgvpn` firewall zone with
masquerade and lan->wgvpn forwarding, no factory SSID, WiFi radios disabled,
`green:wps` LED dark. Secrets (password, WG keys, WiFi PSK) are never in the
repo: set them at first contact.

## WireGuard profiles (slider)

`/usr/bin/wg-profile off|split|full|show` flips the wg peer `allowed_ips`:

| Profile | allowed_ips | LED green:wps |
|---|---|---|
| off | interface disabled | dark |
| split | `192.168.1.0/24` (home) | blink 5 Hz |
| full | `0.0.0.0/0 ::/0` | solid |

The 3-position slider (BTN_0 + BTN_1) drives `wg-profile` through
`/etc/hotplug.d/button/90-slider-wg`; every move is logged (`logread -f slider`)
and the mapping (00=off, 01=split, 11=full) is calibrated on the bench.
The selected profile is committed, so it survives reboots. The tunnel only
comes alive once keys and an endpoint exist (set later, LuCI or SSH).

No Internet on the device by design: its only Ethernet port is LAN. For an
occasional `apk update`, use the PC as a gateway (IP forwarding + masquerade
on the PC, `network.lan.gateway='192.168.10.66'` on the router) - do not keep
that open longer than needed. For anything durable, add the package to the
ImageBuilder build instead (8 MB flash has little headroom).

## Upgrades

No OTA. When a new OpenWrt release drops:

1. Bump `VERSION` (and `IB_SHA256` from the matching `sha256sums` file).
2. `make image-luci` (config overlay applied if present).
3. Flash the new `sysupgrade.bin` via LuCI (*System > Backup/Flash firmware*)
   or `scp` + `sysupgrade /tmp/*.bin` - config is preserved.
   Use `-n` only for a factory-reset reflash.

TFTP recovery stays the emergency path; a TFTP reflash wipes the config
(rootfs is rewritten wholesale).

## Recovery / brick ladder

1. Failsafe boot: hold reset at power-on until the LED flashes fast early in
   boot. Fixed `192.168.1.1`, no config applied. `ssh root@192.168.1.1`
   (passwordless), `mount_root`, fix `/etc/config/network` with uci, reboot.
2. U-Boot TFTP recovery (this repo's `tftp-serve` + `flash-watch`): rewrites
   the firmware partition, works whatever the OS state. Proven working twice
   in a row on this unit.
3. Serial console: 3.3 V, 115200 8N1, pads next to the LAN port (VCC, GND, RX, TX).

Back to stock TP-Link firmware: strip its 512-byte header
(`dd if=stock.bin of=tp_recovery.bin skip=257 bs=512`) and TFTP it.

## Design decisions (agreed)

- Single function: WireGuard travel router. No mode zoo.
- 3-position slider = WireGuard profile only:
  1. no tunnel (direct hotel access),
  2. split tunnel (`allowed_ips` = home subnets only),
  3. full tunnel (`allowed_ips 0.0.0.0/0,::/0`).
  Implementation: flip the wg peer `allowed_ips` via uci + interface restart.
  Slider GPIOs: BTN_0 + BTN_1 (`gpio-keys-polled`, no default action).
- LED `green:wps` (GPIO 4) = tunnel state indicator.
- Facade WPS button (KEY_WPS_BUTTON): free for now.
- Reset button: stock behavior (short = reboot, long = factory reset, boot failsafe).
- Kismet rogue-AP probe: manual launch over SSH only, never wired to the slider
  (monitor mode kills the AP on that radio; intelligence lives on a deferred Pi3).
- Tunnel config (keys, peers, endpoints): provisioned, never hand-typed - see below.

## WireGuard key provisioning

Keys are generated locally and pushed over SSH; nothing hand-typed, nothing
committed. `secrets/` is gitignored and chmod 700/600.

```
make keygen       # keypair generated ON the device (wg genkey), stored in secrets/
make provision    # push wg_router.key into the device wg0 config over SSH
                  # prints the router pubkey: use it in the SERVER peer config
```

Rotation: delete `secrets/wg_router.key` + `wg_router.pub`, re-run both targets.
When the home server (Pi) exists with a real endpoint and public key, complete
the peer (LuCI or `uci set network.@wireguard_wg0[0].public_key=...`), or bake
the full peer config into future images via a generated overlay in `config/`.
The peer shipped empty on purpose: a wg interface with no valid peer simply
stays down and does not disturb the rest of the network.
- Upstream mode (hotel Ethernet vs hotel WiFi STA): configured manually,
  not slider-controlled.
- Device LAN: `192.168.10.0/24`, gateway at `192.168.10.254` (last usable IP,
  "gateway at the top of the pool"). No /25 split: `.127`/`.255` are broadcasts,
  and two subnets would need VLANs this hardware does not justify.

## Hardware buttons/LEDs reference (DTS)

| Item | Code | Default action |
|---|---|---|
| Reset | KEY_RESTART | reboot / long = factory reset / boot failsafe |
| Facade button | KEY_WPS_BUTTON | WPS via hostapd (wpad full only) |
| 3-pos slider | BTN_0 + BTN_1 | none |
| Facade LED | `green:wps` | free, usable as tunnel indicator |

## Gotchas learned the hard way

- OpenWrt 25.12 `uci` network `ipaddr` is CIDR (`'192.168.2.1/24'`). A bare IP
  leaves a broken netmask: ARP answers, everything else is dead.
- Two interfaces in the same subnet = blackhole. With `192.168.1.2/24` on eth0
  and the home LAN on WiFi, Linux routes the whole /24 to eth0 (lower metric)
  and WiFi hosts become unreachable; pings "answered" on eth0 are ARP-flux
  replies from WiFi hosts, pure false positives. Keep one interface per subnet.
- ufw status is locale-dependent: test with `LANG=C ufw status | grep "Status: active"`.
- Stock firmware refuses OpenWrt via web upgrade: TFTP recovery is the only entry.
- Reflashing resets the SSH host key: `ssh-keygen -R 192.168.1.1` (or the LAN IP).

## Sources

- Device page: https://openwrt.org/toh/tp-link/tl-wr902ac_v3
- Original support commit (DTS, buttons/LEDs):
  https://lists.infradead.org/pipermail/lede-dev/2018-March/011566.html
- Current DTS: https://raw.githubusercontent.com/openwrt/openwrt/main/target/linux/ramips/dts/mt76x8/tplink_tl-wr902ac-v3.dts
