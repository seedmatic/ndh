#!/usr/bin/env bash
# @codebase
# Bootstrap a self-signed TLS root certificate for an authority in
# keys.yaml.
#
# Two modes:
#
#   1. Existing authority — keys.yaml already has a full authority
#      block (public + private, usage includes tls-authority).  Mint
#      the self-signed x509 root off the existing key and write it
#      back as `authorities.<name>.ca_crt`.
#
#   2. Fresh authority — keys.yaml has no entry at all.  Pass
#      `--create <keyType>` to generate the keypair and synthesise
#      the authority block alongside minting the cert.  Supported
#      keyType: `ecdsa-sha2-nistp256` (the SSH-wire name for ECDSA
#      P-256; chosen for macOS SecTrust compatibility since Apple
#      rejects Ed25519 x509 leaves at validation time).
#
# The authority's private lives encrypted in keys.yaml; `ca_crt` is
# the plaintext cert clients install into their trust stores.  One
# authority can sign SSH certs, TLS certs, or both — the `usage:`
# list on the authority controls which.
#
# This ceremony is explicitly *not* automated inside the enrichment
# pipeline — minting a new root is an operator action that rotates
# every client's trust, so it should always be intentional.  Run
# this once per authority, commit the resulting yaml diff, and ship.
#
# Usage:
#   authority-bootstrap-tls-root.sh <authority-name> [--force]
#   authority-bootstrap-tls-root.sh <authority-name> --create <keyType>
#
# Preconditions:
#   - keys.yaml is decryptable with the current sops age key.
#   - step-cli + sops + yq + ssh-keygen on PATH.
#
# Re-running (non-create mode) without --force is a no-op when
# `ca_crt` is already set.

set -euo pipefail

log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }
info() { log info "$*"; }
err() { log error "$*"; }

# Packaged as a flake app (`nix run .#authority-bootstrap-tls-root`), so $0 is a
# /nix/store path — resolve the repo from the invocation cwd instead (run from the
# ndh repo root).
REPO_ROOT="$(git rev-parse --show-toplevel)"
KEYS_YAML="${REPO_ROOT}/modules/home-manager/ssh.d/keys.yaml"

usage() {
	cat >&2 <<-EOF
		usage: $(basename "$0") <authority-name> [--force]
		       $(basename "$0") <authority-name> --create <keyType>

		  <authority-name>   Name of a top-level authorities.<name> in keys.yaml.
		  --force            Overwrite an existing ca_crt field.
		  --create <type>    Create a fresh authority entry with the given key
		                     type.  Supported: ecdsa-sha2-nistp256.

		Effect: writes authorities.<name>.ca_crt (and in --create mode, the
		full authority block) into keys.yaml via sops, re-encrypting the
		file in place.  Commit the yaml diff.
	EOF
	exit 64
}

authority="${1:-}"
mode="${2:-}"
modeArg="${3:-}"
[[ -n "$authority" ]] || usage
case "$mode" in
	"" | --force) ;;
	--create)
		[[ -n "$modeArg" ]] || usage
		;;
	*) usage ;;
esac

for tool in step sops yq ssh-keygen; do
	command -v "$tool" >/dev/null 2>&1 || { err "required tool not on PATH: $tool"; exit 127; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "decrypting ${KEYS_YAML}"
decrypted="${tmp}/keys.yaml"
sops --input-type yaml --output-type yaml -d "$KEYS_YAML" >"$decrypted"
if [[ ! -s "$decrypted" ]]; then
	err "sops -d produced an empty file (decryption failure; check SOPS_AGE_KEY_FILE / sops.age.keyFile)"
	exit 1
fi

authorityExists="$(yq eval ".authorities | has(\"${authority}\")" "$decrypted" 2>/dev/null || echo false)"

# --- --create mode: generate the keypair + synthesise the authority block ---
if [[ "$mode" == "--create" ]]; then
	if [[ "$authorityExists" == "true" ]]; then
		err "authority ${authority} already exists; remove it first or drop --create to re-sign with existing key"
		exit 1
	fi

	case "$modeArg" in
		ecdsa-sha2-nistp256)
			# ssh-keygen produces an OpenSSH-format private key with the
			# matching curve, which step-cli reads natively for x509
			# signing.  ECDSA P-256 is the curve Apple's SecTrust fully
			# supports — the reason this authority exists.
			info "generating ${modeArg} keypair"
			ssh-keygen -q -t ecdsa -b 256 -N "" \
				-f "${tmp}/${authority}-privkey" \
				-C "cert-authority@${authority}"
			;;
		*)
			err "unsupported --create keyType: ${modeArg}"
			err "supported types: ecdsa-sha2-nistp256"
			exit 1
			;;
	esac

	privPem="$(<"${tmp}/${authority}-privkey")"
	# The ssh-keygen .pub file has a trailing newline + comment; strip
	# to the raw base64 blob (second field) so it matches the shape
	# other authorities' `public` scalars use.
	pubBlob="$(awk '{print $2}' "${tmp}/${authority}-privkey.pub")"

	info "writing authority block into ${KEYS_YAML}"
	# yq-go's flow-style attrset syntax is finicky inside multi-line
	# expressions; populate each scalar as a separate statement for
	# clarity + line-comment assignment on the private (sops only
	# encrypts scalars preceded by `# sops:encrypted` per the repo's
	# .sops.yaml encrypted_comment_regex).
	env NDH_PRIV="$privPem" NDH_PUB="$pubBlob" \
		NDH_TYPE="$modeArg" \
		NDH_COMMENT="cert-authority@${authority}" \
		yq eval -i "
			.authorities.\"${authority}\".type = strenv(NDH_TYPE) |
			.authorities.\"${authority}\".comment = strenv(NDH_COMMENT) |
			.authorities.\"${authority}\".public = strenv(NDH_PUB) |
			.authorities.\"${authority}\".private = strenv(NDH_PRIV) |
			.authorities.\"${authority}\".private lineComment = \"sops:encrypted\" |
			.authorities.\"${authority}\".usage = [\"tls-authority\"] |
			.authorities.\"${authority}\".annotations.public_scope = \"system\"
		" "$decrypted"
