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

# Site/runtime defaults (overridable at build time)
LAN_IP        ?= 192.168.10.254/24
HOSTNAME      ?= ac750
TZ            ?= Europe/Paris
NTP_SERVERS   ?= 0.openwrt.pool.ntp.org 1.openwrt.pool.ntp.org 2.openwrt.pool.ntp.org 3.openwrt.pool.ntp.org
SSH_KEEPALIVE ?= 60

# DNS over HTTPS (optional). DOH=off|quad9|quad9-unfiltered|cloudflare|adguard|dns4eu|google|custom
DOH              ?= off
DOH_CUSTOM_URL   ?=
DOH_BOOTSTRAP    ?=
# DNS leak redirect via https-dns-proxy force_dns (captive-portal risk). 0=recommended default.
DNS_REDIRECT      ?= 0
DNS_REDIRECT_PORTS ?= 53 853

GEN       := $(CURDIR)/config-gen

PKG_DOH :=
ifneq ($(DOH),off)
PKG_DOH := https-dns-proxy
endif

PKG_min  := wireguard-tools luci-proto-wireguard kmod-wireguard $(PKG_DOH) -ppp -ppp-mod-pppoe
PKG_luci := wireguard-tools luci-proto-wireguard kmod-wireguard luci $(PKG_DOH) $(if $(filter-out off,$(DOH)),luci-app-https-dns-proxy,) -ppp -ppp-mod-pppoe

# declarative config overlay: static files in config/files, site values in
# config-gen (generated per build from LAN_IP/HOSTNAME/TZ)

