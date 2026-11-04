# TL-WR902AC v3 / OpenWrt - image builder + flash toolkit
# See README.md for the full procedure.

VERSION   ?= 25.12.6
TARGET    ?= ramips/mt76x8
PROFILE   ?= tplink_tl-wr902ac-v3
IB_SHA256 ?= 7f26c50440cadd83362c444778f80f4a214ee76f3c192ef85ef074f2c56d89ec

IB_LOC  ?= $(CURDIR)
IB_NAME := openwrt-imagebuilder-$(VERSION)-ramips-mt76x8.Linux-x86_64
IB_URL  := https://downloads.openwrt.org/releases/$(VERSION)/targets/$(TARGET)/$(IB_NAME).tar.zst
IB_DIR  := $(IB_LOC)/$(IB_NAME)
IB_BIN  := $(IB_DIR)/bin/targets/$(TARGET)

PKG_min  := wireguard-tools luci-proto-wireguard kmod-wireguard -ppp -ppp-mod-pppoe
PKG_luci := $(PKG_min) luci

# declarative config overlay: applied at first boot if config/files exists
FILES := $(if $(wildcard $(CURDIR)/config/files),FILES=$(CURDIR)/config/files,)

TFTP_ROOT ?= /tmp/opencode/wr902ac/tftp
TFTP_IP   ?= 192.168.0.66
DEV       ?= eth0
CONN      ?= Connexion filaire 1
SSH_OPTS  := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
PC_IPS       := 192.168.0.66/24,192.168.10.66/24
PC_IPS_FIRST := 192.168.0.66/24,192.168.1.2/24,192.168.10.66/24

VARIANT ?= luci

SECRETS   := $(CURDIR)/secrets
SECRETS_SSH := $(CURDIR)/config/files/etc/dropbear/authorized_keys
WG_HOST   ?= root@192.168.10.254
WG_IFACE  ?= wg0

.DEFAULT_GOAL := help

.PHONY: help deps imagebuilder image-min image-luci tftp-prepare tftp-serve tftp-stop flash-watch pc-ip pc-ip-restore provision-ssh clean

