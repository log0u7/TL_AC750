# TL-WR902AC v3 - OpenWrt + WireGuard toolkit

Build, flash and manage OpenWrt on a TP-Link TL-WR902AC v3 pocket travel router,
with WireGuard baked in and a first-boot declarative config overlay.

Device: MediaTek MT7628N @580 MHz, 8 MB flash / 64 MB RAM, 2T2R 2.4 GHz + 1T1R
5 GHz (MT7610 via PCIe), 1x 100 Mb/s Ethernet, USB 2.0, micro-USB power 5V/2A.
OpenWrt marks 8/64 devices NOT RECOMMENDED: few extra packages fit, OOM risk
exists. WireGuard + LuCI fit comfortably in one image.

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

## Image variants

Both variants include `wireguard-tools`, `luci-proto-wireguard`, `kmod-wireguard`
and drop `ppp`/`ppp-mod-pppoe`.

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

## Build-time configuration

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

## Flash procedure (U-Boot TFTP recovery)

The stock TP-Link firmware rejects OpenWrt signatures, so the ONLY way in is the
U-Boot TFTP recovery mode. The bootloader requests a file named `tp_recovery.bin`
from a TFTP server hardcoded at `192.168.0.66`.

```
make tftp-prepare VARIANT=luci   # stage the tftp-recovery image
make pc-ip                       # DEV: 192.168.0.66 + 192.168.10.66
make tftp-serve                  # sudo: start dnsmasq TFTP-only on 192.168.0.66
make flash-watch                 # live log: router request + file sent
```

`make pc-ip` uses the recovery address plus the address matching the LAN_IP
plan above; it collides with nothing else. Then, physically:

1. Router unplugged, LEDs dark.
2. Hold the reset pinhole.
3. Plug USB power WHILE holding, keep held ~8 s (fast LED flicker = recovery
   mode / download starting), release once it flickers fast.
4. Write takes ~1 min (occasional LED blinks), auto-reboot. DO NOT cut power.

## Default addressing plan

| Role | Address |
|---|---|
| Recovery (U-Boot TFTP, hardcoded) | `192.168.0.66` on the PC |
| Router LAN (build default) | `192.168.10.254/24` |
| PC on the router LAN | `192.168.10.66/24` |

Keep exactly one interface per subnet on the flash host: putting a second
interface on a subnet it already reaches by another path blackholes that path
(connected route with lower metric wins, ARP goes out the wrong wire).

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

## WireGuard profiles (slider)

`/usr/bin/wg-profile off|split|full|show` flips the wg peer `allowed_ips`:

| Profile | allowed_ips | LED green:wps |
|---|---|---|
| off | interface disabled | dark |
| split | `network.wg0.split_ips` value | blink 5 Hz |
| full | `0.0.0.0/0 ::/0` | solid |

With no split subnets configured, `split` fails loudly instead of guessing.
The 3-position slider (BTN_0 + BTN_1) drives `wg-profile` through
`/etc/hotplug.d/button/90-slider-wg`; every move is logged (`logread -f slider`).
The selected profile is committed, so it survives reboots. The tunnel only
comes alive once keys and an endpoint exist.

## WireGuard key provisioning

Keys are generated with `wg genkey` on the device itself and stored under
`secrets/` (gitignored, chmod 600); nothing hand-typed, nothing committed.

```
make keygen       # keypair generated ON the device, stored in secrets/
make provision    # push wg_router.key into the device wg0 config over SSH
                  # prints the router pubkey: use it in the SERVER peer config
```

Rotation: delete `secrets/wg_router.key` + `wg_router.pub`, re-run both targets.
The peer shipped empty on purpose: a wg interface with no valid peer simply
stays down and does not disturb the rest of the network.

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

## Hardware buttons/LEDs reference (DTS)

| Item | Code | Default action |
|---|---|---|
| Reset | KEY_RESTART | reboot / long = factory reset / boot failsafe |
| Facade button | KEY_WPS_BUTTON | WPS via hostapd (wpad full only) |
| 3-pos slider | BTN_0 + BTN_1 | none; combos: 00 / 01 / 10 left to right |
| Facade LED | `green:wps` | free; binary LED (max_brightness=1) |

## Gotchas learned the hard way

- OpenWrt 25.12 `uci` network `ipaddr` is CIDR (`'192.168.1.1/24'`). A bare IP
  leaves a broken netmask: ARP answers, everything else is dead.
- Two interfaces in the same subnet on one host = blackhole. The lower-metric
  connected route wins and the other path dies; "answered" pings are ARP-flux
  false positives from the other path.
- A local firewall can silently drop ICMP replies: with ARP resolving and
  ping dead, suspect the flash host's firewall first and confirm with
  `tcpdump -i <if> -n icmp` (replies visible = firewall side).
- ufw status is locale-dependent: test with `LANG=C ufw status | grep "Status: active"`.
- Stock firmware refuses OpenWrt via web upgrade: TFTP recovery is the only entry.
- Reflashing resets the SSH host key and wipes the config: `ssh-keygen -R <ip>`,
  then re-run `make provision`.
- dropbear: `RootPasswordAuth=off` can block root logins entirely (including
  pubkey) on some builds; prefer `PasswordAuth=off` alone and test SSH right
  after each apply.
- The device has no RTC/NTP until it gets uplink: logread timestamps drift.

## Design decisions

- Single function: WireGuard travel router. No mode zoo.
- 3-position slider = WireGuard profile only (off / split / full).
- LED `green:wps` = tunnel profile indicator.
- Reset button: stock behavior (short = reboot, long = factory reset, boot failsafe).
- Device LAN: one /24, gateway at the last usable IP of the range. No /25 split:
  `.127`/`.255` are broadcasts, and two subnets would need VLANs this hardware
  does not justify.
- Kismet-style rogue-AP detection is out of scope here; the radios can run a
  capture tool manually over SSH against a remote analysis host, but monitor
  mode kills the AP on that radio.

## License

MIT - see [LICENSE](LICENSE).

## Sources

- Device page: https://openwrt.org/toh/tp-link/tl-wr902ac_v3
- Original support commit (DTS, buttons/LEDs):
  https://lists.infradead.org/pipermail/lede-dev/2018-March/011566.html
- Current DTS: https://raw.githubusercontent.com/openwrt/openwrt/main/target/linux/ramips/dts/mt76x8/tplink_tl-wr902ac-v3.dts
