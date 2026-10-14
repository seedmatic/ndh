#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
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

# keys.yaml relative to the repository root: the real file, and the copy whose path picks its sops rule.
readonly keysRel="modules/home-manager/ssh.d/keys.yaml"
# ssh-keygen is pinned: the signature AND the comparison of a recorded certificate read its `-L`
# output, and the first ssh-keygen on PATH (Apple's or nix's) made a current certificate look stale.
readonly sshKeygen="@sshKeygen@"
declare -g keysYaml tmpdir decrypted apply
declare -ga hostPrincipals=() plan=() current=() unrecorded=()
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

# What a recorded certificate says, normalised: type, key, CA, identity, serial, validity, principals,
# critical options and extensions (each list sorted, "(none)" when empty).
cert::describe() { # <cert file>
	"$sshKeygen" -L -f "$1" | awk '
		function flush(name) { if (sec == name) { n = split(buf, arr, "\n"); out = ""
			for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (arr[j] < arr[i]) { t = arr[i]; arr[i] = arr[j]; arr[j] = t }
			for (i = 1; i <= n; i++) if (arr[i] != "") out = out (out ? "," : "") arr[i]
			val[name] = out ? out : "(none)"; buf = "" } }
		function section(name, rest) { flush(sec); sec = name; buf = ""; if (rest != "" && rest != "(none)") buf = rest }
		/^ *Type:/ { type = ($0 ~ /host certificate/) ? "host" : "user"; next }
		/^ *Public key:/ { key = $NF; next }
		/^ *Signing CA:/ { ca = $(NF - 2); next }
		/^ *Key ID:/ { sub(/^ *Key ID: /, ""); id = $0; next }
		/^ *Serial:/ { serial = $2; next }
		/^ *Valid:/ { sub(/^ *Valid: /, ""); valid = $0; next }
		/^ *Principals:/ { r = $0; sub(/^ *Principals: */, "", r); section("principals", r); next }
		/^ *Critical Options:/ { r = $0; sub(/^ *Critical Options: */, "", r); section("critical", r); next }
		/^ *Extensions:/ { r = $0; sub(/^ *Extensions: */, "", r); section("extensions", r); next }
		sec != "" { line = $0; gsub(/^ +| +$/, "", line); if (line != "") buf = buf (buf ? "\n" : "") line }
		END { flush(sec)
			print type "|" key "|" ca "|" id "|" serial "|" valid "|" val["principals"] "|" val["critical"] "|" val["extensions"] }'
}

# ssh-keygen's defaults, which a certificate signed here carries: no critical option, and for a user
# certificate the permit-* extensions. A recorded certificate with anything else (a force-command, a
# source-address) is stale, and re-signed.
cert::default_extensions() { # <usage>
	if [[ "$1" == ssh-host ]]; then
		echo "(none)"
	else
		echo "permit-X11-forwarding,permit-agent-forwarding,permit-port-forwarding,permit-pty,permit-user-rc" | tr ',' '\n' | sort | paste -sd, -
	fi
}

