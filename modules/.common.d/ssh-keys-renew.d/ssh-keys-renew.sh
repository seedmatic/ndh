#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset BASH_XTRACEFD 2>/dev/null || true
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
# --replace collapses both phases into one change, for a key whose private is
# EXPOSED: there, the overlap the two phases exist to provide is the risk itself,
# since it keeps the published generation accepted until phase 2.
#
# --create declares a NEW entry and generates its first slot in the same change: the
# schema requires one slot per entry, so an entry cannot be committed empty and filled
# later, and an entry with no slots at all is refused as one that predates the model.
#
# Usage:
#   ssh-keys-renew [--key NAME]... [--authority NAME]... [--older-than Nd]
#                  [--replace --reason TEXT] [--apply]
#   ssh-keys-renew --create NAME --usage TAG... [--profile NAME]... [--comment TEXT]
#                  [--type TYPE] [--apply]
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
# Authorities are renewed the same way. An authority signs with its OLDEST slot
# that is not compromised (keys.schema.yaml, authoritySlots), so a new generation
# signs nothing until phase 2 drops the old one — by which time every trust store
# carries it. An authority and its leaves may therefore renew together: the new
# leaf slot is signed by the generation every host already trusts.
#
# See docs/ssh-keys-renewal-spec.adoc.

# shellcheck disable=SC1091
source @nixBashTrampoline@

declare -g keysYaml tmpdir decrypted today apply olderThanDays replace reason
declare -g createName createComment createType
declare -ga selectKeys=() selectAuthorities=() plan=() refusals=()
declare -ga createUsages=() createProfiles=()

# ⚠️ stdout, NOT stderr — the opposite of the activation scripts' convention, and
# for a reason. ndh::logger:command:run redirects stderr into the logger sink and
# leaves stdout as "the wrapped command's contract", so an operator tool that
# logs to stderr prints nothing the operator can see: the plan, the refusals and
# the next steps all vanish into the syslog. Measured — the first run of this
# tool returned status 1 with an empty terminal.
#
# (The escape hatch, when you do need the stderr trace: ACTIVATION_LOG_FILE=<path>
# makes the logger tee it back to the console.)
log::info() { echo "[ssh-keys-renew][INFO] $*"; }
log::error() { echo "[ssh-keys-renew][ERROR] $*"; }