fi

# --- Validation: the authority must exist + advertise tls-authority ---
if ! yq eval -e ".authorities | has(\"${authority}\")" "$decrypted" >/dev/null 2>&1; then
	err "authority ${authority} not found in ${KEYS_YAML}"
	err "hint: pass --create <keyType> to bootstrap a fresh authority entry"
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
if [[ -n "$existing" && "$mode" != "--force" && "$mode" != "--create" ]]; then
	err "authorities.${authority}.ca_crt already present; rerun with --force to replace (this invalidates every client's trust)"
	exit 1
fi

# --- Materialise the authority's private for step-cli ---
authKey="${tmp}/ca-signer"
yq eval -r ".authorities.\"${authority}\".private" "$decrypted" >"$authKey"
chmod 400 "$authKey"

# --- Mint the self-signed root ---
crtFile="${tmp}/${authority}-ca.crt"
# Template mirrors step's built-in root-ca profile but WITHOUT pathLenConstraint.
# The default profile stamps pathlen:1, which caps a valid path at a single
# intermediate below the root. Our RKE2 BYO-CA subtree nests two
# (rke2-intermediate-ca -> rke2-server-ca) before the leaf, so a strict verifier
# (OpenSSL/rustls — e.g. kube-rs clients like flux9s) rejects the served chain
# with X509_V_ERR_PATH_LENGTH_EXCEEDED, while client-go happens to anchor early
# and pass. Dropping the constraint lets the root anchor an arbitrary-depth
# subtree, as a top root normally does.
rootTmpl="${tmp}/root-ca.tmpl"
cat >"$rootTmpl" <<'STEP_TMPL'
{
	"subject": {{ toJson .Subject }},
	"issuer": {{ toJson .Subject }},
	"keyUsage": ["certSign", "crlSign"],
	"basicConstraints": {
		"isCA": true,
		"maxPathLen": -1
	}
}
STEP_TMPL
info "minting self-signed TLS root for ${authority} (validity 10y, no pathlen)"
step certificate create "$authority" \
	"$crtFile" "${tmp}/${authority}-ca.unused-key" \
	--template "$rootTmpl" \
	--key "$authKey" \
	--no-password --insecure \
	--not-after 87600h >/dev/null

if [[ ! -s "$crtFile" ]]; then
	err "step certificate create produced no output"
	exit 1
fi

# --- Inject ca_crt into the yaml ---
info "writing authorities.${authority}.ca_crt into ${KEYS_YAML} (re-encrypting)"
env CA_PEM="$(<"$crtFile")" yq eval -i \
	".authorities.\"${authority}\".ca_crt = strenv(CA_PEM)" "$decrypted"

# --- Re-encrypt atomically ---
reencrypted="${tmp}/keys.yaml.reenc"
sops --input-type yaml --output-type yaml encrypt "$decrypted" >"$reencrypted"
if [[ ! -s "$reencrypted" ]]; then
	err "sops encrypt produced an empty file; keys.yaml left untouched"
	exit 1
fi
install -m 0644 "$reencrypted" "$KEYS_YAML"

info "bootstrap complete for ${authority}"
info "Inspect the minted cert with:"
info "  sops -d ${KEYS_YAML} | yq eval -r '.authorities.\"${authority}\".ca_crt' - | step certificate inspect -"
info "Commit the yaml diff to ship the new trust anchor."
