#!/usr/bin/env bash
# KnownHostsCommand script (@codebase)
# Emits host CA certificate lines for dynamic known hosts resolution.
# Template variable @CA_DIR@ is replaced by Nix with the derivation output directory
# holding extracted CA public keys (files matching *-ca.pub).

set -e

LOG_DIR="${HOME}/.local/var"
mkdir -p "${LOG_DIR}"
exec 2>>"${LOG_DIR}/known-hosts.log"

host="$1"   # Provided by OpenSSH (may be empty)
ip="$2"     # Second argument (may be empty)

CA_DIR="@CA_DIR@"

shopt -s nullglob 2>/dev/null || true
for f in "${CA_DIR}"/*-ca.pub; do
  [ -f "${f}" ] || continue
  # First line contains the public key (format key comment)
  key_part="$(sed -n '1p' "${f}")"
  # Wildcard domain trust entry
  echo "@cert-authority ,principals=\"admin,staff,wheel\" * ${key_part}"
  # Specific host entry (only if host provided)
  if [ -n "${host}" ]; then
    echo "@cert-authority ,principals=\"admin,staff,wheel\" ${host} ${key_part}"
  fi
done

exit 0
