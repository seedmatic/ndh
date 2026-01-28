#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${VLAN_ID:-}" || -z "${VLAN_PARENT:-}" ]]; then
  echo "[vlan] VLAN_ID and VLAN_PARENT must be set" >&2
  exit 1
fi

VLAN_NAME="${VLAN_NAME:-vlan${VLAN_ID}}"

ADDRESS_PREFIX="${ADDRESS_PREFIX:-}"
NETMASK_PREFIX="${NETMASK_PREFIX:-24}"
SOURCE_IFACE="${SOURCE_IFACE:-$VLAN_PARENT}"

if ! ip link show "$VLAN_PARENT" >/dev/null 2>&1; then
  echo "[vlan] parent interface $VLAN_PARENT not found" >&2
  exit 0
fi

if ! ip link show "$VLAN_NAME" >/dev/null 2>&1; then
  ip link add link "$VLAN_PARENT" name "$VLAN_NAME" type vlan id "$VLAN_ID"
fi

ip link set "$VLAN_PARENT" up
ip link set "$VLAN_NAME" up

IP_ADDR=$(ip -4 -o addr show dev "$SOURCE_IFACE" | awk '{print $4}' | head -n1 | cut -d/ -f1)
if [[ -z "$IP_ADDR" ]]; then
  echo "[vlan] no IPv4 address on $SOURCE_IFACE" >&2
  exit 0
fi

LAST_OCTET="${IP_ADDR##*.}"
if [[ -z "$LAST_OCTET" ]]; then
  echo "[vlan] unable to derive last octet from $IP_ADDR" >&2
  exit 0
fi

if [[ -z "$ADDRESS_PREFIX" ]]; then
  echo "[vlan] ADDRESS_PREFIX is not set" >&2
  exit 1
fi

VLAN_IP="${ADDRESS_PREFIX}.${LAST_OCTET}/${NETMASK_PREFIX}"
ip addr flush dev "$VLAN_NAME"
ip addr add "$VLAN_IP" dev "$VLAN_NAME"
