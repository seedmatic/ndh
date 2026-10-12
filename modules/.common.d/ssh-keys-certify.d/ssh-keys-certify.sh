#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset BASH_XTRACEFD 2>/dev/null || true
# ssh-keys-certify — sign, ON THE SEAT, every SSH certificate keys.yaml declares, and record it
# in keys.yaml next to the generation it certifies.
#
# Roles × keys 6a. Every host used to sign its own certificates at activation, which is why every
# host held the authority's private (L4). Here the seat signs once, from each key's PUBLIC, and the
# certificates travel in keys.yaml as public data: the activation only installs them.
#
#   ssh-host   the union of every name a fleet host or guest answers to (baked at build, computed
#              from the inventory and the guests' own configurations): one certificate per key
#              generation, valid wherever that key serves
#   ssh-user   the principals the key declares (`principals`)
#
# Valid forever, by decision: the hosts are checked strictly, so a certificate that expired
# unrenewed would break every connection. A leaked key is cut by `revoked` instead (sshd's
# RevokedKeys, every client's RevokedHostKeys). Signed by the authority's SIGNING slot — the oldest
# not marked compromised — the generation every trust store already carries.
#
# Idempotent: a certificate already recorded with the same key, authority generation, type,
# principals, identity and validity is kept as it is. Dry run by default; --apply rewrites keys.yaml.
#
# Usage: ssh-keys-certify [--apply]     (run from the ndh repository root)

# shellcheck disable=SC1091
source @nixBashTrampoline@

declare -g keysYaml tmpdir decrypted apply
declare -ga hostPrincipals=() plan=() current=()
IFS=',' read -r -a hostPrincipals <<<"@hostPrincipals@"

# stdout, like ssh-keys-renew: the logger sends stderr to the syslog, and the operator must see the plan.
log::info() { echo "[ssh-keys-certify][INFO] $*"; }
log::error() { echo "[ssh-keys-certify][ERROR] $*"; }

usage() {
	cat <<-EOF
		usage: ssh-keys-certify [--apply]

		  Sign every ssh-host / ssh-user certificate keys.yaml declares with its authority's
		  signing slot, and record each one under
		  keys.<key>.slots.<slot>.certificates.<authority>.<usage>. Dry run by default.

		  --apply   sign what is missing or stale and rewrite keys.yaml (re-encrypted)
	EOF
	return 64
}

yq::get() { yq eval -r "$1" "$decrypted"; }

