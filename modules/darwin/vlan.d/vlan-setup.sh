#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${VLAN_ID:-}" || -z "${VLAN_PARENT:-}" ]]; then
  echo "[vlan] VLAN_ID and VLAN_PARENT must be set" >&2
  exit 1
fi

VLAN_NAME="${VLAN_NAME:-vlan${VLAN_ID}}"

ADDRESS_PREFIX="${ADDRESS_PREFIX:-}"
NETMASK="${NETMASK:-255.255.255.0}"
SOURCE_IFACE="${SOURCE_IFACE:-}"

if [[ -z "$SOURCE_IFACE" ]]; then
  SOURCE_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
fi

if [[ -z "$SOURCE_IFACE" ]]; then
  echo "[vlan] no source interface found" >&2
  exit 0
fi

if ! ifconfig "$VLAN_NAME" >/dev/null 2>&1; then
  ifconfig "$VLAN_NAME" create
fi

ifconfig "$VLAN_NAME" vlan "$VLAN_ID" vlandev "$VLAN_PARENT"

IP_ADDR=$(ipconfig getifaddr "$SOURCE_IFACE" 2>/dev/null || true)
if [[ -z "$IP_ADDR" ]]; then
  IP_ADDR=$(ifconfig "$SOURCE_IFACE" | awk '/inet /{print $2; exit}')
fi

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

VLAN_IP="${ADDRESS_PREFIX}.${LAST_OCTET}"
ifconfig "$VLAN_NAME" inet "$VLAN_IP" netmask "$NETMASK" up

route -n delete default -ifscope "$VLAN_NAME" 2>/dev/null || true
