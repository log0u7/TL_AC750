# Changelog

All notable changes to this project are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed
- Renamed default hostname from `tpac750` to `ac750` (Makefile, README, banner, motd, SSH key comment).
- Repositioned project as secure/hardened travel router (README, banner, motd, repo descriptions).
- `wg-profile split` now validates `split_ips` before modifying state (no partial commit on failure).
- `rc.button/wps` simplified restore flow (removed redundant ifup, cleaner fallback).
- Makefile `CONN` variable: inline comment moved out to avoid fragile parsing.
- Added MIT `LICENSE` file.

### Added
- Build options: `DOH`, `DOH_CUSTOM_URL`, `DOH_BOOTSTRAP`, `DNS_REDIRECT`, `DNS_REDIRECT_PORTS`, `NTP_SERVERS`, `SSH_KEEPALIVE`.
- Optional encrypted DNS (DoH) via `https-dns-proxy` with multi-provider support (quad9, cloudflare, adguard, dns4eu, google, custom).
- Generated `99-doh-config` uci-defaults script for DoH configuration.
- Explicit NTP client config (`system.ntp`, pool servers, `enable_server=0`).
- Dropbear conservative defaults (`SSHKeepAlive`, `GatewayPorts=0`, `MaxAuthTries=3`).
- Quick hardening checklist in README.
- DoH provider notes table (Quad9 France 24/11/2026 caveat).

### Fixed
- `wg-profile split` no longer leaves peer in broken state when `split_ips` is empty.
- README title duplication removed; commercial name (AC750 WiFi Travel Router) added.
- README slider/bouton wording clarified (facade → front panel button).

## [0.0.0] - 2026-11-04

### Added
- Initial OpenWrt 25.12.6 ImageBuilder project for TP-Link TL-WR902AC v3.
- WireGuard skeleton with `off/split/full` profiles.
- 3-position slider + front panel button controls.
- IPv6 disabled on LAN, flow offloading, odhcpd disabled.
- SSH key provisioning via `make keygen`/`make provision`.
- TFTP recovery flash toolkit.