help: ## show this help
	@echo "Variables: VERSION=$(VERSION) PROFILE=$(PROFILE) VARIANT=$(VARIANT)"
	@echo "           TFTP_ROOT=$(TFTP_ROOT) TFTP_IP=$(TFTP_IP) DEV=$(DEV) CONN=\"$(CONN)\""
	@echo
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  WARNING: pc-ip / tftp-serve / tftp-stop mutate host state (NetworkManager,"
	@echo "           root, ufw). Revert with pc-ip-restore, tftp-stop."

deps: ## check host build dependencies
	@for c in make gcc zstd xz file python3 gawk curl; do \
		command -v $$c >/dev/null || { echo "MISSING: $$c"; exit 1; }; \
	done
	@echo "host deps OK"

imagebuilder: ## download + verify + extract the ImageBuilder
	@test -d "$(IB_DIR)" && echo "imagebuilder present: $(IB_DIR)" || { \
		mkdir -p tmp-build && cd tmp-build && \
		curl -fsSL -o ib.tar.zst $(IB_URL) && \
		echo "$(IB_SHA256)  ib.tar.zst" | sha256sum -c - && \
		zstd -d -f ib.tar.zst -o ib.tar && tar xf ib.tar && \
		mv $(IB_NAME) $(IB_LOC)/ && cd .. && rm -rf tmp-build ; }
	@echo "imagebuilder ready: $(IB_DIR)"

define build_variant
	mkdir -p $(3)
	$(MAKE) -C $(IB_DIR) image PROFILE=$(PROFILE) PACKAGES="$(2)" $(FILES)
	cd $(IB_BIN) && sha256sum -c sha256sums
	cp $(IB_BIN)/openwrt-$(VERSION)-ramips-mt76x8-$(PROFILE)* $(3)/
	@echo "== variant $(1) -> $(3) =="
	ls -lh $(3)
endef

image-min: imagebuilder ## build image without LuCI (WireGuard only)
	@$(call build_variant,min,$(PKG_min),$(CURDIR)/images/min)

image-luci: imagebuilder ## build image with LuCI web UI + WireGuard
	@$(call build_variant,luci,$(PKG_luci),$(CURDIR)/images/luci)

tftp-prepare: ## stage chosen VARIANT image as tp_recovery.bin (VARIANT=min|luci)
	@test -f $(CURDIR)/images/$(VARIANT)/*tftp-recovery.bin || \
		{ echo "no tftp-recovery image in images/$(VARIANT) - run: make image-$(VARIANT)"; exit 1; }
	mkdir -p $(TFTP_ROOT)
	cp $(CURDIR)/images/$(VARIANT)/*tftp-recovery.bin $(TFTP_ROOT)/tp_recovery.bin
	chmod 755 $(TFTP_ROOT) 2>/dev/null || true
	chmod 644 $(TFTP_ROOT)/tp_recovery.bin
	@echo "staged images/$(VARIANT) -> $(TFTP_ROOT)/tp_recovery.bin"

tftp-serve: ## start TFTP server as root (dnsmasq, UDP 69, TFTP_IP only)
	@echo "sudo required: TFTP needs port 69"
	sudo env TFTP_ROOT=$(TFTP_ROOT) TFTP_IP=$(TFTP_IP) bash $(CURDIR)/tftp/tftp-start.sh

tftp-stop: ## stop the TFTP server
	@test -f $(TFTP_ROOT)/dnsmasq.pid || { echo "no pidfile, nothing to stop"; exit 0; }
	sudo kill "$$(cat $(TFTP_ROOT)/dnsmasq.pid)" && rm -f $(TFTP_ROOT)/dnsmasq.pid
	@echo "tftp stopped"

flash-watch: ## tail TFTP log live (transfer from the router shows up here)
	tail -n 20 -F $(TFTP_ROOT)/dnsmasq.log | grep --line-buffered -iE 'RRQ|sent|error|ignored'

pc-ip: ## set DEV static multi-subnet (0.66 recovery / 2.66 target LAN)
	nmcli connection modify "$(CONN)" ipv4.method manual \
		ipv4.addresses $(PC_IPS) ipv4.gateway "" ipv4.dns ""
	nmcli device reapply $(DEV)
	ip -4 addr show $(DEV) | grep inet

pc-ip-firstboot: ## TEMPORARY: also add 192.168.1.2 to reach factory-LAN device. Blackholes home LAN on wifi. Revert with: make pc-ip
	nmcli connection modify "$(CONN)" ipv4.method manual \
		ipv4.addresses $(PC_IPS_FIRST) ipv4.gateway "" ipv4.dns ""
	nmcli device reapply $(DEV)
	ip -4 addr show $(DEV) | grep inet
	@echo "WARNING: 192.168.1.2 on eth0 shadows the home-LAN subnet (dual connected routes). Revert ASAP: make pc-ip"

pc-ip-restore: ## revert DEV profile to DHCP (undo pc-ip)
	nmcli connection modify "$(CONN)" ipv4.method auto \
		ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
	nmcli device reapply $(DEV)
	@echo "profile reverted to DHCP"

clean: ## remove extracted ImageBuilder (images/ kept)
	rm -rf $(IB_DIR) $(CURDIR)/tmp-build
	@echo "imagebuilder removed - images/ untouched"

keygen: ## generate a WireGuard keypair with wg on the DEVICE, store in secrets/ (gitignored)
	@mkdir -p $(SECRETS) && chmod 700 $(SECRETS)
	@if test -s $(SECRETS)/wg_router.key; then \
		echo "keypair already exists: $(SECRETS)/wg_router.key (delete both files to rotate)"; exit 1; fi
	@ssh $(SSH_OPTS) $(WG_HOST) 'p=$$(wg genkey); q=$$(echo "$$p" | wg pubkey); printf "%s\n%s\n" "$$p" "$$q"' > /tmp/opencode/wg_pair.txt
	@umask 077 && head -1 /tmp/opencode/wg_pair.txt > $(SECRETS)/wg_router.key && tail -1 /tmp/opencode/wg_pair.txt > $(SECRETS)/wg_router.pub && chmod 600 $(SECRETS)/wg_router.key $(SECRETS)/wg_router.pub && rm -f /tmp/opencode/wg_pair.txt && echo "keypair: $(SECRETS)/wg_router.key + wg_router.pub"

provision: ## push secrets/wg_router.key into the device wg0 config (SSH)
	@test -s $(SECRETS)/wg_router.key || { echo "no keypair - run: make keygen"; exit 1; }
	@mkdir -p /tmp/opencode
	@printf '#!/bin/sh\nuci set network.wg0.private_key="%s"\nuci commit network\ntest -n "$$(uci -q get network.wg0.private_key)" && echo "private key: set"\n' "$$(cat $(SECRETS)/wg_router.key)" > /tmp/opencode/wg-provision.sh
	@scp -O -q $(SSH_OPTS) /tmp/opencode/wg-provision.sh $(WG_HOST):/tmp/wg-provision.sh
	@ssh $(SSH_OPTS) $(WG_HOST) 'sh /tmp/wg-provision.sh; rm -f /tmp/wg-provision.sh' 2>/dev/null
	@rm -f /tmp/opencode/wg-provision.sh
	@echo "router pubkey (to configure later in the server peer):"
	@cat $(SECRETS)/wg_router.pub
	@echo "note: peer stays incomplete (no server pubkey/endpoint yet) until the Pi exists"

provision-ssh: ## install local SSH public key into the device dropbear authorized_keys
	@test -s $(SECRETS_SSH) || { echo "no pubkey at $(SECRETS_SSH)"; exit 1; }
	@scp -O -q $(SSH_OPTS) $(SECRETS_SSH) $(WG_HOST):/tmp/ak.pub
	@ssh $(SSH_OPTS) $(WG_HOST) 'mkdir -p /etc/dropbear && touch /etc/dropbear/authorized_keys && grep -qF "$$(cat /tmp/ak.pub)" /etc/dropbear/authorized_keys || cat /tmp/ak.pub >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; rm -f /tmp/ak.pub; echo "authorized_keys updated"'