# The oldest authority slot not marked compromised: the generation that signs (keys.schema.yaml).
authority::signing_slot() { # <authority>
	local slot
	while IFS= read -r slot; do
		[[ -n "$slot" ]] || continue
		[[ -n "$(yq::get ".authorities.\"$1\".slots.\"${slot}\".compromised // \"\"")" ]] && continue
		printf '%s\n' "$slot"
		return 0
	done < <(yq::get ".authorities.\"$1\".slots // {} | keys | sort | .[]")
	return 1
}

# The `-I` identity the downstream consumers (split-exp, extract-keys) read.
cert::identity() { # <key> <usage>
	KEYNAME="$1" USAGE="$2" yq --null-input --indent=0 --output-format=json eval \
		'{"marker": "ndh-ssh-key-meta-v1", "owner": "home-manager.ssh-add-keys", "key": strenv(KEYNAME), "usage": [strenv(USAGE)]}'
}

cert::principals_for() { # <key> <usage> → comma-separated, sorted
	if [[ "$2" == ssh-host ]]; then
		printf '%s\n' "${hostPrincipals[@]}"
	else
		yq::get ".keys.\"$1\".principals // {} | keys | .[]"
	fi | sort -u | paste -sd, -
}

# What a recorded certificate says, normalised: type, key, CA, identity, validity, principals.
cert::describe() { # <cert file>
	ssh-keygen -L -f "$1" | awk '
		/^ *Type:/ { type = ($0 ~ /host certificate/) ? "host" : "user" }
		/^ *Public key:/ { key = $NF }
		/^ *Signing CA:/ { ca = $(NF - 2) }
		/^ *Key ID:/ { sub(/^ *Key ID: /, ""); id = $0 }
		/^ *Valid:/ { sub(/^ *Valid: /, ""); valid = $0 }
		/^ *Principals:/ { p = 1; next }
		/^ *Critical Options:/ { p = 0 }
		p { gsub(/^ +/, ""); if ($0 != "(none)") names = names (names ? "\n" : "") $0 }
		END {
			n = split(names, arr, "\n"); sorted = ""
			for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (arr[j] < arr[i]) { t = arr[i]; arr[i] = arr[j]; arr[j] = t }
			for (i = 1; i <= n; i++) sorted = sorted (i > 1 ? "," : "") arr[i]
			print type "|" key "|" ca "|" id "|" valid "|" sorted
		}'
}

# The description a certificate signed now would have, to compare with the recorded one.
cert::expected() { # <key> <slot> <authority> <authority slot> <usage>
	local type keyFp caFp
	type="$([[ "$5" == ssh-host ]] && echo host || echo user)"
	keyFp="$(printf '%s %s\n' "$(yq::get ".keys.\"$1\".type")" "$(yq::get ".keys.\"$1\".slots.\"$2\".public")" | ssh-keygen -lf - | awk '{print $2}')"
	caFp="$(printf '%s %s\n' "$(yq::get ".authorities.\"$3\".type // \"ssh-ed25519\"")" "$(yq::get ".authorities.\"$3\".slots.\"$4\".public")" | ssh-keygen -lf - | awk '{print $2}')"
	printf '%s|%s|%s|"%s"|forever|%s\n' "$type" "$keyFp" "$caFp" "$(cert::identity "$1" "$5")" "$(cert::principals_for "$1" "$5")"
}

plan::build() {
	local key authority authSlot slot usage recorded
	while IFS= read -r key; do
		[[ -n "$key" ]] || continue
		authority="$(yq::get ".keys.\"${key}\".authority // \"\"")"
		[[ -n "$authority" ]] || continue
		if ! authSlot="$(authority::signing_slot "$authority")"; then
			log::error "authority ${authority}: no slot may sign (all compromised, or none) — ${key} cannot be certified"
			return 1
		fi
		while IFS= read -r slot; do
			[[ -n "$slot" ]] || continue
			while IFS= read -r usage; do
				[[ "$usage" == ssh-host || "$usage" == ssh-user ]] || continue
				recorded="$(yq::get ".keys.\"${key}\".slots.\"${slot}\".certificates.\"${authority}\".\"${usage}\" // \"\"")"
				if [[ -n "$recorded" ]]; then
					printf '%s\n' "$recorded" >"${tmpdir}/recorded-cert.pub"
					if [[ "$(cert::describe "${tmpdir}/recorded-cert.pub")" == "$(cert::expected "$key" "$slot" "$authority" "$authSlot" "$usage")" ]]; then
						current+=("${key}	${slot}	${usage}")
						continue
					fi
				fi
				plan+=("${key}	${slot}	${authority}	${authSlot}	${usage}	$([[ -n "$recorded" ]] && echo stale || echo missing)")
			done < <(yq::get ".keys.\"${key}\".cert_usage // [] | .[]")
		done < <(yq::get ".keys.\"${key}\".slots // {} | keys | sort | .[]")
	done < <(yq::get '.keys // {} | keys | .[]')
}

plan::show() {
	local line key slot authority authSlot usage why
	printf '\nkeys.yaml   %s\nhost names  %s (%s)\n\n' "$keysYaml" "${#hostPrincipals[@]}" "$(
		IFS=,
		echo "${hostPrincipals[*]}"
	)"
	for line in ${current[@]+"${current[@]}"}; do
		IFS=$'\t' read -r key slot usage <<<"$line"
		printf '  current  %-22s %-9s %s\n' "$key" "$slot" "$usage"
	done
	for line in ${plan[@]+"${plan[@]}"}; do
		IFS=$'\t' read -r key slot authority authSlot usage why <<<"$line"
		printf '  %-8s %-22s %-9s %-9s signed by %s@%s\n' "$why" "$key" "$slot" "$usage" "$authority" "$authSlot"
	done
	printf '\n'
}

