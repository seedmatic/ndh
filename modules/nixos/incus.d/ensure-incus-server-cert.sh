#!/usr/bin/env -S bash -euo pipefail

# Runs as a systemd ExecStartPre — bootstrap runtime may not be present.
export NDH_BOOTSTRAP_INSTALLER_MODE=1
export NDH_BOOTSTRAP_STRICT=0
# shellcheck disable=SC1091
source @nixBashTrampoline@

openssl_cmd='@openssl@'

incus_state_dir="/var/lib/incus"
server_cert="${incus_state_dir}/server.crt"
server_key="${incus_state_dir}/server.key"
primary_name="@incusServerCertPrimaryName@"
# shellcheck disable=SC2206
desired_names=( @incusServerCertNames@ )

if [[ ${#desired_names[@]} -eq 0 ]]; then
  echo "[incus-cert] no desired SAN names resolved; skipping" >&2
  exit 0
fi

install -d -m 0711 "${incus_state_dir}"

existing_names=()
if [[ -s "${server_cert}" ]]; then
  mapfile -t existing_names < <(
    "${openssl_cmd}" x509 -in "${server_cert}" -noout -ext subjectAltName 2>/dev/null \
      | tr ',' '\n' \
      | sed -n 's/^[[:space:]]*DNS://p' \
      | sed '/^$/d' \
      | sort -u
  )
fi

mapfile -t desired_names_sorted < <(printf '%s\n' "${desired_names[@]}" | sed '/^$/d' | sort -u)

# Nothing here generates a key (docs/ssh-keys-architecture.adoc: no key is generated at activation):
# Incus makes its own at first start, and a wrong name set is a loud warning, never a re-key, since a
# fresh self-signed key here would undo the certificate the operator seat signed on the existing one.
if [[ ! -s "${server_cert}" || ! -s "${server_key}" ]]; then
  echo "[incus-cert] no server certificate yet: incus generates its own at first start" >&2
  exit 0
fi

if [[ "${existing_names[*]-}" == "${desired_names_sorted[*]-}" ]]; then
  echo "[incus-cert] SANs already up to date for ${primary_name}" >&2
  exit 0
fi

echo "[incus-cert] WARNING: ${server_cert} names [${existing_names[*]-}], the fleet expects [${desired_names_sorted[*]-}]" >&2
echo "[incus-cert] the certificate and its key are kept; renew it on the operator seat: incus-cluster-cert-renew" >&2
