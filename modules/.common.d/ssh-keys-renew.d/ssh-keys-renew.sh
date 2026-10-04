#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ssh-keys-renew — phase 1 of an SSH key renewal in
# modules/home-manager/ssh.d/keys.yaml.
#
# This is the operator gesture the renewal model is built around. Key material is
# stable by default and renewed on request, so nothing here happens on a timer:
# a periodic job would renew things nobody is watching, and the two-phase rule
# needs a human to confirm phase 1 before phase 2.
#
#   phase 1 (this tool)   add a dated slot, generate into it, publish BOTH
#                         generations, activate, and verify the new one serves
#   phase 2 (by hand)     delete the retiring slot, and only after a POSITIVE
#                         check — otherwise the one path that worked is the one
#                         removed
#
# Usage:
#   ssh-keys-renew [--key NAME]... [--authority NAME]... [--older-than Nd] [--apply]
#
# Safe by default: nothing is generated and keys.yaml is not touched unless
# --apply is given. A tool that rewrites key material shows its work first.
#
# Base: the shared bash trampoline (nix-managed bash + logger + stable env).
# Nothing is pinned by store path: every tool this needs — sops, yq, ssh-keygen,
# git, and the coreutils behind date/mktemp/install/cut — is part of the bringup
# runtime profile's command contract, so the trampoline either provides them or
# refuses with an install hint. `date` there is GNU date on both platforms, which
# is what --older-than depends on.
#
# Why generation happens HERE and not by emptying a slot and letting activation
# fill it: the enrichment runs against the sops-DECRYPTED RUNTIME copy, which is
# rewritten from the encrypted source on every switch. Material generated there
# does not survive, so an empty slot in the source would be a DIFFERENT key after
# every activation — fatal for anything that identifies a host.
#
# Authorities are renewed the same way, and they must be renewed BEFORE their
# leaves: the enrichment refuses to sign without the authority's private key, and
# a leaf is only re-signed by the new authority once every host trusts it. That
# ordering is what makes one certificate per key generation sufficient.
#
# See docs/ssh-keys-renewal-spec.adoc.

# shellcheck disable=SC1091
source @nixBashTrampoline@

declare -g keysYaml tmpdir decrypted today apply olderThanDays
declare -ga selectKeys=() selectAuthorities=() plan=() refusals=()

log::info() { echo "[ssh-keys-renew][INFO] $*" >&2; }
log::error() { echo "[ssh-keys-renew][ERROR] $*" >&2; }

usage() {
	cat >&2 <<-EOF
		usage: ssh-keys-renew [--key NAME]... [--authority NAME]... [--older-than Nd] [--apply]

		  --key NAME         Renew keys.<NAME>. Repeatable.
		  --authority NAME   Renew authorities.<NAME>. Repeatable. Renew an authority
		                     BEFORE its leaves.
		  --older-than Nd    Select every entry whose newest slot is more than N days
		                     old. Reads the slot dates directly — there is no side
		                     table to keep in step, which is the free benefit of
		                     dating the slots.
		  --apply            Actually generate and rewrite keys.yaml. Without it this
		                     prints the plan and changes nothing.

		Effect with --apply: adds a slot dated today to each selected entry, generates
		a keypair into it, re-encrypts keys.yaml in place. BOTH generations are then
		published; phase 2 removes the retiring one, by hand, after a positive check.
	EOF
	return 64
}

# `ssh-keygen -t` takes its own names, not the SSH wire names the schema's enum
# uses. The mapping is total over that enum, so an unknown type is a schema
# violation and gets refused rather than guessed at.
keygen::args_for() { # <wire type>
	case "$1" in
		ssh-ed25519) printf '%s\n' "-t ed25519" ;;
		ssh-rsa) printf '%s\n' "-t rsa -b 4096" ;;
		ecdsa-sha2-nistp256) printf '%s\n' "-t ecdsa -b 256" ;;
		ecdsa-sha2-nistp384) printf '%s\n' "-t ecdsa -b 384" ;;
		ecdsa-sha2-nistp521) printf '%s\n' "-t ecdsa -b 521" ;;
		*) return 1 ;;
	esac
}

slot::list() { # <section> <name>
	yq eval -r ".${1}.\"${2}\".slots // {} | keys | sort | .[]" "$decrypted"
}