certify::one() { # <key> <slot> <authority> <authority slot> <usage>
	local key="$1" slot="$2" authority="$3" authSlot="$4" usage="$5"
	local authFile="${tmpdir}/authority-${authority}@${authSlot}"
	if [[ ! -s "$authFile" ]]; then
		yq::get ".authorities.\"${authority}\".slots.\"${authSlot}\".private" >"$authFile"
		chmod 400 "$authFile"
	fi
	local stem="${tmpdir}/${key}@${slot}-${usage}"
	printf '%s %s %s\n' "$(yq::get ".keys.\"${key}\".type")" "$(yq::get ".keys.\"${key}\".slots.\"${slot}\".public")" \
		"$(yq::get ".keys.\"${key}\".comment // \"${key}\"")" >"${stem}.pub"
	local -a args=(-q -s "$authFile" -I "$(cert::identity "$key" "$usage")" -n "$(cert::principals_for "$key" "$usage")")
	[[ "$usage" == ssh-host ]] && args+=(-h)
	ssh-keygen "${args[@]}" "${stem}.pub"
	log::info "signed ${key}@${slot} ${usage} with ${authority}@${authSlot}"
	CERT="$(<"${stem}-cert.pub")" yq eval -i \
		".keys.\"${key}\".slots.\"${slot}\".certificates.\"${authority}\".\"${usage}\" = strenv(CERT)" "$decrypted"
}

certify::apply() {
	local line reencrypted
	for line in "${plan[@]}"; do
		IFS=$'\t' read -r key slot authority authSlot usage _ <<<"$line"
		certify::one "$key" "$slot" "$authority" "$authSlot" "$usage"
	done
	reencrypted="${tmpdir}/keys.yaml.reenc"
	sops --input-type yaml --output-type yaml encrypt "$decrypted" >"$reencrypted"
	[[ -s "$reencrypted" ]] || {
		log::error "sops encrypt produced an empty file; keys.yaml left untouched"
		return 1
	}
	# Every private, of every key and authority, must still be ciphertext: a certificate is public
	# and travels in clear, nothing else may.
	if [[ "$(yq eval '[.keys[].slots[].private, .authorities[].slots[].private] | map(select(. != null)) | all_c(test("^ENC\["))' "$reencrypted")" != true ]]; then
		log::error "a private is NOT encrypted in the re-encrypted file; keys.yaml left untouched"
		return 1
	fi
	install -m 0644 "$reencrypted" "$keysYaml"
	cat <<-EOF

		${#plan[@]} certificate(s) recorded in keys.yaml.

		Next, in order:
		  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
		  2. commit the keys.yaml diff
		  3. activate every host: each installs the certificates recorded here
	EOF
}

main() {
	apply=0
	while (($# > 0)); do
		case "$1" in
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
	if ((${#hostPrincipals[@]} == 0)); then
		log::error "no host names were baked into this build — refusing to sign a host certificate for nobody"
		return 1
	fi

	keysYaml="$(git rev-parse --show-toplevel)/modules/home-manager/ssh.d/keys.yaml"
	[[ -r "$keysYaml" ]] || {
		log::error "keys.yaml not readable at ${keysYaml} (run from the ndh repo root)"
		return 1
	}
	tmpdir="$(mktemp -d)"
	chmod 700 "$tmpdir"
	trap 'rm -rf "$tmpdir"' EXIT
	decrypted="${tmpdir}/keys.yaml"
	sops --input-type yaml --output-type yaml -d "$keysYaml" >"$decrypted"
	[[ -s "$decrypted" ]] || {
		log::error "sops -d produced an empty file (check SOPS_AGE_KEY_FILE / sops.age.keyFile)"
		return 1
	}

	plan::build
	plan::show
	if ((${#plan[@]} == 0)); then
		log::info "every certificate is current — nothing to sign"
		return 0
	fi
	if ((apply == 0)); then
		log::info "dry run — pass --apply to sign and rewrite keys.yaml"
		return 0
	fi
	certify::apply
}

ndh::logger:command:run "@loggerTag@" main "$@"