# The description a certificate signed now would have, to compare with the recorded one.
cert::expected() { # <key> <slot> <authority> <authority slot> <usage>
	local type keyFp caFp
	type="$([[ "$5" == ssh-host ]] && echo host || echo user)"
	keyFp="$(printf '%s %s\n' "$(yq::get ".keys.\"$1\".type")" "$(yq::get ".keys.\"$1\".slots.\"$2\".public")" | "$sshKeygen" -lf - | awk '{print $2}')"
	caFp="$(printf '%s %s\n' "$(yq::get ".authorities.\"$3\".type // \"ssh-ed25519\"")" "$(yq::get ".authorities.\"$3\".slots.\"$4\".public")" | "$sshKeygen" -lf - | awk '{print $2}')"
	printf '%s|%s|%s|"%s"|0|forever|%s|(none)|%s\n' "$type" "$keyFp" "$caFp" "$(cert::identity "$1" "$5")" \
		"$(cert::principals_for "$1" "$5")" "$(cert::default_extensions "$5")"
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
				# A slot whose public is not recorded holds material generated at activation, on each host:
				# there is nothing to sign here, so that host keeps signing it until its slot is recorded.
				if [[ -z "$(yq::get ".keys.\"${key}\".slots.\"${slot}\".public // \"\"")" ]]; then
					unrecorded+=("${key}	${slot}	${usage}")
					continue
				fi
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
	for line in ${unrecorded[@]+"${unrecorded[@]}"}; do
		IFS=$'\t' read -r key slot usage <<<"$line"
		printf '  unrecorded %-20s %-9s %-9s no public in keys.yaml: generated and signed at activation\n' "$key" "$slot" "$usage"
	done
	for line in ${plan[@]+"${plan[@]}"}; do
		IFS=$'\t' read -r key slot authority authSlot usage why <<<"$line"
		printf '  %-8s %-22s %-9s %-9s signed by %s@%s\n' "$why" "$key" "$slot" "$usage" "$authority" "$authSlot"
	done
	printf '\n'
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

# A tool that rewrites key material never changes who can read it. The re-encryption follows
# keys.yaml's own creation rule (the decrypted copy sits at its relative path — a temp path once
# matched the catch-all and dropped a recipient), and a recipient set that would still change —
# the rule and the committed envelope disagree — is refused: that is `sops updatekeys`, an
# explicit gesture of its own.
recipients::unchanged() { # <committed file> <re-encrypted file>
	local before after
	before="$(recipients::of "$1")"
	after="$(recipients::of "$2")"
	[[ "$before" == "$after" ]] && return 0
	log::error "keys.yaml's recipients would change: +[$(comm -13 <(tr ',' '\n' <<<"$before") <(tr ',' '\n' <<<"$after") | paste -sd, -)] -[$(comm -23 <(tr ',' '\n' <<<"$before") <(tr ',' '\n' <<<"$after") | paste -sd, -)]"
	log::error "keys.yaml left untouched — align its recipients with its creation rule first: sops updatekeys ${keysRel}"
	return 1
}

certify::one() { # <key> <slot> <authority> <authority slot> <usage>
	local key="$1" slot="$2" authority="$3" authSlot="$4" usage="$5"
	local authFile="${tmpdir}/authority-${authority}@${authSlot}"
	if [[ ! -s "$authFile" ]]; then
		(
			umask 077
			yq::get ".authorities.\"${authority}\".slots.\"${authSlot}\".private" >"$authFile"
		)
		chmod 400 "$authFile"
	fi
	local stem="${tmpdir}/${key}@${slot}-${usage}"
	printf '%s %s %s\n' "$(yq::get ".keys.\"${key}\".type")" "$(yq::get ".keys.\"${key}\".slots.\"${slot}\".public")" \
		"$(yq::get ".keys.\"${key}\".comment // \"${key}\"")" >"${stem}.pub"
	local -a args=(-q -s "$authFile" -I "$(cert::identity "$key" "$usage")" -n "$(cert::principals_for "$key" "$usage")")
	[[ "$usage" == ssh-host ]] && args+=(-h)
	# Every step is checked: the logger wrapper runs this script with errexit OFF, and an unchecked
	# failure once recorded EMPTY certificates as "signed".
	if ! "$sshKeygen" "${args[@]}" "${stem}.pub"; then
		log::error "ssh-keygen could not sign ${key}@${slot} ${usage}"
		return 1
	fi
	if [[ ! -s "${stem}-cert.pub" ]]; then
		log::error "no certificate was written for ${key}@${slot} ${usage}"
		return 1
	fi
	if ! CERT="$(<"${stem}-cert.pub")" yq eval -i \
		".keys.\"${key}\".slots.\"${slot}\".certificates.\"${authority}\".\"${usage}\" = strenv(CERT)" "$decrypted"; then
		log::error "cannot record the certificate of ${key}@${slot} ${usage}"
		return 1
	fi
	log::info "signed ${key}@${slot} ${usage} with ${authority}@${authSlot}"
}

certify::apply() {
	local line reencrypted
	for line in "${plan[@]}"; do
		IFS=$'\t' read -r key slot authority authSlot usage _ <<<"$line"
		certify::one "$key" "$slot" "$authority" "$authSlot" "$usage" || {
			log::error "keys.yaml left untouched"
			return 1
		}
	done
	reencrypted="${tmpdir}/keys.yaml.reenc"
	if ! (cd "${tmpdir}/repo" && sops --input-type yaml --output-type yaml encrypt "$keysRel") >"$reencrypted"; then
		log::error "sops encrypt failed; keys.yaml left untouched"
		return 1
	fi
	[[ -s "$reencrypted" ]] || {
		log::error "sops encrypt produced an empty file; keys.yaml left untouched"
		return 1
	}
	recipients::unchanged "$keysYaml" "$reencrypted" || return 1
	# Every private, of every key and authority, must still be ciphertext: a certificate is public
	# and travels in clear, nothing else may.
	if [[ "$(yq eval '[.keys[].slots[].private, .authorities[].slots[].private] | map(select(. != null)) | all_c(test("^ENC\["))' "$reencrypted")" != true ]]; then
		log::error "a private is NOT encrypted in the re-encrypted file; keys.yaml left untouched"
		return 1
	fi
	install -m 0644 "$reencrypted" "$keysYaml" || return 1
	cat <<-EOF

		${#plan[@]} certificate(s) recorded in keys.yaml.

		Next, in order:
		  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
		  2. commit the keys.yaml diff
		  3. the hosts install them once the enrichment reads recorded certificates (the next ndh
		     change of 6a part B); until then each activation still signs its own
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

	keysYaml="$(git rev-parse --show-toplevel)/${keysRel}"
	[[ -r "$keysYaml" ]] || {
		log::error "keys.yaml not readable at ${keysYaml} (run from the ndh repo root)"
		return 1
	}
	tmpdir="$(mktemp -d)"
	chmod 700 "$tmpdir"
	trap 'rm -rf "$tmpdir"' EXIT
	# The decrypted copy sits at keys.yaml's OWN relative path, beside a copy of the repository's
	# .sops.yaml: sops picks the creation rule by the path it encrypts (--filename-override does not
	# change that, measured with 3.13.3), so the re-encryption gets exactly keys.yaml's rule.
	install -d -m 0700 "${tmpdir}/repo/$(dirname "$keysRel")"
	cp "$(git rev-parse --show-toplevel)/.sops.yaml" "${tmpdir}/repo/.sops.yaml"
	decrypted="${tmpdir}/repo/${keysRel}"
	sops --input-type yaml --output-type yaml -d "$keysYaml" >"$decrypted"
	[[ -s "$decrypted" ]] || {
		log::error "sops -d produced an empty file (check SOPS_AGE_KEY_FILE / sops.age.keyFile)"
		return 1
	}

	plan::build || return 1
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