usage() {
	cat <<-EOF
		usage: ssh-keys-renew [--key NAME]... [--authority NAME]... [--older-than Nd]
		                      [--replace --reason TEXT] [--apply]
		       ssh-keys-renew --create NAME --usage TAG... [--profile NAME]...
		                      [--comment TEXT] [--type TYPE] [--apply]

		  --key NAME         Renew keys.<NAME>. Repeatable.
		  --authority NAME   Renew authorities.<NAME>. Repeatable. The new generation
		                     signs only once phase 2 drops the old one.
		  --older-than Nd    Select every entry whose newest slot is more than N days
		                     old. Reads the slot dates directly — there is no side
		                     table to keep in step, which is the free benefit of
		                     dating the slots.
		  --replace          No overlap: every existing slot of a selected entry is
		                     deleted AND written to revoked in the same change.
		                     For an EXPOSED private, where the overlap is the risk.
		  --reason TEXT      The reason recorded in each revoked entry. Required with
		                     --replace.
		  --create NAME      Declare keys.<NAME>, which must not exist, and generate its
		                     first slot. Needs at least one --usage.
		  --usage TAG        A usage of the new entry (keys.schema.yaml). Repeatable.
		  --profile NAME     A profile of the new entry. Repeatable; none means the key
		                     lands on no host and its consumer reads keys.yaml itself.
		  --comment TEXT     The new entry's comment (default: NAME).
		  --type TYPE        The new entry's key type (default: ssh-ed25519).
		  --apply            Actually generate and rewrite keys.yaml. Without it this
		                     prints the plan and changes nothing.

		Effect with --apply: adds a slot dated today to each selected entry, generates
		a keypair into it, re-encrypts keys.yaml in place. BOTH generations are then
		published; phase 2 removes the retiring one, by hand, after a positive check.
		With --replace, only the new generation is published.
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
	# enrichment's assertion refuses, and it would mean phase 2 was skipped. A
	# replacement retires every slot, so an in-flight renewal is no obstacle to it.
	if ((replace == 0)) && ((${#existing[@]} >= 2)); then
		refusals+=("${section}.${name}: a renewal is already in flight (${existing[*]}) — finish phase 2 first")
		return 0
	fi
	local slot
	for slot in "${existing[@]}"; do
		if [[ "$slot" == "$today" ]]; then
			refusals+=("${section}.${name}: slot ${today} already exists — renewing the same entry twice in one day is a symptom, not a case to support")
			return 0
		fi
		((replace == 1)) || continue
		# A slot without a public is generated at activation and never recorded:
		# there is nothing to revoke, so replacing it would only hide that.
		if [[ -z "$(yq eval -r ".${section}.\"${name}\".slots.\"${slot}\".public // \"\"" "$decrypted")" ]]; then
			refusals+=("${section}.${name}: slot ${slot} has no public — an entry generated at activation cannot be revoked, so it is not replaced")
			return 0
		fi
		if [[ "$(yq eval -r ".revoked // {} | has(\"${name}@${slot}\")" "$decrypted")" == "true" ]]; then
			refusals+=("${section}.${name}: revoked already holds ${name}@${slot}")
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

# A new entry: its name must be free and its type generable; the schema checks the rest
# (usage tags, profile names) when the result is validated, before the commit.
plan::consider_create() {
	if [[ "$(yq eval -r ".keys // {} | has(\"${createName}\")" "$decrypted")" == "true" ]]; then
		refusals+=("keys.${createName}: already exists — --create declares a new entry, --key renews one")
		return 0
	fi
	if ! keygen::args_for "$createType" >/dev/null; then
		refusals+=("keys.${createName}: unsupported type '${createType}'")
		return 0
	fi
	plan+=("keys	${createName}	${createType}	create")
	return 0
}

plan::build() {
	local name section newest age
	if [[ -n "$createName" ]]; then plan::consider_create; fi
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
			if [[ "$existing" == create ]]; then
				printf '%-13s %-24s %-22s %s\n' "$section" "$name" "$keyType" "${today} (new entry)"
			elif ((replace == 1)); then
				printf '%-13s %-24s %-22s %s\n' "$section" "$name" "$keyType" "${today} (revokes ${existing})"
			else
				printf '%-13s %-24s %-22s %s\n' "$section" "$name" "$keyType" "${existing} + ${today}"
			fi
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

# Declare the new entry's public fields; renew::one then generates its first slot.
create::declare() {
	local item
	log::info "declaring keys.${createName} (${createType})"
	TYPE="$createType" COMMENT="$createComment" yq eval -i "
		.keys.\"${createName}\".type = strenv(TYPE) |
		.keys.\"${createName}\".comment = strenv(COMMENT) |
		.keys.\"${createName}\".usage = [] |
		.keys.\"${createName}\".profiles = []
	" "$decrypted"
	for item in "${createUsages[@]}"; do
		ITEM="$item" yq eval -i ".keys.\"${createName}\".usage += [strenv(ITEM)]" "$decrypted"
	done
	for item in ${createProfiles[@]+"${createProfiles[@]}"}; do
		ITEM="$item" yq eval -i ".keys.\"${createName}\".profiles += [strenv(ITEM)]" "$decrypted"
	done
}

# Delete each retiring slot and write its `revoked` entry in the same document:
# the evaluation refuses a revoked public that a slot still carries, and a slot
# deleted without its entry stays valid wherever its public is still known.
renew::retire() { # <section> <name> <slot>...
	local section="$1" name="$2" slot
	shift 2
	for slot in "$@"; do
		log::info "retiring ${section}.${name} slot ${slot} into revoked"
		REASON="$reason" yq eval -i "
			.revoked.\"${name}@${slot}\".type   = .${section}.\"${name}\".type |
			.revoked.\"${name}@${slot}\".public = .${section}.\"${name}\".slots.\"${slot}\".public |
			.revoked.\"${name}@${slot}\".reason = strenv(REASON) |
			.revoked.\"${name}@${slot}\".compromised = true |
			.revoked.\"${name}@${slot}\".compromised = true |
			del(.${section}.\"${name}\".slots.\"${slot}\")
		" "$decrypted"
	done
}

renew::apply() {
	local line section name keyType existing reencrypted value
	local -a retiring

	for line in "${plan[@]}"; do
		IFS=$'\t' read -r section name keyType existing <<<"$line"
		if [[ "$existing" == create ]]; then create::declare; fi
		renew::one "$section" "$name" "$keyType"
		if ((replace == 1)) && [[ "$existing" != create ]]; then
			read -r -a retiring <<<"$existing"
			renew::retire "$section" "$name" "${retiring[@]}"
		fi
	done

	reencrypted="${tmpdir}/keys.yaml.reenc"
	sops --input-type yaml --output-type yaml encrypt "$decrypted" >"$reencrypted"
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

	if [[ -n "$createName" ]]; then
		cat <<-EOF

			keys.${createName} declared, with its first slot ${today}. A new entry has no
			phase 2: nothing trusted the generation before it.

			Next, in order:
			  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
			  2. commit the keys.yaml diff
			  3. activate the hosts whose profiles it names, if any
		EOF
		return 0
	fi

	if ((replace == 1)); then
		cat <<-EOF

			replacement written. Only the new generations are declared; the retired
			ones are in revoked.

			Next, in order:
			  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
			  2. commit the keys.yaml diff
			  3. activate EVERY host. There is no overlap: from its own activation on,
			     a host refuses the retired generation — activate it from a session
			     that does not depend on that generation.
		EOF
		return 0
	fi

	cat <<-EOF

		phase 1 written. Both generations are now declared.

		Next, in order:
		  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
		  2. commit the keys.yaml diff
		  3. activate EVERY host, and verify the new generation serves on each
		  4. phase 2, by hand: delete the retiring slot and activate again

		Phase 2 is not optional — while two slots exist, the document itself says
		the renewal is unfinished.
	EOF
}

main() {
	apply=0
	replace=0
	reason=""
	olderThanDays=""
	createName=""
	createComment=""
	createType=""

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
			--replace)
				replace=1
				shift
				;;
			--reason)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				reason="$2"
				shift 2
				;;
			--create)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				createName="$2"
				shift 2
				;;
			--usage)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				createUsages+=("$2")
				shift 2
				;;
			--profile)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				createProfiles+=("$2")
				shift 2
				;;
			--comment)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				createComment="$2"
				shift 2
				;;
			--type)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				createType="$2"
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

	if [[ -n "$createName" ]]; then
		# One gesture at a time: a creation mixed with renewals would apply both or
		# neither, and a replacement has nothing to revoke in a new entry.
		if ((${#selectKeys[@]} + ${#selectAuthorities[@]} > 0)) || [[ -n "$olderThanDays" ]] || ((replace == 1)); then
			log::error "--create stands alone: no --key, --authority, --older-than or --replace with it"
			usage
			return $?
		fi
		# The schema's key-name pattern (keys.patternProperties), checked here because the name
		# is spliced into yq expressions before anything validates the document.
		if [[ ! "$createName" =~ ^[a-z][a-z0-9-]*$ ]]; then
			log::error "--create ${createName@Q}: a key name is ^[a-z][a-z0-9-]*\$ (keys.schema.yaml)"
			usage
			return $?
		fi
		if ((${#createUsages[@]} == 0)); then
			log::error "--create needs at least one --usage: it is what the schema reads the key's role from"
			usage
			return $?
		fi
		[[ -n "$createComment" ]] || createComment="$createName"
		[[ -n "$createType" ]] || createType="ssh-ed25519"
	elif ((${#createUsages[@]} + ${#createProfiles[@]} > 0)) || [[ -n "$createComment$createType" ]]; then
		log::error "--usage, --profile, --comment and --type describe a new entry: they need --create"
		usage
		return $?
	elif ((${#selectKeys[@]} == 0)) && ((${#selectAuthorities[@]} == 0)) && [[ -z "$olderThanDays" ]]; then
		log::error "nothing selected — pass --key, --authority, --older-than or --create"
		usage
		return $?
	fi
	if ((replace == 1)) && [[ -z "$reason" ]]; then
		log::error "--replace needs --reason: it is what each revoked entry records"
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
	sops --input-type yaml --output-type yaml -d "$keysYaml" >"$decrypted"
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
