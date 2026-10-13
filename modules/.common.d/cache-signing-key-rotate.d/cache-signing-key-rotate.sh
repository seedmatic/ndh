#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
NDH_LOGGER_NO_XTRACE=1 # read by ndh::logger:command:run, which then runs the command untraced
unset BASH_XTRACEFD 2>/dev/null || true
# cache-signing-key-rotate — replace the fleet's nix signing key, ON THE SEAT.
#
# catalog/cache-trust.yaml holds ONE fleet signing key under caches.cachix.<name>.private (the bare
# base64, without the `<name>:` prefix nix-daemon reads). This generates a new one under a new name,
# writes its private in place of the old entry — under its `# sops:encrypted` marker, since the
# file's rule encrypts only marked leaves and a plain `sops set` would leave it in clear — and prints
# the new PUBLIC, which catalog/cache-trust.nix then declares in place of the old one.
#
# Refused, keys.yaml-style, before anything is installed: a new private that is not ENC[ after the
# re-encryption, a recipient set that would change (aligning recipients is `sops updatekeys`, a
# gesture of its own), any change outside caches.cachix, and the new private readable anywhere in
# the encrypted file. A dry run generates NOTHING and prints the plan only.
#
# Usage: cache-signing-key-rotate --to NAME [--apply]     (run from the ndh repository root)

# shellcheck disable=SC1091
source @nixBashTrampoline@

# catalog/cache-trust.yaml relative to the repository root: the real file, and the copy whose path
# picks its sops creation rule (sops chooses the rule by the path it encrypts).
readonly fileRel="catalog/cache-trust.yaml"
readonly nix="@nix@"
declare -g file tmpdir decrypted newName apply oldName

# stdout: the logger sends stderr to the syslog, and the operator must see the plan.
log::info() { echo "[cache-signing-key-rotate][INFO] $*"; }
log::error() { echo "[cache-signing-key-rotate][ERROR] $*"; }

usage() {
	cat <<-EOF
		usage: cache-signing-key-rotate --to NAME [--apply]

		  --to NAME   the new key's name, e.g. seedmatic-fleet-1 (nix key names end in -<n>)
		  --apply     generate the key, rewrite ${fileRel} (re-encrypted), print the new public.
		              Without it, nothing is generated and the plan is printed.
	EOF
	return 64
}

