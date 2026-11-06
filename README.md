# TL-AC750 (TP-Link TL-WR902AC v3) — Secure OpenWrt travel router

Minimal, hardened OpenWrt build for the TP-Link TL-WR902AC v3 (AC750 WiFi Travel
Router), designed for travel/public networks. It combines WireGuard with physical
controls (3-position slider + front panel button) and optional encrypted DNS
(DoH). Config is applied via an ImageBuilder overlay (`config/files/`) and
generated site values.

> Security note: this project **hardens** travel use; it does not guarantee
> anonymity or complete protection. Effectiveness depends on your WireGuard
> server, peer config, upstream DNS choice, captive portal behavior, and
> post-flash settings.

Device: MediaTek MT7628N @580 MHz, 8 MB flash / 64 MB RAM, 2T2R 2.4 GHz + 1T1R
5 GHz (MT7610 via PCIe), 1x 100 Mb/s Ethernet, USB 2.0, micro-USB power 5V/2A.
WireGuard + LuCI fit in one image; optional DoH adds packages and must be
validated for flash/RAM headroom.

## Security posture (factual)

| Area | Current behavior | Limits |
|---|---|---|
| Tunnel | WireGuard `wg0` skeleton + `off/split/full` profiles; slider selects profile; front panel button is a temporary kill switch | WG full tunnel routes through your peer, not anonymity. Split profile needs `network.wg0.split_ips`. |
| DNS | Default: system DNS behavior. Optional: DoH via `https-dns-proxy` to a selected provider (`DOH=...`) | `DNS_REDIRECT=1` can reduce DNS leaks (53/853 interception) but **may break captive portals**; default is `0`. Apps can still use hardcoded/non-DNS methods in some cases. |
| Services | WiFi radios off by default, no factory SSID; IPv6 disabled on LAN; `odhcpd` disabled; explicit NTP client | You enable WiFi/SSID/PSK post-flash for each trip. |
| SSH | Key baked via overlay; conservative dropbear defaults (`SSHKeepAlive`, `GatewayPorts=0`, `MaxAuthTries=3`, port 22) | **Do not bake `RootPasswordAuth=off`** on TL-WR902AC v3/OpenWrt 25.12.6 (observed pubkey lockout/flapping; see gotchas). |
| Updates | No OTA; rebuild/flash on new OpenWrt releases | TFTP recovery rewrites firmware config; sysupgrade preserves config unless `-n`. |

## Repository layout

```
Makefile                      build + flash toolkit (see `make help`)
config/files/                 static declarative overlay (FILES=, first boot)
config-gen/                   generated per build: site values and optional DoH config
images/                       built images per variant (manifests/checksums kept; payloads excluded)
tftp/tftp-start.sh            dnsmasq-based TFTP server (port 69, root required)
```

Runtime scratch (TFTP root, logs, pidfiles) lives in `/tmp/wr902ac-tftp` by
default (`TFTP_ROOT` overrides). Transient key material during `keygen`/
`provision` lives under `secrets/` (chmod 700).

## Requirements

Linux host with `make gcc zstd xz file python3 gawk curl` (`make deps` checks).
TFTP serving needs root (port 69). If a firewall is active, allow UDP 69 inbound
on the cabled interface.

## Build options

Both variants include WireGuard packages and drop `ppp`/`ppp-mod-pppoe`.

| Var | Default | Effect |
|---|---|---|
| `VARIANT` | `luci` | `min` (SSH-only) or `luci` (web UI) |
| `LAN_IP` | `192.168.10.254/24` | router LAN address (CIDR) |
| `HOSTNAME` | `tpac750` | system hostname |
| `TZ` | `Europe/Paris` | timezone/zonename (build-time) |
| `NTP_SERVERS` | OpenWrt pool (4 servers) | explicit `system.ntp` client, `enable_server=0` |
| `DOH` | `off` | `off|quad9|quad9-unfiltered|cloudflare|adguard|dns4eu|google|custom` |
| `DOH_CUSTOM_URL` | empty | required when `DOH=custom` (RFC 8484 URL). Hook for self-hosted resolver / Raspberry Pi DoH endpoint. |
| `DOH_BOOTSTRAP` | provider-specific | bootstrap DNS IPs for resolving the DoH hostname |
| `DNS_REDIRECT` | `0` | `1` sets `https-dns-proxy force_dns=1` (intercepts LAN DNS ports). **May break captive portals**. |
| `DNS_REDIRECT_PORTS` | `53 853` | ports intercepted when `DNS_REDIRECT=1` |
| `SSH_KEEPALIVE` | `60` | dropbear `SSHKeepAlive` |

