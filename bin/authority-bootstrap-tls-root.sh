#!/usr/bin/env bash
# @codebase
# Bootstrap a self-signed TLS root certificate for an SSH authority
# declared in modules/home-manager/ssh.d/keys.yaml.
#
# Mints the cert with step-cli against the authority's OpenSSH-format
# Ed25519 private key and writes it back INTO keys.yaml as
# `authorities.<name>.ca_crt` via `sops set`.  Co-locating with the
# rest of the authority's material (public + private + usage) keeps
# one source of truth for both SSH and TLS anchor bytes; the cert
# scalar is a public-key artifact (same category as `.public:`) so
# it lives in cleartext even inside the sops-encrypted document.
#
# This ceremony is explicitly *not* automated inside the enrichment
# pipeline — minting a new root is an operator action that rotates
# every client's trust, so it should always be intentional.  Run this
# once per authority, commit the resulting yaml diff, and ship.
#
# Usage:
#   authority-bootstrap-tls-root.sh <authority-name> [--force]
#
# Preconditions:
#   - keys.yaml is decryptable with the current sops age key.
#   - The authority exists in the decrypted keys bundle with
#     usage: [..., tls-authority, ...].
#   - step-cli + sops + yq are on PATH.
#
# Re-running without --force is a no-op when `ca_crt` is already set.
#
set -euo pipefail

log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }
info() { log info "$*"; }
err() { log error "$*"; }

REPO_ROOT="$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"
KEYS_YAML="${REPO_ROOT}/modules/home-manager/ssh.d/keys.yaml"

usage() {
	cat >&2 <<EOF
usage: $(basename "$0") <authority-name> [--force]

  <authority-name>   Name of a top-level authorities.<name> in keys.yaml.
  --force            Overwrite an existing ca_crt field.

Effect: writes authorities.<name>.ca_crt into keys.yaml (via sops set),
re-encrypting the file in place.  Commit the yaml diff.
EOF
	exit 64
}

authority="${1:-}"
force="${2:-}"
[[ -n "$authority" ]] || usage
[[ -z "$force" || "$force" == "--force" ]] || usage

for tool in step sops yq ssh-keygen; do
	command -v "$tool" >/dev/null 2>&1 || { err "required tool not on PATH: $tool"; exit 127; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "decrypting ${KEYS_YAML}"
decrypted="${tmp}/keys.yaml"
sops -d "$KEYS_YAML" >"$decrypted"
if [[ ! -s "$decrypted" ]]; then
	err "sops -d produced an empty file (decryption failure; check SOPS_AGE_KEY_FILE / sops.age.keyFile)"
	exit 1
fi

# Guard: authority must exist and advertise tls-authority.  yq-go uses
# contains() for array-membership; index() exists in jq but trips a
# lexer error here.
if ! yq eval -e ".authorities | has(\"${authority}\")" "$decrypted" >/dev/null 2>&1; then
	err "authority ${authority} not found in ${KEYS_YAML}"
	exit 1
fi
if ! yq eval -e "(.authorities.\"${authority}\".usage // []) | contains([\"tls-authority\"])" \
	"$decrypted" >/dev/null 2>&1; then
	err "authority ${authority} does not advertise tls-authority in its usage list"
	err "decrypted usage list is:"
	yq eval ".authorities.\"${authority}\".usage" "$decrypted" >&2 || true
	err "edit modules/home-manager/ssh.d/keys.yaml via 'sops' and add 'tls-authority'"
	exit 1
fi

existing="$(yq eval -r ".authorities.\"${authority}\".ca_crt // \"\"" "$decrypted")"
if [[ -n "$existing" && "$force" != "--force" ]]; then
	err "authorities.${authority}.ca_crt already present; rerun with --force to replace (this invalidates every client's trust)"
	exit 1
fi

keyType="$(yq eval -r ".authorities.\"${authority}\".type" "$decrypted")"
if [[ "$keyType" != "ssh-ed25519" ]]; then
	err "authority ${authority} is ${keyType}; only ssh-ed25519 is supported for now"
	exit 1
fi

# Materialise the authority private as a tempfile step-cli reads.
authKey="${tmp}/ca"
yq eval -r ".authorities.\"${authority}\".private" "$decrypted" >"$authKey"
chmod 400 "$authKey"

# Mint the self-signed root.  step-cli always writes a PKCS8 copy of
# the signer key next to the cert; we throw that away — the real
# private stays in keys.yaml.
crtFile="${tmp}/${authority}-ca.crt"
info "minting self-signed TLS root for ${authority} (validity 10y)"
step certificate create "$authority" \
	"$crtFile" "${tmp}/${authority}-ca.unused-key" \
	--profile root-ca \
	--key "$authKey" \
	--no-password --insecure \
	--not-after 87600h >/dev/null

if [[ ! -s "$crtFile" ]]; then
	err "step certificate create produced no output"
	exit 1
fi

# Inject authorities.<name>.ca_crt via a decrypt → yq-in-place →
# re-encrypt cycle.  yq-go doesn't support `--arg`, so PEM bytes
# travel through a single env var (`CA_PEM`) consumed by `strenv()`
# inside the yq expression — this keeps newlines and special chars
# intact without a JSON-escape fallback chain (no jq, no python3).
info "writing authorities.${authority}.ca_crt into ${KEYS_YAML} (re-encrypting)"
env CA_PEM="$(<"$crtFile")" yq eval -i \
	".authorities.\"${authority}\".ca_crt = strenv(CA_PEM)" "$decrypted"

# Re-encrypt atomically: sops encrypts into a sibling tempfile, then
# we mv over the original only if encryption succeeded.  Preserves
# the original's sops recipients/metadata shape (age keys, mac, etc.)
# because sops reads them from the existing encrypted file.
reencrypted="${tmp}/keys.yaml.reenc"
sops encrypt --input-type yaml --output-type yaml "$decrypted" >"$reencrypted"
if [[ ! -s "$reencrypted" ]]; then
	err "sops encrypt produced an empty file; keys.yaml left untouched"
	exit 1
fi
install -m 0644 "$reencrypted" "$KEYS_YAML"

info "bootstrap complete for ${authority}"
info "Inspect the minted cert with:"
info "  sops -d ${KEYS_YAML} | yq eval -r '.authorities.\"${authority}\".ca_crt' - | step certificate inspect -"
info "Commit the yaml diff to ship the new trust anchor."