# Who can read a sops file, every key provider included, sorted.
recipients::of() { # <sops file>
	yq eval -r '[
		((.sops.age // [])[] | "age:" + .recipient),
		((.sops.pgp // [])[] | "pgp:" + .fp),
		((.sops.kms // [])[] | "kms:" + .arn),
		((.sops.gcp_kms // [])[] | "gcp_kms:" + .resource_id),
		((.sops.azure_kv // [])[] | "azure_kv:" + .vault_url + "/" + .name),
		((.sops.hc_vault // [])[] | "hc_vault:" + .vault_address + "/" + .engine_path + "/" + .key_name)
	] | sort | join(",")' "$1"
}

rotate::apply() {
	local gen="${tmpdir}/gen" bare public reencrypted
	install -d -m 0700 "$gen"
	# `nix key` touches no store: the pair exists only in this 0700 directory, removed on exit.
	if ! (umask 077 && "$nix" --extra-experimental-features nix-command key generate-secret --key-name "$newName" >"${gen}/secret"); then
		log::error "nix could not generate ${newName}"
		return 1
	fi
	if ! "$nix" --extra-experimental-features nix-command key convert-secret-to-public <"${gen}/secret" >"${gen}/public"; then
		log::error "nix could not derive the public of ${newName}"
		return 1
	fi
	public="$(<"${gen}/public")"
	bare="$(<"${gen}/secret")"
	bare="${bare#"${newName}:"}"
	if [[ "$public" != "${newName}:"* || -z "$bare" || "$bare" == *:* ]]; then
		log::error "the generated pair does not have the <name>:<base64> shape; ${fileRel} left untouched"
		return 1
	fi

	if ! OLD="$oldName" NEW="$newName" BARE="$bare" yq eval -i '
		del(.caches.cachix[strenv(OLD)]) |
		.caches.cachix[strenv(NEW)].private = strenv(BARE) |
		(.caches.cachix[strenv(NEW)].private | key) headComment = "sops:encrypted"
	' "$decrypted"; then
		log::error "cannot write the new entry; ${fileRel} left untouched"
		return 1
	fi

	reencrypted="${tmpdir}/reencrypted"
	if ! (cd "${tmpdir}/repo" && sops --input-type yaml --output-type yaml encrypt "$fileRel") >"$reencrypted"; then
		log::error "sops encrypt failed; ${fileRel} left untouched"
		return 1
	fi

	# The new private is ciphertext, and readable nowhere in the file.
	if [[ "$(NEW="$newName" yq eval -r '.caches.cachix[strenv(NEW)].private' "$reencrypted")" != ENC\[* ]]; then
		log::error "the new private is NOT encrypted in the re-encrypted file; ${fileRel} left untouched"
		return 1
	fi
	if grep -qF -f <(printf '%s\n' "$bare") "$reencrypted"; then
		log::error "the new private appears in clear in the re-encrypted file; ${fileRel} left untouched"
		return 1
	fi
	# Who can read it is not this tool's business.
	if [[ "$(recipients::of "$file")" != "$(recipients::of "$reencrypted")" ]]; then
		log::error "${fileRel}'s recipients would change — align them with its rule first: sops updatekeys ${fileRel}"
		return 1
	fi
	# Nothing but the replaced entry moves: the re-encrypted document, decrypted again, equals the
	# committed one everywhere outside caches.cachix.
	local before after
	before="$(sops --input-type yaml --output-type yaml -d "$file" | yq eval 'del(.caches.cachix)' -)" || return 1
	after="$(sops --input-type yaml --output-type yaml -d "$reencrypted" | yq eval 'del(.caches.cachix)' -)" || return 1
	if [[ "$before" != "$after" ]]; then
		log::error "something outside caches.cachix changed; ${fileRel} left untouched"
		return 1
	fi

	install -m 0644 "$reencrypted" "$file" || return 1
	cat <<-EOF

		${fileRel}: caches.cachix.${oldName} replaced by caches.cachix.${newName}.

		New public (catalog/cache-trust.nix, caches.cachix."${newName}".publicKey):
		  ${public}

		Next: the public goes into catalog/cache-trust.nix in place of the old one, the old public is
		removed everywhere, and every host is switched — the old key then signs nothing and is trusted nowhere.
	EOF
}

main() {
	apply=0
	newName=""
	while (($# > 0)); do
		case "$1" in
			--to)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				newName="$2"
				shift 2
				;;
			--apply)
				apply=1
				shift
				;;
			*)
				usage
				return $?
				;;
		esac
	done
	if [[ ! "$newName" =~ ^[a-z][a-z0-9.-]*-[0-9]+$ ]]; then
		log::error "--to ${newName@Q}: a key name is ^[a-z][a-z0-9.-]*-<n>$ (e.g. seedmatic-fleet-1)"
		usage
		return $?
	fi

	file="$(git rev-parse --show-toplevel)/${fileRel}"
	[[ -r "$file" ]] || {
		log::error "${fileRel} not readable (run from the ndh repo root)"
		return 1
	}
	tmpdir="$(mktemp -d)"
	chmod 700 "$tmpdir"
	trap 'rm -rf "$tmpdir"' EXIT
	install -d -m 0700 "${tmpdir}/repo/$(dirname "$fileRel")"
	cp "$(git rev-parse --show-toplevel)/.sops.yaml" "${tmpdir}/repo/.sops.yaml"
	decrypted="${tmpdir}/repo/${fileRel}"
	if ! sops --input-type yaml --output-type yaml -d "$file" >"$decrypted" || [[ ! -s "$decrypted" ]]; then
		log::error "cannot decrypt ${fileRel} (check SOPS_AGE_KEY_FILE / sops.age.keyFile)"
		return 1
	fi

	local -a names
	mapfile -t names < <(yq eval -r '.caches.cachix // {} | keys | .[]' "$decrypted")
	if ((${#names[@]} != 1)); then
		log::error "${fileRel} holds ${#names[@]} fleet signing keys; this replaces exactly one"
		return 1
	fi
	oldName="${names[0]}"
	if [[ "$oldName" == "$newName" ]]; then
		log::error "--to names the key in place (${oldName}); a rotation takes a new name"
		return 1
	fi

	printf '\n%s\n  caches.cachix.%s  →  caches.cachix.%s (generated on this seat)\n\n' "$fileRel" "$oldName" "$newName"
	if ((apply == 0)); then
		log::info "dry run — nothing generated; pass --apply to generate the key and rewrite ${fileRel}"
		return 0
	fi
	rotate::apply
}

ndh::logger:command:run "@loggerTag@" main "$@"
