#!/usr/bin/env -S bash -euo pipefail

# shellcheck disable=SC1091
source @bashTrampoline@

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
    openssl x509 -in "${server_cert}" -noout -ext subjectAltName 2>/dev/null \
      | tr ',' '\n' \
      | sed -n 's/^[[:space:]]*DNS://p' \
      | sed '/^$/d' \
      | sort -u
  )
fi

mapfile -t desired_names_sorted < <(printf '%s\n' "${desired_names[@]}" | sed '/^$/d' | sort -u)

if [[ -s "${server_key}" && "${existing_names[*]-}" == "${desired_names_sorted[*]-}" ]]; then
  echo "[incus-cert] SANs already up to date for ${primary_name}" >&2
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

san_entries=""
for name in "${desired_names_sorted[@]}"; do
  if [[ -z "${san_entries}" ]]; then
    san_entries="DNS:${name}"
  else
    san_entries="${san_entries},DNS:${name}"
  fi
done

openssl_config="${tmp_dir}/openssl-incus.cnf"
cat > "${openssl_config}" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no

[dn]
CN = root@${primary_name}
O = Linux Containers

[v3_req]
subjectAltName = ${san_entries}
EOF

openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
  -days 825 \
  -keyout "${tmp_dir}/server.key" \
  -out "${tmp_dir}/server.crt" \
  -config "${openssl_config}" \
  -extensions v3_req

install -m 0600 "${tmp_dir}/server.key" "${server_key}"
install -m 0644 "${tmp_dir}/server.crt" "${server_cert}"

echo "[incus-cert] updated server certificate SANs: ${san_entries}" >&2