TFTP_ROOT ?= /tmp/wr902ac-tftp
TFTP_IP   ?= 192.168.0.66
DEV       ?= eth0
# NetworkManager profile on DEV - override for your system (quote if name has spaces)
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
	@echo "  site:  LAN_IP=$(LAN_IP) HOSTNAME=$(HOSTNAME) TZ=$(TZ)"
	@echo "  ntp:   NTP_SERVERS=$(NTP_SERVERS)"
	@echo "  doh:   DOH=$(DOH) DNS_REDIRECT=$(DNS_REDIRECT) DNS_REDIRECT_PORTS=$(DNS_REDIRECT_PORTS)"
	@echo "         DOH_CUSTOM_URL=$(DOH_CUSTOM_URL) DOH_BOOTSTRAP=$(DOH_BOOTSTRAP)"
	@echo "  flash: TFTP_ROOT=$(TFTP_ROOT) TFTP_IP=$(TFTP_IP) DEV=$(DEV) CONN=\"$(CONN)\""
	@echo
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "  WARNING: pc-ip / tftp-serve / tftp-stop mutate host state (NetworkManager, root, ufw)."
	@echo "  Security: DNS_REDIRECT=1 can break captive portals; dropbear hardening is conservative by default."

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
	@case "$(DOH)" in off|quad9|quad9-unfiltered|cloudflare|adguard|dns4eu|google|custom) ;; *) echo "invalid DOH=$(DOH) (use off|quad9|quad9-unfiltered|cloudflare|adguard|dns4eu|google|custom)"; exit 1;; esac
	@if [ "$(DOH)" = custom ] && [ -z "$(DOH_CUSTOM_URL)" ]; then echo "DOH=custom requires DOH_CUSTOM_URL"; exit 1; fi
	rm -rf $(GEN) && mkdir -p $(3) $(GEN)
	cp -a $(CURDIR)/config/files/. $(GEN)/
	{ \
	  echo '#!/bin/sh'; \
	  echo 'uci set network.lan.ipaddr="$(LAN_IP)"'; \
	  echo 'uci -q delete network.lan.netmask'; \
	  echo 'uci set system.@system[0].hostname="$(HOSTNAME)"'; \
	  echo 'uci set system.@system[0].timezone="$(TZ)"'; \
	  echo 'uci set system.@system[0].zonename="$(TZ)"'; \
	  echo 'uci -q delete system.ntp.server'; \
	  echo "uci set system.ntp.enabled='1'"; \
	  echo "uci set system.ntp.enable_server='0'"; \
	  for s in $(NTP_SERVERS); do echo "uci add_list system.ntp.server='$$s'"; done; \
	  echo 'uci set dropbear.@dropbear[0].SSHKeepAlive="$(SSH_KEEPALIVE)"'; \
	  echo "uci -q delete dropbear.@dropbear[0].KeepAlive"; \
	  echo "uci set dropbear.@dropbear[0].GatewayPorts='0'"; \
	  echo "uci set dropbear.@dropbear[0].MaxAuthTries='3'"; \
	  echo 'uci commit system'; echo 'uci commit network'; echo 'uci commit dropbear'; \
	} > $(GEN)/etc/uci-defaults/99-site-config
	chmod 755 $(GEN)/etc/uci-defaults/99-site-config
	@if [ "$(DOH)" != off ]; then \
	  case "$(DOH)" in \
	    quad9) url='https://dns.quad9.net/dns-query'; boot='9.9.9.9,149.112.112.112';; \
	    quad9-unfiltered) url='https://dns10.quad9.net/dns-query'; boot='9.9.9.10,149.112.112.10';; \
	    cloudflare) url='https://cloudflare-dns.com/dns-query'; boot='1.1.1.1,1.0.0.1';; \
	    adguard) url='https://dns.adguard-dns.com/dns-query'; boot='94.140.14.14,94.140.15.15';; \
	    dns4eu) url='https://protective.joindns4.eu/dns-query'; boot='86.54.11.1,86.54.11.201';; \
	    google) url='https://dns.google/dns-query'; boot='8.8.8.8,8.8.4.4';; \
	    custom) url='$(DOH_CUSTOM_URL)'; boot='$(DOH_BOOTSTRAP)';; \
	  esac; \
	  if [ "$(DOH)" = custom ] && [ -z "$$boot" ]; then boot='1.1.1.1,9.9.9.9'; fi; \
	  { \
	    echo '#!/bin/sh'; \
	    echo '# Generated DoH config (secure travel router build option).'; \
	    echo '# Replaces package default instances; verify provider endpoints for your region/policy.'; \
	    echo 'while uci -q delete https-dns-proxy.@https-dns-proxy[0]; do :; done'; \
	    echo "uci set https-dns-proxy.config=main"; \
	    echo "uci set https-dns-proxy.config.dnsmasq_config_update='*'"; \
	    echo "uci set https-dns-proxy.config.force_dns='$(DNS_REDIRECT)'"; \
	    echo "uci set https-dns-proxy.config.notrack_dns='1'"; \
	    echo "uci -q delete https-dns-proxy.config.force_dns_port"; \
	    for p in $(DNS_REDIRECT_PORTS); do echo "uci add_list https-dns-proxy.config.force_dns_port='$$p'"; done; \
	    echo "uci -q delete https-dns-proxy.config.force_dns_src_interface"; \
	    echo "uci add_list https-dns-proxy.config.force_dns_src_interface='lan'"; \
	    echo "uci set https-dns-proxy.config.canary_domains_icloud='1'"; \
	    echo "uci set https-dns-proxy.config.canary_domains_mozilla='1'"; \
	    echo "uci set https-dns-proxy.config.procd_trigger_wan6='0'"; \
	    echo "uci set https-dns-proxy.config.heartbeat_domain='heartbeat.mossdef.org'"; \
	    echo "uci set https-dns-proxy.config.heartbeat_sleep_timeout='10'"; \
	    echo "uci set https-dns-proxy.config.heartbeat_wait_timeout='10'"; \
	    echo "uci set https-dns-proxy.config.user='nobody'"; \
	    echo "uci set https-dns-proxy.config.group='nogroup'"; \
	    echo "uci set https-dns-proxy.config.listen_addr='127.0.0.1'"; \
	    echo "uci set https-dns-proxy.config.force_ip_family='auto'"; \
	    echo "uci set https-dns-proxy.dns1=https-dns-proxy"; \
	    echo "uci set https-dns-proxy.dns1.bootstrap_dns='$$boot'"; \
	    echo "uci set https-dns-proxy.dns1.resolver_url='$$url'"; \
	    echo "uci set https-dns-proxy.dns1.listen_port='5053'"; \
	    echo 'uci commit https-dns-proxy'; \
	  } > $(GEN)/etc/uci-defaults/99-doh-config; \
	  chmod 755 $(GEN)/etc/uci-defaults/99-doh-config; \
	fi
	$(MAKE) -C $(IB_DIR) image PROFILE=$(PROFILE) PACKAGES="$(2)" FILES="$(GEN)"
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
	@sudo sh -c 'if [ -f "$(TFTP_ROOT)/dnsmasq.pid" ]; then kill "$$(cat "$(TFTP_ROOT)/dnsmasq.pid")" && rm -f "$(TFTP_ROOT)/dnsmasq.pid"; echo "tftp stopped"; else echo "no pidfile at $(TFTP_ROOT)"; fi'

