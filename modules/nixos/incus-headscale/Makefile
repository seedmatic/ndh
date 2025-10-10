# Makefile for Incus Headscale Deployment
#-----------------------------
# Simple deployment system for Headscale server and gateway
#-----------------------------

SHELL := /bin/bash -exo pipefail

NAME ?= headscale-server

# Cluster/Network Configuration
CLUSTER_NAME ?= $(LIMA_HOSTNAME)
HEADSCALE_BASE_DOMAIN ?= home.local

# Network Configuration (bridge to home LAN)
NETWORK_NAME := headscale-lan-br
PARENT_INTERFACE ?= enp0s1
HEADSCALE_SERVER_IP ?= dhcp
HEADSCALE_SERVER_URL ?= http://headscale-server.local:8080

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

#-----------------------------
# Makefile Macros
#-----------------------------

# Create bridged network if it doesn't exist
define create_bridged_network
	if ! incus network show $(1) --project $(2) >/dev/null 2>&1; then
		echo "[+] Creating bridged network $(1) using parent $(3)..."
		incus network create $(1) \
			--project $(2) \
			--type=bridge \
			parent=$(3) \
			ipv4.address=none \
			ipv6.address=none
		echo "[+] Network $(1) created (bridge to home LAN)"
	else
		echo "[*] Network $(1) already exists"
	fi
endef

# Configure profile device for network
define configure_profile_device
	if incus profile show $(1) --project $(2) --format=yaml | yq -e '.devices.eth0' >/dev/null 2>&1; then
		echo "[+] Updating eth0 device in $(1) profile to use $(3)..."
		incus profile device set $(1) eth0 parent=$(3) --project $(2) || true
	else
		echo "[+] Adding eth0 device to $(1) profile with network $(3)..."
		incus profile device add $(1) eth0 nic network=$(3) name=eth0 --project $(2)
	fi
endef

# Add images remote if it doesn't exist
define ensure_images_remote
	incus remote list --format=yaml | yq -e '.images' >/dev/null 2>&1 || \
		incus remote add images https://images.linuxcontainers.org --protocol=simplestreams --public
endef

# Create incus project with features if it doesn't exist
define create_incus_project
	if ! incus project list --format=yaml | yq -e '.[] | select(.name == "$(1)")' >/dev/null 2>&1; then
		echo "[+] Creating project $(1)..."
		incus project create $(1) \
			-c features.images=true \
			-c features.profiles=true \
			-c features.storage.volumes=true \
			-c features.networks=$(2)
	fi
	incus project switch $(1)
endef

# Check if instance exists
define instance_exists
	incus list --project $(1) --format=yaml | yq -e '.[] | select(.name == "$(2)")' >/dev/null 2>&1
endef

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
	@$(call create_bridged_network,$(NETWORK_NAME),$(INCUS_PROJECT),$(PARENT_INTERFACE))
	@$(call configure_profile_device,default,$(INCUS_PROJECT),$(NETWORK_NAME))
	@touch $@

$(SHARED_DIR) $(LOGS_DIR): | $(INSTANCE_DIR)
	mkdir -p $@

$(INCUS_SETUP_MARKER): | $(INCUS_DIR)
	@echo "[+] Setting up Incus environment..."
	@$(call ensure_images_remote)
	@$(call create_incus_project,$(INCUS_PROJECT),true)
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
	@if $(call instance_exists,$(INCUS_PROJECT),$(NAME)); then \
		echo "Instance $(NAME) already exists"; \
	else \
		echo "[+] Launching instance with network $(NETWORK_NAME)..."; \
		incus init --project $(INCUS_PROJECT) images:ubuntu/22.04/cloud $(NAME) < $(INSTANCE_CONFIG_FILE); \
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
	@if $(call instance_exists,$(INCUS_PROJECT),$(NAME)); then \
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

# Clean network
clean-network:
	@echo "[+] Cleaning up network..."
	@if incus network show $(NETWORK_NAME) --project $(INCUS_PROJECT) >/dev/null 2>&1; then \
		echo "[+] Deleting network $(NETWORK_NAME)..."; \
		incus network delete $(NETWORK_NAME) --project $(INCUS_PROJECT) || true; \
	fi
	@-rm -f $(NETWORK_SETUP_MARKER)
	@echo "[+] Network cleanup complete"

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
