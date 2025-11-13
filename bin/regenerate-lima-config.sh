#!/usr/bin/env bash
# Regenerate Lima config and optionally managed vmnet networks.yaml (@codebase)
# Usage:
#   ./bin/regenerate-lima-config.sh [--host <alias-or-hostname>] [--flake <path>] \
#       [--write-networks] [--no-networks]
#
# Resolution order for config attrs:
#   1. --flake explicitly provided (use that flake)
#   2. If ./hosts/$HOST exists use host sub-flake and attr darwinConfiguration
#   3. Else use repo root flake and attr darwinConfigurations.$HOST
#
# Networks generation logic:
#   - Uses lima-yaml-manager.sh for surgical YAML editing of ~/.lima/_config/networks.yaml
#   - Ensures standard networks are defined: host, bridged, shared
#   - Preserves existing user-managed networks and comments
#   - Uses rotating backups (.0, .1, .2) for safety
#   - Safe to run multiple times - only adds missing networks
#
# Safe to run without nix-darwin activation script executing.
set -euo pipefail

HOSTNAME="$(hostname -s)"
REQUESTED_HOST=""
EXPLICIT_FLAKE=""
WRITE_NETWORKS=1

show_help() {
  sed -n '1,80p' "$0" | grep -v '^#!/';
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      REQUESTED_HOST="$2"; shift 2 ;;
    --flake)
      EXPLICIT_FLAKE="$2"; shift 2 ;;
    --write-networks)
      WRITE_NETWORKS=1; shift ;;
    --no-networks)
      WRITE_NETWORKS=0; shift ;;
    -h|--help)
      show_help; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

TARGET_DIR="$HOME/.lima/nerd-nixos"
mkdir -p "$TARGET_DIR"
OUT_FILE_JSON="$TARGET_DIR/lima.json"
OUT_FILE_YAML="$TARGET_DIR/lima.yaml"

if ! command -v nix >/dev/null 2>&1; then
  echo "Error: nix not found in PATH" >&2; exit 1
fi

USE_YQ=1
if ! command -v yq-go >/dev/null 2>&1 && ! command -v yq >/dev/null 2>&1; then
  echo "Warning: yq not found; output will remain JSON only" >&2
  USE_YQ=0
fi

HOST_REF="${REQUESTED_HOST:-$HOSTNAME}"

# Determine flake reference and attribute path
if [ -n "$EXPLICIT_FLAKE" ]; then
  FLAKE_REF="$EXPLICIT_FLAKE"
  PRIMARY_ATTR="darwinConfiguration.config.lima.computedConfig"
  FALLBACK_ATTR="darwinConfiguration.config.lima.configGenerator"
elif [ -d "hosts/$HOST_REF" ]; then
  FLAKE_REF="hosts/$HOST_REF"
  PRIMARY_ATTR="darwinConfiguration.config.lima.computedConfig"
  FALLBACK_ATTR="darwinConfiguration.config.lima.configGenerator"
else
  FLAKE_REF="."  # repo root
  PRIMARY_ATTR="darwinConfigurations.\"$HOST_REF\".config.lima.computedConfig"
  FALLBACK_ATTR="darwinConfigurations.\"$HOST_REF\".config.lima.configGenerator"
fi

echo "[regenerate-lima] flake=$FLAKE_REF primary=$PRIMARY_ATTR host=$HOST_REF" >&2

if ! NIX_JSON=$(nix eval --json "$FLAKE_REF"#"$PRIMARY_ATTR" 2>/dev/null); then
  echo "[regenerate-lima] primary attr missing, trying fallback: $FALLBACK_ATTR" >&2
  if ! NIX_JSON=$(nix eval --json "$FLAKE_REF"#"$FALLBACK_ATTR" 2>/dev/null); then
    echo "Error: nix eval failed for both $PRIMARY_ATTR and $FALLBACK_ATTR" >&2
    echo "Check host name or flake path; try --host bioskop." >&2
    exit 2
  fi
fi

if [ "$USE_YQ" -eq 1 ]; then
  if command -v yq-go >/dev/null 2>&1; then
    echo "$NIX_JSON" | yq-go -P -p json -o yaml eval . - > "$OUT_FILE_YAML"
  else
    echo "$NIX_JSON" | yq -P > "$OUT_FILE_YAML"
  fi
  chmod 0600 "$OUT_FILE_YAML"
  echo "Generated $OUT_FILE_YAML" >&2
  grep -E 'subnet|gateway|clusterId' "$OUT_FILE_YAML" || true

  # ---------------- Networks.yaml generation using lima-yaml-manager.sh ---------------- (@codebase)
  if [ $WRITE_NETWORKS -eq 1 ]; then
    echo "[regenerate-lima] networks: using lima-yaml-manager.sh for surgical YAML editing" >&2
    
    # Check if lima-yaml-manager.sh exists
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    YAML_MANAGER="$SCRIPT_DIR/lima-yaml-manager.sh"
    
    if [ ! -f "$YAML_MANAGER" ]; then
      echo "[regenerate-lima][WARN] lima-yaml-manager.sh not found at $YAML_MANAGER; skipping networks.yaml" >&2
    else
      CFG_DIR="$HOME/.lima/_config"
      NET_FILE="$CFG_DIR/networks.yaml"
      mkdir -p "$CFG_DIR"
      
      # Ensure networks.yaml exists with basic structure if missing
      if [ ! -f "$NET_FILE" ]; then
        echo "[regenerate-lima] networks: creating basic $NET_FILE" >&2
        cat > "$NET_FILE" <<NETCFG
paths:
  varRun: /private/var/run/lima
group: everyone
networks: {}
NETCFG
      fi
      
      # Add missing standard networks using lima-yaml-manager.sh
      # These are the networks that Lima VMs typically reference
      echo "[regenerate-lima] networks: ensuring standard networks are defined" >&2
      
      # Add 'host' network if missing
      if ! grep -q "^  host:" "$NET_FILE"; then
        echo "[regenerate-lima] networks: adding 'host' network definition" >&2
        "$YAML_MANAGER" --file "$NET_FILE" --add-network host --mode host \
          --gateway 172.16.106.1 --dhcp-end 172.16.106.224 --netmask 255.255.255.0 --verbose || {
          echo "[regenerate-lima][WARN] Failed to add 'host' network" >&2
        }
      fi
      
      # Add 'bridged' network if missing  
      if ! grep -q "^  bridged:" "$NET_FILE"; then
        echo "[regenerate-lima] networks: adding 'bridged' network definition" >&2
        "$YAML_MANAGER" --file "$NET_FILE" --add-network bridged --mode bridged \
          --interface en0 --verbose || {
          echo "[regenerate-lima][WARN] Failed to add 'bridged' network" >&2
        }
      fi
      
      # Add 'shared' network if missing
      if ! grep -q "^  shared:" "$NET_FILE"; then
        echo "[regenerate-lima] networks: adding 'shared' network definition" >&2
        "$YAML_MANAGER" --file "$NET_FILE" --add-network shared --mode shared \
          --gateway 10.80.16.1 --dhcp-end 10.80.16.224 --netmask 255.255.255.0 --verbose || {
          echo "[regenerate-lima][WARN] Failed to add 'shared' network" >&2
        }
      fi
      
      echo "[regenerate-lima] networks: standard network definitions ensured" >&2
    fi
  fi
else
  echo "Error: yq/yq-go not found; cannot generate YAML" >&2
  echo "Install yq-go: nix-env -iA nixpkgs.yq-go" >&2
  exit 3
fi