flash-watch: ## tail TFTP log live (transfer from the router shows up here)
	tail -n 20 -F $(TFTP_ROOT)/dnsmasq.log | grep --line-buffered -iE 'RRQ|sent|error|ignored'

pc-ip: ## set DEV static multi-subnet (0.66 recovery / 10.66 target LAN)
	nmcli connection modify "$(CONN)" ipv4.method manual \
		ipv4.addresses $(PC_IPS) ipv4.gateway "" ipv4.dns ""
	nmcli device reapply $(DEV)
	ip -4 addr show $(DEV) | grep inet

pc-ip-firstboot: ## TEMPORARY: also add 192.168.1.2 to reach factory-LAN device. May disrupt any other interface on that subnet. Revert with: make pc-ip
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

clean: ## remove extracted ImageBuilder and generated overlay (images/ kept)
	rm -rf $(IB_DIR) $(CURDIR)/tmp-build $(GEN)
	@echo "imagebuilder removed - images/ untouched"

keygen: ## generate a WireGuard keypair with wg on the DEVICE, store in secrets/ (gitignored)
	@mkdir -p $(SECRETS) && chmod 700 $(SECRETS)
	@if test -s $(SECRETS)/wg_router.key; then \
		echo "keypair already exists: $(SECRETS)/wg_router.key (delete both files to rotate)"; exit 1; fi
	@ssh $(SSH_OPTS) $(WG_HOST) 'p=$$(wg genkey); q=$$(echo "$$p" | wg pubkey); printf "%s\n%s\n" "$$p" "$$q"' > $(SECRETS)/.wg_pair
	@umask 077 && head -1 $(SECRETS)/.wg_pair > $(SECRETS)/wg_router.key && tail -1 $(SECRETS)/.wg_pair > $(SECRETS)/wg_router.pub && chmod 600 $(SECRETS)/wg_router.key $(SECRETS)/wg_router.pub && rm -f $(SECRETS)/.wg_pair && echo "keypair: $(SECRETS)/wg_router.key + wg_router.pub"

provision: ## push secrets/wg_router.key into the device wg0 config (SSH)
	@test -s $(SECRETS)/wg_router.key || { echo "no keypair - run: make keygen"; exit 1; }
	@mkdir -p $(SECRETS) && chmod 700 $(SECRETS)
	@printf '#!/bin/sh\nuci set network.wg0.private_key="%s"\nuci commit network\ntest -n "$$(uci -q get network.wg0.private_key)" && echo "private key: set"\n' "$$(cat $(SECRETS)/wg_router.key)" > $(SECRETS)/.wg-provision.sh
	@scp -O -q $(SSH_OPTS) $(SECRETS)/.wg-provision.sh $(WG_HOST):/tmp/wg-provision.sh
	@ssh $(SSH_OPTS) $(WG_HOST) 'sh /tmp/wg-provision.sh; rm -f /tmp/wg-provision.sh' 2>/dev/null
	@rm -f $(SECRETS)/.wg-provision.sh
	@echo "router pubkey (to configure later in the server peer):"
	@cat $(SECRETS)/wg_router.pub
	@echo "note: peer stays incomplete (no server pubkey/endpoint yet) until the Pi exists"

provision-ssh: ## install local SSH public key into the device dropbear authorized_keys
	@test -s $(SECRETS_SSH) || { echo "no pubkey at $(SECRETS_SSH)"; exit 1; }
	@scp -O -q $(SSH_OPTS) $(SECRETS_SSH) $(WG_HOST):/tmp/ak.pub
	@ssh $(SSH_OPTS) $(WG_HOST) 'mkdir -p /etc/dropbear && touch /etc/dropbear/authorized_keys && grep -qF "$$(cat /tmp/ak.pub)" /etc/dropbear/authorized_keys || cat /tmp/ak.pub >> /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; rm -f /tmp/ak.pub; echo "authorized_keys updated"'