slot::newest() { # <section> <name>
	local -a slots
	mapfile -t slots < <(slot::list "$1" "$2")
	((${#slots[@]} > 0)) || return 1
	printf '%s\n' "${slots[-1]}"
}

slot::days_since() { # <YY-MM-DD>
	local created now
	created="$(date -d "20$1" +%s 2>/dev/null)" || return 1
	now="$(date +%s)"
	printf '%s\n' $(((now - created) / 86400))
}

entry::names_in() { # <section>
	yq eval -r ".${1} // {} | keys | .[]" "$decrypted"
}

plan::holds() { # <section> <name>
	local entry
	for entry in ${plan[@]+"${plan[@]}"}; do
		[[ "$entry" == "${1}	${2}	"* ]] && return 0
	done
	return 1
}

# Decide one entry's fate and record it in either `plan` or `refusals`. Every
# refusal names the entry and the reason, because the whole invocation is
# abandoned on any refusal and the operator needs to know which one.
plan::consider() { # <section> <name>
	local section="$1" name="$2"
	if [[ "$(yq eval -r ".${section} // {} | has(\"${name}\")" "$decrypted")" != "true" ]]; then
		refusals+=("${section}.${name}: no such entry in keys.yaml")
		return 0
	fi

	local -a existing
	mapfile -t existing < <(slot::list "$section" "$name")
	if ((${#existing[@]} == 0)); then
		refusals+=("${section}.${name}: no slots — the entry predates the renewal model")
		return 0
	fi
	# Two slots means a renewal is already in flight. A third is the state the
	# enrichment's assertion refuses, and it would mean phase 2 was skipped.
	if ((${#existing[@]} >= 2)); then
		refusals+=("${section}.${name}: a renewal is already in flight (${existing[*]}) — finish phase 2 first")
		return 0
	fi
	local slot
	for slot in "${existing[@]}"; do
		if [[ "$slot" == "$today" ]]; then
			refusals+=("${section}.${name}: slot ${today} already exists — renewing the same entry twice in one day is a symptom, not a case to support")
			return 0
		fi
	done

	local keyType
	keyType="$(yq eval -r ".${section}.\"${name}\".type // \"\"" "$decrypted")"
	if ! keygen::args_for "$keyType" >/dev/null; then
		refusals+=("${section}.${name}: unsupported type '${keyType}'")
		return 0
	fi

	plan+=("${section}	${name}	${keyType}	${existing[*]}")
	return 0
}

plan::build() {
	local name section newest age
	if ((${#selectKeys[@]} > 0)); then
		for name in "${selectKeys[@]}"; do plan::consider keys "$name"; done
	fi
	if ((${#selectAuthorities[@]} > 0)); then
		for name in "${selectAuthorities[@]}"; do plan::consider authorities "$name"; done
	fi

	[[ -n "$olderThanDays" ]] || return 0
	for section in authorities keys; do
		while IFS= read -r name; do
			[[ -n "$name" ]] || continue
			# Skip anything already named explicitly, so a mixed invocation does not
			# plan the same entry twice.
			if plan::holds "$section" "$name"; then continue; fi
			newest="$(slot::newest "$section" "$name" 2>/dev/null || true)"
			[[ -n "$newest" ]] || continue
			age="$(slot::days_since "$newest" 2>/dev/null || true)"
			[[ -n "$age" ]] || continue
			((age > olderThanDays)) || continue
			plan::consider "$section" "$name"
		done < <(entry::names_in "$section")
	done
}

plan::show() {
	local line section name keyType existing refusal
	cat <<-EOF

		keys.yaml   ${keysYaml}
		new slot    ${today}

	EOF

	if ((${#plan[@]} == 0)); then
		printf 'Nothing to renew.\n'
	else
		printf '%-13s %-24s %-22s %s\n' SECTION ENTRY TYPE 'SLOTS AFTER'
		for line in "${plan[@]}"; do
			IFS=$'\t' read -r section name keyType existing <<<"$line"
			printf '%-13s %-24s %-22s %s\n' "$section" "$name" "$keyType" "${existing} + ${today}"
		done
	fi

	if ((${#refusals[@]} > 0)); then
		printf '\nREFUSED\n'
		for refusal in "${refusals[@]}"; do printf '  %s\n' "$refusal"; done
	fi
	printf '\n'
}

# Generate one entry's new generation and write it into the decrypted document.
renew::one() { # <section> <name> <keyType>
	local section="$1" name="$2" keyType="$3"
	local comment out pub priv
	local -a keygenArgs

	comment="$(yq eval -r ".${section}.\"${name}\".comment // \"${name}\"" "$decrypted")"
	read -r -a keygenArgs <<<"$(keygen::args_for "$keyType")"

	out="${tmpdir}/${section}-${name}"
	ssh-keygen -q "${keygenArgs[@]}" -N "" -f "$out" -C "$comment"

	# `public` is the BARE base64 blob — the type is in `type:` and the comment in
	# `comment:`, and consumers rebuild the line from the three. Writing a whole
	# line here doubles both in every rebuilt line, and the schema refuses it.
	pub="$(cut -d' ' -f2 <"${out}.pub")"
	priv="$(<"$out")"

	log::info "generating ${section}.${name} slot ${today} (${keyType})"
	PUB="$pub" PRIV="$priv" yq eval -i "
		.${section}.\"${name}\".slots.\"${today}\".public  = strenv(PUB) |
		.${section}.\"${name}\".slots.\"${today}\".private = strenv(PRIV)
	" "$decrypted"

	# ⛔ NOT optional. sops encrypts by `encrypted_comment_regex: 'sops:encrypted'`,
	# so a private without this comment is committed IN THE CLEAR — which is
	# exactly how eight private keys reached a public repository. Verified again on
	# the re-encrypted file, because a comment that silently failed to attach would
	# otherwise stay invisible until the commit.
	yq eval -i \
		"(.${section}.\"${name}\".slots.\"${today}\".private | key) headComment = \"sops:encrypted\"" \
		"$decrypted"
}

renew::apply() {
	local line section name keyType reencrypted value

	for line in "${plan[@]}"; do
		IFS=$'\t' read -r section name keyType _ <<<"$line"
		renew::one "$section" "$name" "$keyType"
	done

	reencrypted="${tmpdir}/keys.yaml.reenc"
	"$SOPS" --input-type yaml --output-type yaml encrypt "$decrypted" >"$reencrypted"
	if [[ ! -s "$reencrypted" ]]; then
		log::error "sops encrypt produced an empty file; keys.yaml left untouched"
		return 1
	fi

	for line in "${plan[@]}"; do
		IFS=$'\t' read -r section name _ _ <<<"$line"
		value="$(yq eval -r ".${section}.\"${name}\".slots.\"${today}\".private" "$reencrypted")"
		case "$value" in
			ENC\[*) ;;
			*)
				log::error "${section}.${name} slot ${today}: private is NOT encrypted in the re-encrypted file"
				log::error "keys.yaml left untouched — the sops:encrypted comment did not take effect"
				return 1
				;;
		esac
	done

	install -m 0644 "$reencrypted" "$keysYaml"

	cat >&2 <<-EOF

		phase 1 written. Both generations are now declared.

		Next, in order:
		  1. nix run .#ssh-keys-v2-validate
		  2. commit the keys.yaml diff
		  3. activate EVERY host, and verify the new generation serves on each
		  4. phase 2, by hand: delete the retiring slot and activate again

		Phase 2 is not optional — while two slots exist, the document itself says
		the renewal is unfinished.
	EOF
}

main() {
	apply=0
	olderThanDays=""

	while (($# > 0)); do
		case "$1" in
			--key)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				selectKeys+=("$2")
				shift 2
				;;
			--authority)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				selectAuthorities+=("$2")
				shift 2
				;;
			--older-than)
				if [[ ! "${2:-}" =~ ^([0-9]+)d$ ]]; then
					usage
					return $?
				fi
				olderThanDays="${BASH_REMATCH[1]}"
				shift 2
				;;
			--apply)
				apply=1
				shift
				;;
			-h | --help)
				usage
				return $?
				;;
			*)
				log::error "unknown argument: $1"
				usage
				return $?
				;;
		esac
	done

	if ((${#selectKeys[@]} == 0)) && ((${#selectAuthorities[@]} == 0)) && [[ -z "$olderThanDays" ]]; then
		log::error "nothing selected — pass --key, --authority or --older-than"
		usage
		return $?
	fi

	# Packaged as a flake app, so $0 is a /nix/store path — resolve the repo from
	# the invocation cwd instead (run from the ndh repo root).
	keysYaml="$(git rev-parse --show-toplevel)/modules/home-manager/ssh.d/keys.yaml"
	if [[ ! -r "$keysYaml" ]]; then
		log::error "keys.yaml not readable at ${keysYaml} (run from the ndh repo root)"
		return 1
	fi

	tmpdir="$(mktemp -d)"
	chmod 700 "$tmpdir"
	trap 'rm -rf "$tmpdir"' EXIT

	decrypted="${tmpdir}/keys.yaml"
	"$SOPS" --input-type yaml --output-type yaml -d "$keysYaml" >"$decrypted"
	if [[ ! -s "$decrypted" ]]; then
		log::error "sops -d produced an empty file (check SOPS_AGE_KEY_FILE / sops.age.keyFile)"
		return 1
	fi

	today="$(date +%y-%m-%d)"

	plan::build
	plan::show

	if ((${#refusals[@]} > 0)); then
		# Refusing the whole invocation rather than applying the healthy part: a
		# partially applied renewal is the state nobody can reason about afterwards.
		log::error "nothing applied — resolve the refusals above, or narrow the selection"
		return 1
	fi
	if ((apply == 0)); then
		log::info "dry run — pass --apply to generate and rewrite keys.yaml"
		return 0
	fi
	if ((${#plan[@]} == 0)); then
		return 0
	fi

	renew::apply
}

ndh::logger:command:run "@loggerTag@" main "$@"
