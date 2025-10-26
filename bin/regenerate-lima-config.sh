#!/usr/bin/env bash
# Regenerate Lima config and optionally managed vmnet networks.yaml (@codebase)
# Usage:
#   ./bin/regenerate-lima-config.sh [--host <alias-or-hostname>] [--flake <path>] \
#       [--write-networks] [--no-networks] [--netmask <mask>] [--overwrite-networks]
#
# Resolution order for config attrs:
#   1. --flake explicitly provided (use that flake)
#   2. If ./hosts/$HOST exists use host sub-flake and attr darwinConfiguration
#   3. Else use repo root flake and attr darwinConfigurations.$HOST
#
# Networks generation logic:
#   - If enabled (default) tries to evaluate nix options:
#       lima.networks.enableManagedClusterNetwork
#       lima.networks.netmask
#       lima.networks.overwrite
#     Falls back to defaults if evaluation fails.
#   - Deterministic clusterId derived from host name via internal map (bioskop->1, alcide->2).
#   - Generates or updates ~/.lima/_config/networks.yaml cluster<id> block with gateway, dhcpEnd, netmask.
#   - Allows override via CLI flags (highest precedence).
#
# Safe to run without nix-darwin activation script executing.
set -euo pipefail

HOSTNAME="$(hostname -s)"
REQUESTED_HOST=""
EXPLICIT_FLAKE=""
WRITE_NETWORKS=1
OVERWRITE_FLAG=0
CLI_NETMASK=""

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
    --overwrite-networks)
      OVERWRITE_FLAG=1; shift ;;
    --netmask)
      CLI_NETMASK="$2"; shift 2 ;;
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
    echo "Check host name or flake path; try --host bioskop or --host alcide." >&2
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

  # ---------------- Networks.yaml generation (managed vmnet) ---------------- (@codebase)
  if [ $WRITE_NETWORKS -eq 1 ]; then
    echo "[regenerate-lima] networks: attempting managed networks.yaml update" >&2
    # Evaluate nix options if possible (ignore errors)
    eval_attr() {
      local attr="$1"
      nix eval --raw "$FLAKE_REF"#"$attr" 2>/dev/null || true
    }

    if [ -z "$EXPLICIT_FLAKE" ] && [ ! -d "hosts/$HOST_REF" ]; then
      NET_BASE="darwinConfigurations.\"$HOST_REF\".config.lima.networks"
    else
      NET_BASE="darwinConfiguration.config.lima.networks"
    fi
    NIX_ENABLE=$(eval_attr "$NET_BASE.enableManagedClusterNetwork")
    NIX_MASK=$(eval_attr "$NET_BASE.netmask")
    NIX_OVERWRITE=$(eval_attr "$NET_BASE.overwrite")

    # Fallback defaults
    [ -z "$NIX_ENABLE" ] && NIX_ENABLE="true"
    [ -z "$NIX_MASK" ] && NIX_MASK="255.255.255.0"
    [ -z "$NIX_OVERWRITE" ] && NIX_OVERWRITE="false"

    # CLI overrides
    [ -n "$CLI_NETMASK" ] && NIX_MASK="$CLI_NETMASK"
    [ $OVERWRITE_FLAG -eq 1 ] && NIX_OVERWRITE="true"

    if [ "$NIX_ENABLE" != "true" ]; then
      echo "[regenerate-lima] networks: nix option enableManagedClusterNetwork=false; skipping." >&2
    else
      # Host cluster map (replicates Nix module logic)
      case "$HOST_REF" in
        bioskop) CLUSTER_ID=1 ;;
        alcide) CLUSTER_ID=2 ;;
        *) echo "[regenerate-lima][WARN] No clusterId mapping for host '$HOST_REF'; skipping networks.yaml" >&2; CLUSTER_ID=0 ;;
      esac
      if [ $CLUSTER_ID -gt 0 ]; then
        BASE_OCTET=$((CLUSTER_ID * 8))
        GATEWAY="10.80.${BASE_OCTET}.1"
        DHCP_END="10.80.${BASE_OCTET}.224"
        NETWORK_NAME="cluster${CLUSTER_ID}"
        CFG_DIR="$HOME/.lima/_config"
        NET_FILE="$CFG_DIR/networks.yaml"
        mkdir -p "$CFG_DIR"
        BLOCK_HEADER="  ${NETWORK_NAME}:"
        DESIRED_BLOCK="  ${NETWORK_NAME}:\n    mode: shared\n    gateway: ${GATEWAY}\n    dhcpEnd: ${DHCP_END}\n    netmask: ${NIX_MASK}"
        if [ ! -f "$NET_FILE" ]; then
          echo "[regenerate-lima] networks: creating $NET_FILE with ${NETWORK_NAME}" >&2
          cat > "$NET_FILE" <<NETCFG
  paths:
    varRun: /private/var/run/lima
  group: everyone
  networks:
  ${DESIRED_BLOCK}
  NETCFG
        else
          if grep -q "^${BLOCK_HEADER}" "$NET_FILE"; then
            EXISTING=$(grep -A4 "^${BLOCK_HEADER}" "$NET_FILE" || true)
            if echo "$EXISTING" | grep -q "gateway: ${GATEWAY}" && \
               echo "$EXISTING" | grep -q "dhcpEnd: ${DHCP_END}" && \
               echo "$EXISTING" | grep -q "netmask: ${NIX_MASK}"; then
              echo "[regenerate-lima] networks: ${NETWORK_NAME} matches desired" >&2
            else
              if [ "$NIX_OVERWRITE" = "true" ]; then
                echo "[regenerate-lima] networks: overwriting differing ${NETWORK_NAME}" >&2
                awk -v start="${BLOCK_HEADER}" 'BEGIN{skip=0} {
                  if($0==start){print; skip=4; next}
                  if(skip>0){skip--; next}
                  print
                }' "$NET_FILE" > "$NET_FILE.tmp" && mv "$NET_FILE.tmp" "$NET_FILE"
                echo "$DESIRED_BLOCK" >> "$NET_FILE"
              else
                echo "[regenerate-lima][WARN] ${NETWORK_NAME} differs; overwrite disabled" >&2
              fi
            fi
          else
            echo "[regenerate-lima] networks: appending ${NETWORK_NAME}" >&2
            echo "$DESIRED_BLOCK" >> "$NET_FILE"
          fi
        fi
        echo "[regenerate-lima] networks: gateway=${GATEWAY} dhcpEnd=${DHCP_END} netmask=${NIX_MASK}" >&2
      fi
    fi
  fi
else
  echo "Error: yq/yq-go not found; cannot generate YAML" >&2
  echo "Install yq-go: nix-env -iA nixpkgs.yq-go" >&2
  exit 3
fi
