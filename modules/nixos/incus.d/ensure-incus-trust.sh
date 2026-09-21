#!/usr/bin/env -S bash -euo pipefail

# Runs as a systemd oneshot just after incus.service — bootstrap runtime may not be present.
export NDH_BOOTSTRAP_INSTALLER_MODE=1
export NDH_BOOTSTRAP_STRICT=0
# shellcheck disable=SC1091
source @nixBashTrampoline@

incus_cmd='@incus@'
openssl_cmd='@openssl@'
manifest='@manifest@'

# Why a script and not `virtualisation.incus.preseed`, which does have a `certificates:` section:
# ApplyServerPreseed calls CreateCertificate BLINDLY for it, while its storage-pool, network and
# project sections all get-then-create-or-update. The preseed unit replays on every daemon start, so
# a second POST of an already-trusted fingerprint would fail the unit at every boot but the first.
# Hence the probe below. (An upstream fix — the same get-then-create guard — would retire this file.)

"${incus_cmd}" --force-local admin waitready --timeout 60

trusted_fingerprints="$(
  "${incus_cmd}" --force-local config trust list --format csv | awk -F, '{print $4}'
)"

while IFS=$'\t' read -r name cert_path; do
  [[ -n "${name}" ]] || continue

  fingerprint="$(
    "${openssl_cmd}" x509 -in "${cert_path}" -noout -fingerprint -sha256 |
      sed 's/^.*=//' | tr -d ':' | tr 'A-F' 'a-f'
  )"
  if [[ -z "${fingerprint}" ]]; then
    echo "[incus-trust] no fingerprint readable from ${cert_path} (${name})" >&2
    exit 1
  fi

  # `config trust list` prints the fingerprint truncated to 12 characters.
  if grep -Fxq "${fingerprint:0:12}" <<<"${trusted_fingerprints}"; then
    echo "[incus-trust] ${name} already trusted (${fingerprint:0:12})" >&2
    continue
  fi

  "${incus_cmd}" --force-local config trust add-certificate "${cert_path}" \
    --name "${name}" --type client
  echo "[incus-trust] trusted ${name} (${fingerprint:0:12})" >&2
done <"${manifest}"
