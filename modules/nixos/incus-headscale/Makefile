# Makefile for Incus Headscale Deployment
#-----------------------------
# Simple deployment system for Headscale server and gateway
#-----------------------------

SHELL := /bin/bash -exo pipefail

NAME ?= headscale-server

# Cluster/Network Configuration
CLUSTER_NAME ?= $(LIMA_HOSTNAME)
HEADSCALE_BASE_DOMAIN ?= home.local

# Network Configuration (using internal-br for home network access)
NETWORK_NAME := internal-br
HEADSCALE_SERVER_IP ?= 10.148.164.100
HEADSCALE_SERVER_URL ?= http://$(HEADSCALE_SERVER_IP):8080

# Headscale ports to expose
HEADSCALE_HTTP_PORT := 8080
HEADSCALE_HTTPS_PORT := 443
HEADSCALE_METRICS_PORT := 9090
HEADSCALE_STUN_PORT := 3478

# Gateway Configuration  
GATEWAY_HOSTNAME ?= $(CLUSTER_NAME)-hs-gateway
GATEWAY_ROUTES ?= 100.64.0.0/10,192.168.5.0/24

# Export for envsubst
export HEADSCALE_SERVER_URL
export HEADSCALE_BASE_DOMAIN
export GATEWAY_HOSTNAME
export GATEWAY_ROUTES

# Directories
RUN_DIR := .run.d
INCUS_DIR := $(RUN_DIR)/incus
INSTANCE_DIR := $(INCUS_DIR)/$(NAME)
SHARED_DIR := $(INSTANCE_DIR)/shared
LOGS_DIR := $(INSTANCE_DIR)/logs

# Cloud-init configuration
CLOUD_CONFIG_COMMON := cloud-config.common.yaml.tmpl
CLOUD_CONFIG_SPECIFIC := cloud-config.$(NAME).yaml.tmpl
CLOUD_CONFIG_MERGED := $(INSTANCE_DIR)/cloud-init-merged.yaml
CLOUD_CONFIG_META := $(INSTANCE_DIR)/cloud-init-meta-data

# Instance configuration
INSTANCE_CONFIG_TEMPLATE := incus-instance-config.yaml.tmpl
INSTANCE_CONFIG_FILE := $(INSTANCE_DIR)/incus-instance-config.yaml

# Incus project
INCUS_PROJECT := headscale

# Marker files
INCUS_SETUP_MARKER := $(INCUS_DIR)/.setup-done
NETWORK_SETUP_MARKER := $(INCUS_DIR)/.network-setup-done

.PHONY: all setup start stop delete shell status logs clean preauth-key clean-network

all: start

# Setup Incus environment (run once)
setup: $(INCUS_SETUP_MARKER) $(NETWORK_SETUP_MARKER)

$(INCUS_DIR):
	mkdir -p $(INCUS_DIR)

$(INSTANCE_DIR):
	mkdir -p $(INSTANCE_DIR)

# Setup network
$(NETWORK_SETUP_MARKER): $(INCUS_SETUP_MARKER) | $(INCUS_DIR)
	@echo "[+] Setting up network environment..."
	@# Ensure internal-br has IPv4 and IPv6 DHCP enabled (global network)
	@echo "[+] Configuring $(NETWORK_NAME) network..."
	@incus network set $(NETWORK_NAME) ipv4.dhcp=true || true
	@incus network set $(NETWORK_NAME) ipv4.dhcp.ranges=10.148.164.100-10.148.164.200 || true
	@incus network set $(NETWORK_NAME) ipv6.dhcp=true || true
	@incus network set $(NETWORK_NAME) ipv6.dhcp.stateful=true || true
	@echo "[+] Network $(NETWORK_NAME) configured with IPv4 + IPv6 DHCP"
	@# Configure default profile with network
	@if incus profile show default --project $(INCUS_PROJECT) --format=yaml | yq -e '.devices.eth0' >/dev/null 2>&1; then \
		echo "[+] Updating eth0 device in default profile to use $(NETWORK_NAME)..."; \
		incus profile device set default eth0 parent=$(NETWORK_NAME) --project $(INCUS_PROJECT) || true; \
	else \
		echo "[+] Adding eth0 device to default profile with network $(NETWORK_NAME)..."; \
		incus profile device add default eth0 nic network=$(NETWORK_NAME) name=eth0 --project $(INCUS_PROJECT); \
	fi
	@touch $@

$(SHARED_DIR) $(LOGS_DIR): | $(INSTANCE_DIR)
	mkdir -p $@