```sh
make image-min
make image-luci
make image-luci DOH=quad9 DNS_REDIRECT=0
make image-luci DOH=custom DOH_CUSTOM_URL='https://dns.example.net/dns-query' DOH_BOOTSTRAP='192.168.10.2'
```

When `DOH!=off`, the build adds `https-dns-proxy` (+ `luci-app-https-dns-proxy`
for `luci`) and generates `99-doh-config`, replacing package default instances.
On this 8 MB / 64 MB target, **validate image size and runtime RAM** before
deployment.

| `DOH` value | Default endpoint intent | Notes |
|---|---|---|
| `quad9` | Quad9 filtered DoH | **France service announced to stop 2026-11-24**; keep an alternate ready. |
| `quad9-unfiltered` | Quad9 no-threat-blocking DoH | Same jurisdiction/availability risk. |
| `cloudflare` | Cloudflare DoH | Broad availability; verify policy/jurisdiction for your use. |
| `adguard` | AdGuard DoH | Filtering/policy differs by endpoint variant; verify. |
| `dns4eu` | DNS4EU protective DoH | EU-focused option; verify current policy/blocks. |
| `google` | Google DoH | Robust; less privacy-first. |
| `custom` | `DOH_CUSTOM_URL` | Best hook for a Raspberry Pi / self-hosted resolver. |

Verify endpoints/bootstrap IPs in the Makefile and upstream provider templates
before production use. Provider availability and policies can change.

## Flash (U-Boot TFTP recovery)

The stock TP-Link firmware rejects OpenWrt signatures, so the only entry path is
U-Boot TFTP recovery. The bootloader requests `tp_recovery.bin` from a TFTP
server hardcoded at `192.168.0.66`.

```sh
make tftp-prepare VARIANT=luci
make pc-ip
make tftp-serve      # sudo
make flash-watch
```

1. Router unplugged, LEDs dark.
2. Hold reset.
3. Plug USB power while holding, keep held ~8 s (fast LED flicker = recovery).
4. Write takes ~1 min, auto-reboot. Do not cut power.

## Addressing plan

| Role | Address |
|---|---|
| Recovery (U-Boot TFTP) | `192.168.0.66` on the PC |
| Router LAN (default) | `192.168.10.254/24` |
| PC on router LAN | `192.168.10.66/24` |

Pick an RFC1918 subnet that does not collide with networks you roam in.

## First boot

The overlay applies once at first boot: hostname/LAN, WireGuard `wg0` skeleton
(no keys/peer), dedicated firewall zone with lan->wgvpn forwarding, no factory
SSID, WiFi radios disabled, WPS LED dark, NTP client, conservative dropbear
settings.

| Setting | How |
|---|---|
| root password | `passwd` over SSH, or first LuCI login |
| WiFi SSID/PSK | LuCI > Network > Wireless, or uci |
| WG peer (server pubkey, endpoint) | LuCI/LuCI-proto-wireguard or uci |
| split-tunnel subnets | `uci set network.wg0.split_ips='a.b.c.d/e ...'` |

## Quick hardening checklist (post-flash)

- [ ] SSH key login works in a **new** session before closing the current one.
- [ ] Set a strong root password or use key-only **only** with tested recovery path (on this model, avoid `RootPasswordAuth=off`).
- [ ] Provision WG keys (`make keygen`/`make provision`), set server pubkey/endpoint, test `wg-profile show` and handshake.
- [ ] If using DoH: verify resolver, test DNS resolution, keep `DNS_REDIRECT=0` first on captive-portal networks.
- [ ] Before trusting traffic on public WiFi: confirm tunnel/profile, DNS behavior, and captive portal completed.
- [ ] Physically verify slider position mapping (deferred) and label behavior.
- [ ] Backup working config (`sysupgrade -b ...`) after validation.

## WireGuard

### Key provisioning

```sh
make keygen       # keypair generated ON the device, stored in secrets/
make provision    # push private key into device wg0 config
```

Rotation: delete `secrets/wg_router.key` + `wg_router.pub`, rerun both.

