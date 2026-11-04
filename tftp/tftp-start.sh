#!/bin/bash
# TFTP server for TL-WR902AC v3 U-Boot recovery.
# Serves tp_recovery.bin over UDP 69 (dnsmasq, TFTP only, no DNS/DHCP).
# Root defaults to the runtime scratch dir (/tmp/opencode/...): dnsmasq runs as
# "nobody" and cannot traverse a private $HOME. Override with TFTP_ROOT.
# Usage: sudo env TFTP_ROOT=... TFTP_IP=... bash tftp-start.sh   (or: make tftp-serve)
set -e

ROOT="${TFTP_ROOT:-/tmp/opencode/wr902ac/tftp}"
IP="${TFTP_IP:-192.168.0.66}"
PID="$ROOT/dnsmasq.pid"
LOG="$ROOT/dnsmasq.log"

if [ ! -f "$ROOT/tp_recovery.bin" ]; then
	echo "ERROR: $ROOT/tp_recovery.bin missing - run: make tftp-prepare VARIANT=luci"
	exit 1
fi

# restart cleanly if already running
if [ -f "$PID" ]; then
	kill "$(cat "$PID")" 2>/dev/null || true
	sleep 1
fi

dnsmasq \
	--port=0 \
	--no-hosts --no-resolv \
	--bind-interfaces \
	--listen-address="$IP" \
	--enable-tftp \
	--tftp-root="$ROOT" \
	--tftp-no-blocksize \
	--pid-file="$PID" \
	--log-facility="$LOG" \
	--log-queries

# firewall: allow UDP 69 only if ufw is active (LANG=C: locale-proof check)
if command -v ufw >/dev/null && LANG=C ufw status | grep -q "Status: active"; then
	IFACE="${TFTP_IFACE:-$(ip -o -4 route show default | grep -oE 'dev [a-z0-9]+' | cut -d' ' -f2)}"
	ufw allow in on "$IFACE" to any port 69 proto udp comment wr902ac-tftp >/dev/null
	echo "UFW_RULE_ADDED ($IFACE)"
fi

# make the transfer log readable by the operator
chmod 644 "$LOG" 2>/dev/null || true

echo "TFTP ready: $IP:69 root=$ROOT (log: $LOG)"