$(INCUS_SETUP_MARKER): | $(INCUS_DIR)
	@echo "[+] Setting up Incus environment..."
	@# Add images remote if not exists (global, not project-specific)
	@incus remote list --format=yaml | yq -e '.images' >/dev/null 2>&1 || \
		incus remote add images https://images.linuxcontainers.org --protocol=simplestreams --public
	@# Create headscale project if it doesn't exist (networks=false to use global internal-br)
	@incus project list --format=yaml | yq -e '.[] | select(.name == "$(INCUS_PROJECT)")' >/dev/null 2>&1 || \
		incus project create $(INCUS_PROJECT) \
			-c features.images=true \
			-c features.profiles=true \
			-c features.storage.volumes=true \
			-c features.networks=false
	@incus project switch $(INCUS_PROJECT)
	@echo "[+] Incus setup complete (project: $(INCUS_PROJECT))"
	@touch $@

# Merge cloud-init configs (common + specific)
$(CLOUD_CONFIG_MERGED): $(CLOUD_CONFIG_COMMON) $(CLOUD_CONFIG_SPECIFIC) | $(INSTANCE_DIR)
	@echo "[+] Merging cloud-init configurations..."
	@yq eval-all '. as $$item ireduce ({}; . *+ $$item)' $(CLOUD_CONFIG_COMMON) $(CLOUD_CONFIG_SPECIFIC) > $@

# Create meta-data for cloud-init
$(CLOUD_CONFIG_META): | $(INSTANCE_DIR)
	@echo "[+] Creating cloud-init meta-data..."
	@echo "instance-id: $(NAME)" > $@
	@echo "local-hostname: $(NAME)" >> $@

# Generate instance config from template (using yq for YAML-safe envsubst like RKE2)
$(INSTANCE_CONFIG_FILE): $(INSTANCE_CONFIG_TEMPLATE) $(CLOUD_CONFIG_MERGED) $(CLOUD_CONFIG_META) | $(SHARED_DIR) $(LOGS_DIR)
	@echo "[+] Generating instance configuration..."
	@PWD=$(CURDIR) NAME=$(NAME) INSTANCE_DIR=$(INSTANCE_DIR) \
		CLOUD_CONFIG_MERGED=$(CLOUD_CONFIG_MERGED) CLOUD_CONFIG_META=$(CLOUD_CONFIG_META) \
		yq eval '( ... | select(tag=="!!str") ) |= envsubst' $(INSTANCE_CONFIG_TEMPLATE) > $@

# Initialize instance (RKE2 pattern: init + config + start)
$(INSTANCE_DIR)/.instance-init: setup $(INSTANCE_CONFIG_FILE) | $(INSTANCE_DIR)
	@echo "[+] Initializing $(NAME) instance..."
	@if incus list --project $(INCUS_PROJECT) --format=yaml | yq -e '.[] | select(.name == "$(NAME)")' >/dev/null 2>&1; then \
		echo "Instance $(NAME) already exists"; \
	else \
		echo "[+] Launching instance with network $(NETWORK_NAME) and IP $(HEADSCALE_SERVER_IP)"; \
		incus init --project $(INCUS_PROJECT) images:ubuntu/22.04/cloud $(NAME) < $(INSTANCE_CONFIG_FILE); \
		if [ "$(NAME)" = "headscale-server" ]; then \
			incus config device set --project $(INCUS_PROJECT) $(NAME) eth0 ipv4.address=$(HEADSCALE_SERVER_IP); \
		fi; \
	fi
	@touch $@

# Configure environment variables (before start)
$(INSTANCE_DIR)/.instance-configured: $(INSTANCE_DIR)/.instance-init
	@echo "[+] Configuring environment variables..."
	@if [ "$(NAME)" = "headscale-server" ]; then \
		incus config set --project $(INCUS_PROJECT) $(NAME) environment.HEADSCALE_SERVER_URL "$(HEADSCALE_SERVER_URL)"; \
		incus config set --project $(INCUS_PROJECT) $(NAME) environment.HEADSCALE_BASE_DOMAIN "$(HEADSCALE_BASE_DOMAIN)"; \
	elif [ "$(NAME)" = "headscale-gateway" ]; then \
		incus config set --project $(INCUS_PROJECT) $(NAME) environment.GATEWAY_HOSTNAME "$(GATEWAY_HOSTNAME)"; \
		incus config set --project $(INCUS_PROJECT) $(NAME) environment.GATEWAY_ROUTES "$(GATEWAY_ROUTES)"; \
	fi
	@touch $@

