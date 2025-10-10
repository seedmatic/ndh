# Makefile for Incus Headscale Deployment
#-----------------------------
# Simple deployment system for Headscale server and gateway
#-----------------------------

SHELL := /bin/bash -exo pipefail

NAME ?= headscale-server

# Cluster/Network Configuration
CLUSTER_NAME ?= $(LIMA_HOSTNAME)
HEADSCALE_SERVER_URL ?= http://192.168.5.10:8080
HEADSCALE_BASE_DOMAIN ?= home.local

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

# Cloud-init configuration
CLOUD_CONFIG_COMMON := cloud-config.common.yaml.tmpl
CLOUD_CONFIG_SPECIFIC := cloud-config.$(NAME).yaml.tmpl
CLOUD_CONFIG_MERGED := $(INSTANCE_DIR)/cloud-init-merged.yaml

# Marker files
INCUS_SETUP_MARKER := $(INCUS_DIR)/.setup-done

.PHONY: all setup start stop delete shell status logs clean

all: start

# Setup Incus environment (run once)
setup: $(INCUS_SETUP_MARKER)

$(INCUS_DIR):
	mkdir -p $(INCUS_DIR)

$(INSTANCE_DIR):
	mkdir -p $(INSTANCE_DIR)

$(INCUS_SETUP_MARKER): | $(INCUS_DIR)
	@echo "[+] Setting up Incus environment..."
	@incus remote list | grep -q "images" || incus remote add images https://images.linuxcontainers.org --protocol=simplestreams --public || true
	@echo "[+] Incus setup complete"
	@touch $@

# Merge cloud-init configs (common + specific)
$(CLOUD_CONFIG_MERGED): $(CLOUD_CONFIG_COMMON) $(CLOUD_CONFIG_SPECIFIC) | $(INSTANCE_DIR)
	@echo "[+] Merging cloud-init configurations..."
	@yq eval-all '. as $$item ireduce ({}; . *+ $$item)' $(CLOUD_CONFIG_COMMON) $(CLOUD_CONFIG_SPECIFIC) > $@

# Start instance - depends on setup and merged config
start: setup $(CLOUD_CONFIG_MERGED)
	@echo "[+] Launching $(NAME) instance..."
	@if incus list -c n -f csv | grep -q "^$(NAME)$$"; then \
		echo "Instance $(NAME) already exists"; \
	else \
		incus launch images:ubuntu/22.04/cloud $(NAME) \
			--storage default \
			--network internal-br \
			--config=cloud-init.user-data="$$(cat $(CLOUD_CONFIG_MERGED))"; \
		echo "[+] Configuring environment variables..."; \
		if [ "$(NAME)" = "headscale-server" ]; then \
			incus config set $(NAME) environment.HEADSCALE_SERVER_URL "$(HEADSCALE_SERVER_URL)"; \
			incus config set $(NAME) environment.HEADSCALE_BASE_DOMAIN "$(HEADSCALE_BASE_DOMAIN)"; \
		elif [ "$(NAME)" = "headscale-gateway" ]; then \
			incus config set $(NAME) environment.GATEWAY_HOSTNAME "$(GATEWAY_HOSTNAME)"; \
			incus config set $(NAME) environment.GATEWAY_ROUTES "$(GATEWAY_ROUTES)"; \
		fi; \
		incus restart $(NAME); \
		echo "[+] Waiting for cloud-init to complete..."; \
		incus exec $(NAME) -- cloud-init status --wait || true; \
		echo "[+] Instance $(NAME) started successfully"; \
	fi

# Stop instance
stop:
	@echo "[+] Stopping $(NAME)..."
	incus stop $(NAME)

# Delete instance
delete:
	@echo "[+] Deleting $(NAME)..."
	incus delete -f $(NAME)
	rm -rf $(INSTANCE_DIR)

# Shell into instance
shell:
	@echo "[+] Opening shell in $(NAME)..."
	incus exec $(NAME) -- bash

# Show status
status:
	@echo "[+] Status of $(NAME):"
	@incus list $(NAME)
	@echo ""
	@if incus list -c n -f csv | grep -q "^$(NAME)$$"; then \
		echo "[+] Cloud-init status:"; \
		incus exec $(NAME) -- cloud-init status || true; \
		echo ""; \
		if [ "$(NAME)" = "headscale-server" ]; then \
			echo "[+] Headscale service status:"; \
			incus exec $(NAME) -- systemctl status headscale --no-pager || true; \
		elif [ "$(NAME)" = "headscale-gateway" ]; then \
			echo "[+] Tailscale status:"; \
			incus exec $(NAME) -- tailscale status || true; \
		fi \
	fi

# Show logs
logs:
	@echo "[+] Logs for $(NAME):"
	@if [ "$(NAME)" = "headscale-server" ]; then \
		incus exec $(NAME) -- journalctl -u headscale -n 50 --no-pager; \
	elif [ "$(NAME)" = "headscale-gateway" ]; then \
		incus exec $(NAME) -- journalctl -u tailscaled -n 50 --no-pager; \
	else \
		incus exec $(NAME) -- journalctl -n 50 --no-pager; \
	fi

# Clean all
clean:
	rm -rf $(RUN_DIR)
	@echo "Run 'make setup' before next deployment"

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
	@echo ""
	@echo "Environment Variables:"
	@echo "  HEADSCALE_SERVER_URL    = $(HEADSCALE_SERVER_URL)"
	@echo "  HEADSCALE_BASE_DOMAIN   = $(HEADSCALE_BASE_DOMAIN)"
	@echo "  GATEWAY_HOSTNAME        = $(GATEWAY_HOSTNAME)"
	@echo "  GATEWAY_ROUTES          = $(GATEWAY_ROUTES)"