### Profiles

`/usr/bin/wg-profile off|split|full|show` flips peer `allowed_ips` and commits
config:

| Profile | allowed_ips | LED green:wps |
|---|---|---|
| off | interface disabled | dark |
| split | `network.wg0.split_ips` | blink 5 Hz |
| full | `0.0.0.0/0 ::/0` | solid |

`split` fails clearly if `network.wg0.split_ips` is empty.

## Controls

> Slider physical mapping/labels in this README may need field verification on
> the actual device (deferred).

### 3-position slider
Selects the default WireGuard routing policy via `/etc/hotplug.d/button/90-slider-wg`.
The current documented mapping is:

| Position | Profile | LED `green:wps` | Usage |
|---|---|---|---|
| **Share ETH** (left) | `split` | Blink 5 Hz | Home-network traffic through tunnel; keeps local LAN/captive portal access patterns possible. |
| **Share HotSpot** (middle) | `full` | Solid | All traffic through tunnel. |
| **AP/Rng Ext / Client** (right) | `off` | Dark | No tunnel. |

### Front panel button (WPS)
Temporary tunnel kill switch (`/etc/rc.button/wps`): toggles `wg0` down/up
regardless of slider, using `/tmp/.wg-kill`. Lasts until next button press,
slider move, or reboot. Native WPS protocol is not used.

## Optimizations / hardening applied

| Change | Why |
|---|---|
| IPv6 off on LAN; `odhcpd` disabled | reduced surface/noise while roaming |
| Flow offloading | better NAT performance on MT7628 |
| `dnsmasq` `logqueries=0` | less log noise |
| Explicit NTP client (`system.ntp`, pool, `enable_server=0`) | reliable time for WG/logs |
| Dropbear conservative defaults (`SSHKeepAlive`, `GatewayPorts=0`, `MaxAuthTries=3`) | fewer drops; small hardening without lockout |
| WiFi off, no factory SSID | explicit opt-in per trip |
| apk opkg-cheatsheet notice removed | login noise |
| Custom banner/motd, useful LEDs | operator clarity |

Persistence: baked in `config/files/` and generated `config-gen/` scripts at
build time; first-boot uci-defaults apply and are removed by OpenWrt.

## DoH, captive portals, Raspberry Pi hook

- **`DNS_REDIRECT=0` (default)**: safer for hotel/cafe captive portals.
- **`DNS_REDIRECT=1`**: stronger DNS policy (intercepts 53/853) but can prevent
  portal login before authentication. Use only if you accept that trade-off.
- **Raspberry Pi / dedicated resolver**: use `DOH=custom` to point the router at
  a DoH endpoint hosted on your Pi (LAN or over WG). Alternatively, keep
  `DOH=off` and forward DNS to a trusted local resolver (future hook).

## Dropbear gotchas (TL-WR902AC v3 / OpenWrt 25.12.6)

Observed on this device/build (memory):
- `RootPasswordAuth=off` (especially combined with password auth off) caused
  root pubkey lockout/flapping.
- Runtime dropbear restarts can temporarily break pubkey auth until recovery.

Safe practice: keep a session open, test a second SSH login after changes, never
bake `RootPasswordAuth=off` by default for this model. Port 22 is kept (LAN
exposure context; port change is mostly obscurity).

## Upgrades

1. Bump `VERSION` / `IB_SHA256`.
2. Rebuild (`make image-luci ...`).
3. Flash `sysupgrade.bin` via LuCI or `sysupgrade` (config preserved; use `-n`
   only for factory reset).
4. TFTP reflash rewrites firmware/config; rerun `make provision` after recovery.

## Recovery / brick ladder

1. Failsafe boot: hold reset at power-on until early fast flash. `192.168.1.1`,
   passwordless root, `mount_root`.
2. U-Boot TFTP recovery (`tftp-serve` + `flash-watch`).
3. Serial console: 3.3V, 115200 8N1.

## License

MIT - see [LICENSE](LICENSE).

## Sources

- Device page: https://openwrt.org/toh/tp-link/tl-wr902ac_v3
- OpenWrt ImageBuilder: https://openwrt.org/docs/guide-user/additional-software/imagebuilder
- https-dns-proxy: https://github.com/openwrt/packages/tree/openwrt-25.12/net/https-dns-proxy