# Start instance - depends on init and config
start: $(INSTANCE_DIR)/.instance-configured
	@echo "[+] Starting $(NAME) instance..."
	@incus start --project $(INCUS_PROJECT) $(NAME) || true
	@echo "[+] Waiting for cloud-init to complete..."
	@incus exec --project $(INCUS_PROJECT) $(NAME) -- cloud-init status --wait || true
	@echo "[+] Instance $(NAME) started successfully"

# Stop instance
stop:
	@echo "[+] Stopping $(NAME)..."
	incus stop --project $(INCUS_PROJECT) $(NAME)

# Delete instance
delete:
	@echo "[+] Deleting $(NAME)..."
	incus delete --project $(INCUS_PROJECT) -f $(NAME)
	rm -f $(INSTANCE_DIR)/.instance-*
	rm -rf $(INSTANCE_DIR)

# Shell into instance
shell:
	@echo "[+] Opening shell in $(NAME)..."
	incus exec --project $(INCUS_PROJECT) $(NAME) -- bash

# Show status
status:
	@echo "[+] Status of $(NAME):"
	@incus list --project $(INCUS_PROJECT) $(NAME)
	@echo ""
	@if incus list --project $(INCUS_PROJECT) --format=yaml | yq -e '.[] | select(.name == "$(NAME)")' >/dev/null 2>&1; then \
		echo "[+] Cloud-init status:"; \
		incus exec --project $(INCUS_PROJECT) $(NAME) -- cloud-init status || true; \
		echo ""; \
		if [ "$(NAME)" = "headscale-server" ]; then \
			echo "[+] Headscale service status:"; \
			incus exec --project $(INCUS_PROJECT) $(NAME) -- systemctl status headscale --no-pager || true; \
		elif [ "$(NAME)" = "headscale-gateway" ]; then \
			echo "[+] Tailscale status:"; \
			incus exec --project $(INCUS_PROJECT) $(NAME) -- tailscale status || true; \
		fi \
	fi

# Show logs
logs:
	@echo "[+] Logs for $(NAME):"
	@if [ "$(NAME)" = "headscale-server" ]; then \
		incus exec --project $(INCUS_PROJECT) $(NAME) -- journalctl -u headscale -n 50 --no-pager; \
	elif [ "$(NAME)" = "headscale-gateway" ]; then \
		incus exec --project $(INCUS_PROJECT) $(NAME) -- journalctl -u tailscaled -n 50 --no-pager; \
	else \
		incus exec --project $(INCUS_PROJECT) $(NAME) -- journalctl -n 50 --no-pager; \
	fi

# Get preauth key (headscale-server only)
preauth-key:
	@echo "[+] Retrieving preauth key from shared directory..."
	@cat $(RUN_DIR)/incus/headscale-server/shared/admin-preauth-key.txt

# Clean instance
clean:
	@echo "[+] Cleaning up instance..."
	@-incus delete --project $(INCUS_PROJECT) $(NAME) --force 2>/dev/null || true
	@-rm -rf $(INSTANCE_DIR)
	@-rm -f $(INCUS_SETUP_MARKER)
	@echo "[+] Cleanup complete"

# Clean network (just reset marker, don't delete global internal-br)
clean-network:
	@echo "[+] Resetting network setup marker..."
	@-rm -f $(NETWORK_SETUP_MARKER)
	@echo "[+] Network cleanup complete ($(NETWORK_NAME) is global, not deleted)"

# Clean all
clean-all: clean clean-network
	@echo "[+] Cleaning up everything..."
	@-rm -rf $(RUN_DIR)
	@echo "[+] Complete cleanup done. Run 'make setup' before next deployment"

# Help
help:
	@echo "Incus Headscale Deployment"
	@echo ""
	@echo "Usage:"
	@echo "  make NAME=headscale-server start   # Deploy Headscale server"
	@echo "  make NAME=headscale-gateway start  # Deploy Headscale gateway"
	@echo "  make NAME=<instance> stop          # Stop instance"
	@echo "  make NAME=<instance> delete        # Delete instance"
	@echo "  make NAME=<instance> shell         # Shell into instance"
	@echo "  make NAME=<instance> status        # Show status"
	@echo "  make NAME=<instance> logs          # Show logs"
	@echo "  make preauth-key                   # Get headscale preauth key"
	@echo ""
	@echo "Environment Variables:"
	@echo "  HEADSCALE_SERVER_URL    = $(HEADSCALE_SERVER_URL)"
	@echo "  HEADSCALE_BASE_DOMAIN   = $(HEADSCALE_BASE_DOMAIN)"
	@echo "  GATEWAY_HOSTNAME        = $(GATEWAY_HOSTNAME)"
	@echo "  GATEWAY_ROUTES          = $(GATEWAY_ROUTES)"
