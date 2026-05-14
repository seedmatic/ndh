# Shared helpers for hs / hs-check / hs-mint.  Inlined into each
# writeShellApplication binary rather than sourced at runtime —
# writeShellApplication wraps the script text through `shellcheck` at
# build time, which can't follow relative `source` paths.  Inlining
# keeps the lint pass honest.
#
# Conventions:
#   - All helpers echo to stderr for diagnostic output; stdout is
#     reserved for machine-readable data the caller consumes.
#   - `sops` / `yq` / `headscale` / `tr` must be on PATH (the
#     writeShellApplication's runtimeInputs provides them).
#   - No jq / python3 fallbacks.  yq-go via env+strenv is the
#     canonical pattern for injecting secrets into YAML.

log::info() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }
log::warn() { printf '[%s][WARN] %s\n' "$(basename "$0")" "$*" >&2; }
log::error() { printf '[%s][ERROR] %s\n' "$(basename "$0")" "$*" >&2; }

# hs::config::path prints the effective path to the local headscale
# config if one exists.  Empty otherwise.  The `hs` CLI uses the
# unix socket when a config is present (no API key needed, local-
# only); otherwise falls back to gRPC over HEADSCALE_CLI_ADDRESS +
# HEADSCALE_CLI_API_KEY.
hs::config::path() {
	local candidate="${HOME}/.config/headscale/config.yaml"
	if [ -r "$candidate" ]; then
		printf '%s\n' "$candidate"
	fi
}

# hs::exec wraps `headscale` with the right transport: local config
# when available, env-vars when not.  Mirrors the dispatcher in the
# standalone `hs` wrapper so hs-check / hs-mint can reuse it without
# duplicating the branch logic.
#
# Requires the caller to have set HEADSCALE_CLI_ADDRESS +
# HEADSCALE_CLI_API_KEY when there's no local config file.
hs::exec() {
	local cfg
	cfg="$(hs::config::path)"
	if [ -n "$cfg" ]; then
		headscale -c "$cfg" "$@"
	else
		headscale "$@"
	fi
}

# sops::edit::set_string writes a plaintext YAML scalar into a
# sops-encrypted file, preserving the sops envelope.  Uses the
# decrypt → yq-i → re-encrypt pattern with env-var substitution to
# avoid jq/python3 fallbacks and to keep newlines / special chars
# intact.
#
# Arguments:
#   $1  path to the sops-encrypted YAML file
#   $2  yq expression identifying the target scalar,
#       e.g. '.tailnet.headscale.auth.darwin'
#   $3  plaintext value to write (read from stdin if "-")
sops::edit::set_string() {
	local sopsFile="$1"
	local yqPath="$2"
	local value="$3"
	if [ "$value" = "-" ]; then
		value="$(cat)"
	fi

	local tmp
	tmp="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" RETURN

	# sops infers input format from the file's extension; when the
	# source is at a non-standard path (e.g. the nix-store snapshot
	# /nix/store/.../source/.secrets), sops defaults to JSON and
	# misparses our YAML envelope with "invalid character 'c' looking
	# for beginning of value".  Always pin --input-type / --output-type
	# to yaml — the file actually is YAML regardless of its path.
	local decrypted="${tmp}/decrypted.yaml"
	if ! sops --input-type yaml --output-type yaml -d "$sopsFile" >"$decrypted"; then
		log::error "sops -d failed on $sopsFile"
		return 1
	fi
	if [ ! -s "$decrypted" ]; then
		log::error "sops -d produced an empty file (decryption failure; check SOPS_AGE_KEY_FILE)"
		return 1
	fi

	# Also attach the `sops:encrypted` line-comment to the scalar so
	# sops re-encrypts it on the next envelope pass.  `.sops.yaml`
	# pins `encrypted_comment_regex: 'sops:encrypted'`, and yq-go's
	# lineComment sets the trailing comment — either position on the
	# scalar is acceptable to sops.  Without this, a freshly-inserted
	# leaf would land as plaintext inside the encrypted file.
	env NDH_SOPS_VALUE="$value" yq eval -i "
		${yqPath} = strenv(NDH_SOPS_VALUE) |
		${yqPath} lineComment = \"sops:encrypted\"
	" "$decrypted"

	local reencrypted="${tmp}/reencrypted.yaml"
	if ! sops --input-type yaml --output-type yaml encrypt "$decrypted" >"$reencrypted"; then
		log::error "sops encrypt failed; $sopsFile left untouched"
		return 1
	fi
	if [ ! -s "$reencrypted" ]; then
		log::error "sops encrypt produced empty output; $sopsFile left untouched"
		return 1
	fi

	install -m 0644 "$reencrypted" "$sopsFile"
}

# sops::edit::get_string prints the plaintext value at a given yq
# path from a sops-encrypted file.  Empty output on missing path.
sops::edit::get_string() {
	local sopsFile="$1"
	local yqPath="$2"
	sops --input-type yaml --output-type yaml -d "$sopsFile" |
		yq eval -r "${yqPath} // \"\"" -
}
