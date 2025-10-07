#!/usr/bin/env bash
# KnownHostsCommand script (@codebase)
# Emits host CA certificate lines for dynamic known hosts resolution.
# Template variable @CA_DIR@ is replaced by Nix with the derivation output directory
# holding extracted CA public keys (files matching *-ca.pub).

set -euo pipefail

LOG_DIR="${HOME}/.local/var"
mkdir -p "${LOG_DIR}"
exec 2>>"${LOG_DIR}/known-hosts.log"

host="${1:-}"   # Provided by OpenSSH (may be empty)
ip="${2:-}"     # Second argument (may be empty)

CA_DIR="@CA_DIR@"

declare -A seen=()

emit_line() {
  local line="$1"
  [[ -z "${line}" ]] && return
  if [[ -n "${seen[${line}]:-}" ]]; then
    return
  fi
  echo "${line}"
  seen["${line}"]=1
}

trim_domain() {
  local raw="$1"
  printf '%s' "${raw}" | tr -d '\r' | sed -e 's/^\s\+//' -e 's/\s\+$//'
}

shopt -s nullglob 2>/dev/null || true
for f in "${CA_DIR}"/*-ca.pub; do
  [[ -f "${f}" ]] || continue

  key_part="$(sed -n '1p' "${f}")"
  base="${f%-ca.pub}"
  domain=""
  if [[ -f "${base}-ca.domain" ]]; then
    domain_raw="$(<"${base}-ca.domain")"
    domain="$(trim_domain "${domain_raw}")"
  fi

  if [[ -n "${domain}" ]]; then
    emit_line "@cert-authority *.${domain} ${key_part}"
  else
    emit_line "@cert-authority * ${key_part}"
  fi

  if [[ -n "${host}" ]]; then
    emit_line "@cert-authority ${host} ${key_part}"
  fi
done

exit 0
