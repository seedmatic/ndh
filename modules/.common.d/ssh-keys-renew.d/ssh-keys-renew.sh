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
# --replace collapses both phases into one change, for a key whose private is
# EXPOSED: there, the overlap the two phases exist to provide is the risk itself,
# since it keeps the published generation accepted until phase 2.
#
# --create declares a NEW entry and generates its first slot in the same change: the
# schema requires one slot per entry, so an entry cannot be committed empty and filled
# later, and an entry with no slots at all is refused as one that predates the model.
#
# --create host-<machine> --public - --usage ssh-host RECORDS a machine's host key instead of
# generating one: its private lives in the operator's keyring only (ndh-keyring host-key <machine>
# prints the public), so the slot holds the public and nothing else. The evaluation then refuses the
# uncertified public until ssh-keys-certify signs it, which is meant: both land in one commit.
#
# --create sshfs-<guest> --public - --usage ssh-user records, the same way, the key a NixOS guest mounts
# its operator seat's git stores with (ndh-keyring sshfs-key <guest>). It gets NO certificate: the seat
# authorizes it by an authorized_keys line generated from this public (modules/darwin/openssh.nix), on
# that one seat and with that one forced command, which a certificate cannot scope as narrowly — its
# principal would be honored by every sshd trusting the authority, and nothing would revoke it but a KRL.
#
# --create vz-recover-<host> --public - --usage ssh-user records, the same way and for the same reason, the
# key the sessions recover a foreign vz-host's VMs with (ndh-keyring vz-recover-key <host>): that vz-host's
# account authorizes it by a line the operator places, forcing ndh-vz-recover.
#
# --record-nix-signing host-<machine> --public - records the nix signing public derived from that machine's
# host key (ndh-keyring nix-signing-public <machine>, roles × keys B2) as its newest slot's `nixSigning`, with
# `sops set` and nothing decrypted, like the revocation below. A new host-key slot records a new one.
#
# --revoke-certificate KEY@SLOT --from-revision REV records the revocation of ONE host certificate, a
# gesture of its own (roles × keys S3a, decided 2026-10-16): the union host certificate, once every
# machine serves its own. Its key stays valid; the KRL cuts that certificate alone, by the exact key id
# read back from the revision that recorded it. Certificates are public and in clear in keys.yaml, so
# nothing is decrypted: the revision is read as committed, and the entry is written with `sops set`,
# which leaves every other value, ciphertexts included, byte for byte.
#
# Usage:
#   ssh-keys-renew [--key NAME]... [--authority NAME]... [--older-than Nd]
#                  [--replace --reason TEXT] [--apply]
#   ssh-keys-renew --create NAME --usage TAG... [--profile NAME]... [--comment TEXT]
#                  [--type TYPE] [--apply]
#   ndh-keyring host-key MACHINE | ssh-keys-renew --create host-MACHINE --public - --usage ssh-host
#                  [--comment TEXT] [--apply]
#   ndh-keyring sshfs-key GUEST | ssh-keys-renew --create sshfs-GUEST --public - --usage ssh-user
#                  [--comment TEXT] [--apply]
#   ndh-keyring vz-recover-key HOST | ssh-keys-renew --create vz-recover-HOST --public - --usage ssh-user
#                  [--comment TEXT] [--apply]
#   ssh-keys-renew --revoke-certificate KEY@SLOT --from-revision REV --reason TEXT [--apply]
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

# None of these tools comes from the caller's shell, nor does the locale: the PATH is this package's store
# paths, then the system's own directories (logger), and LC_ALL is C, whatever the caller's PATH, LANG or
# POSIXLY_CORRECT (which makes awk compare strings by collation). What they print is compared and signed.
PATH="@toolPath@:/usr/bin:/bin"
export PATH LC_ALL=C
unset POSIXLY_CORRECT GREP_OPTIONS

# keys.yaml relative to the repository root: the real file, and the copy whose path picks its sops rule.
readonly keysRel="modules/home-manager/ssh.d/keys.yaml"
# keys.yaml's public view for nix, keys.json, rewritten whenever keys.yaml is (keys-yaml.d/public.yq).
readonly keysJson="@keysJson@"
declare -g keysYaml tmpdir decrypted today apply olderThanDays replace reason
declare -g createName createComment createType createPublic createPublicBlob
declare -g revokeTarget revokeRevision
declare -ga selectKeys=() selectAuthorities=() plan=() refusals=()
declare -ga createUsages=() createProfiles=() machines=() guests=() vzHosts=()
# The machines a host key is recorded for, the NixOS guests an sshfs key is and the foreign vz-hosts a
# vz-recover key is, fixed at evaluation from the inventory.
IFS=' ' read -r -a machines <<<"@machines@"
IFS=' ' read -r -a guests <<<"@guests@"
IFS=' ' read -r -a vzHosts <<<"@vzHosts@"

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
		       ndh-keyring host-key MACHINE |
		         ssh-keys-renew --create host-MACHINE --public - --usage ssh-host
		                      [--comment TEXT] [--apply]
		       ndh-keyring sshfs-key GUEST |
		         ssh-keys-renew --create sshfs-GUEST --public - --usage ssh-user
		                      [--comment TEXT] [--apply]
		       ndh-keyring vz-recover-key HOST |
		         ssh-keys-renew --create vz-recover-HOST --public - --usage ssh-user
		                      [--comment TEXT] [--apply]
		       ssh-keys-renew --revoke-certificate KEY@SLOT --from-revision REV
		                      --reason TEXT [--apply]
		       ndh-keyring nix-signing-public MACHINE |
		         ssh-keys-renew --record-nix-signing host-MACHINE --public - [--apply]

		  --key NAME        Renew keys.<NAME>. Repeatable.
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
		                     --replace and --revoke-certificate.
		  --create NAME      Declare keys.<NAME>, which must not exist, and generate its
		                     first slot. Needs at least one --usage.
		  --usage TAG        A usage of the new entry (keys.schema.yaml). Repeatable.
		  --profile NAME     A profile of the new entry. Repeatable; none means the key
		                     lands on no host and its consumer reads keys.yaml itself.
		  --comment TEXT     The new entry's comment (default: NAME).
		  --type TYPE        The new entry's key type (default: ssh-ed25519).
		  --public -         Record the ONE ssh-ed25519 public line read from stdin instead of
		                     generating, a key whose private stays in the keyring: a
		                     machine's host key, with --create host-MACHINE (${machines[*]})
		                     and --usage ssh-host, then ssh-keys-certify before committing;
		                     or a NixOS guest's sshfs key, with --create sshfs-GUEST
		                     (${guests[*]}) and --usage ssh-user, never certified;
		                     or a foreign vz-host's vz-recover key, with --create
		                     vz-recover-HOST (${vzHosts[*]}) and --usage ssh-user, never
		                     certified.
		  --revoke-certificate KEY@SLOT
		                     Record in revoked_certificates the ssh-host certificate
		                     keys.KEY.slots.SLOT carried at --from-revision, by its exact
		                     key id: the KRL cuts that certificate, never its key. Refused
		                     while keys.yaml still records it (or its id). Decrypts nothing.
		  --from-revision REV
		                     The commit whose keys.yaml recorded the certificate.
		  --record-nix-signing host-MACHINE
		                     Record, with --public -, the nix signing public derived from that
		                     machine's host key (seedmatic-MACHINE-N:<base64>) in its newest slot,
		                     as nixSigning. Refused if that slot already has one, or if it equals
		                     the host key. Decrypts nothing.
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

slot::list() { # <section> <name>: the slots a renewal works on; a pending or retired one is not (roles × keys K5+)
	yq eval -r ".${1}.\"${2}\".slots // {} | with_entries(select((.value.state // \"\") != \"pending\" and (.value.state // \"\") != \"retired\")) | keys | sort | .[]" "$decrypted"
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
	if ((createPublic == 0)); then
		plan+=("keys	${createName}	${createType}	create")
		return 0
	fi
	# One key per role: a public some slot already carries, or that revoked holds, would make two
	# identities one, or bring a retired one back.
	if [[ "$(BLOB="$createPublicBlob" yq eval -r '[(.keys // {}, .authorities // {})[] | .slots // {} | .[] | .public // ""] + [(.revoked // {})[] | .public // ""] | any_c(. == strenv(BLOB))' "$decrypted")" == "true" ]]; then
		refusals+=("keys.${createName}: this public is already in keys.yaml (a slot or revoked) — a recorded key holds one role")
		return 0
	fi
	if [[ "$createName" == sshfs-* || "$createName" == vz-recover-* ]]; then
		plan+=("keys	${createName}	${createType}	record")
		return 0
	fi
	local authority
	if ! authority="$(authority::ssh_host)"; then
		refusals+=("keys.${createName}: no single SSH authority signs the host certificates in keys.yaml — nothing to record it under")
		return 0
	fi
	plan+=("keys	${createName}	${createType}	record	${authority}")
	return 0
}

# The authority host certificates are signed by today: the one named by every key whose cert_usage
# includes ssh-host, and it must advertise ssh-authority (keys.schema.yaml). Read from the document,
# never assumed, so a recorded host key is certified exactly like the ones it joins.
authority::ssh_host() {
	local -a found
	mapfile -t found < <(yq eval -r '[(.keys // {})[] | select((.cert_usage // []) | any_c(. == "ssh-host")) | .authority // ""] | unique | .[]' "$decrypted")
	((${#found[@]} == 1)) && [[ -n "${found[0]}" ]] || return 1
	[[ "$(yq eval -r ".authorities.\"${found[0]}\".usage // [] | any_c(. == \"ssh-authority\")" "$decrypted")" == "true" ]] || return 1
	printf '%s\n' "${found[0]}"
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
	local line section name keyType existing authority refusal
	cat <<-EOF

		keys.yaml   ${keysYaml}
		new slot    ${today}

	EOF

	if ((${#plan[@]} == 0)); then
		printf 'Nothing to renew.\n'
	else
		printf '%-13s %-24s %-22s %s\n' SECTION ENTRY TYPE 'SLOTS AFTER'
		for line in "${plan[@]}"; do
			IFS=$'\t' read -r section name keyType existing authority <<<"$line"
			if [[ "$existing" == create ]]; then
				printf '%-13s %-24s %-22s %s\n' "$section" "$name" "$keyType" "${today} (new entry)"
			elif [[ "$existing" == record && -z "$authority" ]]; then
				printf '%-13s %-24s %-22s %s\n' "$section" "$name" "$keyType" "${today} (new entry, public only, no certificate)"
			elif [[ "$existing" == record ]]; then
				printf '%-13s %-24s %-22s %s\n' "$section" "$name" "$keyType" "${today} (new entry, public only, under ${authority})"
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
	# Checked: the logger wrapper runs this script with errexit OFF.
	if ! ssh-keygen -q "${keygenArgs[@]}" -N "" -f "$out" -C "$comment"; then
		log::error "ssh-keygen could not generate ${section}.${name}"
		return 1
	fi

	# `public` is the BARE base64 blob — the type is in `type:` and the comment in
	# `comment:`, and consumers rebuild the line from the three. Writing a whole
	# line here doubles both in every rebuilt line, and the schema refuses it.
	pub="$(cut -d' ' -f2 <"${out}.pub")"

	log::info "generating ${section}.${name} slot ${today} (${keyType})"
	ndh::secret:begin "the new private is written into the decrypted document"
	priv="$(<"$out")"
	PUB="$pub" PRIV="$priv" yq eval -i "
		.${section}.\"${name}\".slots.\"${today}\".public  = strenv(PUB) |
		.${section}.\"${name}\".slots.\"${today}\".private = strenv(PRIV)
	" "$decrypted"
	priv=""
	ndh::secret:end

	# ⛔ NOT optional. sops encrypts by `encrypted_comment_regex: 'sops:encrypted'`,
	# so a private without this comment is committed IN THE CLEAR — which is
	# exactly how eight private keys reached a public repository. Verified again on
	# the re-encrypted file, because a comment that silently failed to attach would
	# otherwise stay invisible until the commit.
	yq eval -i \
		"(.${section}.\"${name}\".slots.\"${today}\".private | key) headComment = \"sops:encrypted\"" \
		"$decrypted"
}

# Record a key held in the keyring: the public in clear, no private, and no certificate (a host key's
# comes from ssh-keys-certify).
record::one() { # <name>
	log::info "recording keys.${1} slot ${today} (public only)"
	PUB="$createPublicBlob" yq eval -i ".keys.\"${1}\".slots.\"${today}\".public = strenv(PUB)" "$decrypted"
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

# Declare the new entry's public fields; renew::one then generates its first slot, or record::one
# records it.
create::declare() { # [authority]
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
	[[ -n "${1:-}" ]] || return 0
	AUTHORITY="$1" yq eval -i "
		.keys.\"${createName}\".authority = strenv(AUTHORITY) |
		.keys.\"${createName}\".cert_usage = [\"ssh-host\"]
	" "$decrypted"
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
	local line section name keyType existing authority slot reencrypted value
	local -a retiring

	for line in "${plan[@]}"; do
		IFS=$'\t' read -r section name keyType existing authority <<<"$line"
		if [[ "$existing" == record ]]; then
			create::declare "$authority" || return 1
			record::one "$name" || return 1
			continue
		fi
		if [[ "$existing" == create ]]; then create::declare || return 1; fi
		renew::one "$section" "$name" "$keyType" || return 1
		if ((replace == 1)) && [[ "$existing" != create ]]; then
			read -r -a retiring <<<"$existing"
			renew::retire "$section" "$name" "${retiring[@]}"
		fi
	done

	reencrypted="${tmpdir}/keys.yaml.reenc"
	if ! (cd "${tmpdir}/repo" && sops --input-type yaml --output-type yaml encrypt "$keysRel") >"$reencrypted"; then
		log::error "sops encrypt failed; keys.yaml left untouched"
		return 1
	fi
	if [[ ! -s "$reencrypted" ]]; then
		log::error "sops encrypt produced an empty file; keys.yaml left untouched"
		return 1
	fi
	recipients::unchanged "$keysYaml" "$reencrypted" || return 1

	for line in "${plan[@]}"; do
		IFS=$'\t' read -r section name _ existing _ <<<"$line"
		if [[ "$existing" == record ]]; then
			slot=".${section}.\"${name}\".slots.\"${today}\""
			if [[ "$(yq eval -r "(${slot}.public == \"${createPublicBlob}\") and ((${slot} | keys | join(\",\")) == \"public\")" "$reencrypted")" != true ]]; then
				log::error "${section}.${name} slot ${today}: not exactly the public, in clear, in the re-encrypted file"
				log::error "keys.yaml left untouched"
				return 1
			fi
			continue
		fi
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

	install -m 0644 "$reencrypted" "$keysYaml" || return 1

	"$keysJson" "$keysYaml" || return 1

	if ((createPublic == 1)) && [[ "$createName" == sshfs-* ]]; then
		cat <<-EOF

			keys.${createName} recorded: slot ${today} holds its public only, the private stays in
			the keyring. It is never certified: ${createName#sshfs-}'s operator seat authorizes it, read-only.

			Next, in order:
			  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
			  2. commit the keys.yaml diff, then switch the operator seat (it authorizes the key)
			  3. the key reaches ${createName#sshfs-} only as a key born there (K3, ops next): nothing places it
		EOF
		return 0
	fi

	if ((createPublic == 1)) && [[ "$createName" == vz-recover-* ]]; then
		cat <<-EOF

			keys.${createName} recorded: slot ${today} holds its public only, the private stays in
			the keyring and at ~/.ssh/vz-recover. It is never certified: ${createName#vz-recover-}'s vz-host
			account authorizes it, forcing ndh-vz-recover.

			Next, in order:
			  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
			  2. commit the keys.yaml diff
			  3. on the vz-host: nix profile install the pushed revision's ${createName#vz-recover-}-vz-recover, then place
			     the line ndh-keyring printed in that account's ~/.ssh/authorized_keys, by hand
			  4. ssh vzrecover.${createName#vz-recover-} list
		EOF
		return 0
	fi

	if ((createPublic == 1)); then
		cat <<-EOF

			keys.${createName} recorded: slot ${today} holds its public only, the private stays in
			the keyring. The evaluation refuses it until it is certified.

			Next, in order, BEFORE committing:
			  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-certify" -- --apply
			  2. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
			  3. commit the keys.yaml diff: the public and its certificate together
		EOF
		return 0
	fi

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

# A recorded key is ed25519, on no profile (keys.yaml carries no installation for it), of one role: a machine's host key (host-MACHINE, ssh-host), a NixOS guest's sshfs key
# (sshfs-GUEST, ssh-user), or a foreign vz-host's vz-recover key (vz-recover-HOST, ssh-user).
public::check_record() {
	local name role usageTag prefix placeholder
	local -a allowed
	case "$createName" in
		sshfs-*) role="an sshfs key" usageTag=ssh-user prefix=sshfs- placeholder=GUEST allowed=("${guests[@]}") ;;
		vz-recover-*) role="a vz-recover key" usageTag=ssh-user prefix=vz-recover- placeholder=HOST allowed=("${vzHosts[@]}") ;;
		*) role="a host key" usageTag=ssh-host prefix=host- placeholder=MACHINE allowed=("${machines[@]}") ;;
	esac
	if [[ "${createUsages[*]}" != "$usageTag" ]]; then
		log::error "--public records ${role}: its one --usage is ${usageTag}"
		usage
		return $?
	fi
	if ((${#createProfiles[@]} > 0)) || [[ -n "$createType" ]]; then
		log::error "--public takes no --profile and no --type: ${role} is ssh-ed25519 and lands on no profile"
		usage
		return $?
	fi
	for name in "${allowed[@]}"; do
		[[ "$createName" == "${prefix}${name}" ]] && return 0
	done
	log::error "--create ${createName@Q} --public: the name is ${prefix}${placeholder}, ${placeholder} one of: ${allowed[*]}"
	usage
	return $?
}

# Exactly one `ssh-ed25519 <blob> [comment]` line from stdin into createPublicBlob. Nothing read is
# ever printed: a mistaken pipe may carry a private.
public::read() {
	local input type blob rest bits refused=""
	ndh::secret:begin "stdin is read: a mistaken pipe may carry a private"
	input="$(cat)"
	if [[ "$input" == *"PRIVATE KEY"* ]]; then
		refused=private
	elif [[ -z "$input" || "$input" == *$'\n'* ]]; then
		refused=lines
	else
		read -r type blob rest <<<"$input"
	fi
	input=""
	ndh::secret:end
	if [[ "$refused" == private ]]; then
		log::error "stdin holds a PRIVATE key — refused, and not printed: pipe the public only (ndh-keyring prints it)"
		return 1
	fi
	if [[ "$refused" == lines ]]; then
		log::error "--public - reads exactly ONE line from stdin: ssh-ed25519 <blob> [comment]"
		return 1
	fi
	if [[ "$type" != ssh-ed25519 || ! "$blob" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
		log::error "stdin is not an ssh-ed25519 public line — a recorded key is ed25519 only"
		return 1
	fi
	# Checked by ssh-keygen, not by shape: the blob must decode to an ed25519 public key.
	if ! bits="$(printf '%s %s\n' "$type" "$blob" | ssh-keygen -l -f - 2>/dev/null)" || [[ "$bits" != *"(ED25519)" ]]; then
		log::error "stdin is not a valid ssh-ed25519 public key (ssh-keygen -l refused it)"
		return 1
	fi
	createPublicBlob="$blob"
}

# What `ssh-keygen -L` reads in a certificate, tab-separated: type, serial, signing CA fingerprint, key
# id. The id keeps its inner quotes (it is JSON); only the pair ssh-keygen wraps it in goes.
revoke::describe() { # <certificate line>
	printf '%s\n' "$1" | ssh-keygen -L -f - | awk '
		/^ *Type:/ { type = ($0 ~ /host certificate/) ? "host" : "user" }
		/^ *Key ID:/ { sub(/^ *Key ID: "/, ""); sub(/"$/, ""); id = $0 }
		/^ *Serial:/ { serial = $2 }
		/^ *Signing CA:/ { if (match($0, /SHA256:[A-Za-z0-9+\/]+/)) ca = substr($0, RSTART, RLENGTH) }
		END { print type "\t" serial "\t" ca "\t" id }'
}

# The slot of <authority> whose public signed a certificate, in keys.yaml as it is now: the KRL revokes
# the id under that public.
revoke::authority_slot() { # <authority> <CA fingerprint>
	local slot type public
	type="$(yq eval -r ".authorities.\"$1\".type // \"ssh-ed25519\"" "$keysYaml")"
	while IFS= read -r slot; do
		[[ -n "$slot" ]] || continue
		public="$(yq eval -r ".authorities.\"$1\".slots.\"${slot}\".public // \"\"" "$keysYaml")"
		[[ -n "$public" ]] || continue
		if [[ "$(printf '%s %s\n' "$type" "$public" | ssh-keygen -lf - | awk '{print $2}')" == "$2" ]]; then
			printf '%s\n' "$slot"
			return 0
		fi
	done < <(yq eval -r ".authorities.\"$1\".slots // {} | keys | .[]" "$keysYaml")
	return 1
}

# keys.yaml with one revoked_certificates entry left out, as compared JSON: what `sops set` must not
# have changed.
revoke::rest() { # <file> <entry name>
	N="$2" yq eval -o json --indent=0 'del(.sops) | .revoked_certificates |= ((. // {}) | del(.[strenv(N)]))' "$1"
}

# Record the revocation of the ssh-host certificate keys.<key>.slots.<slot> carried at the revision.
revoke::run() {
	local key="${revokeTarget%@*}" slot="${revokeTarget#*@}"
	local sha atRev authority cert type serial ca id where live liveId authSlot name entry updated
	if ! sha="$(git rev-parse --verify --quiet "${revokeRevision}^{commit}")"; then
		log::error "--from-revision ${revokeRevision@Q}: no such commit"
		return 1
	fi
	atRev="${tmpdir}/keys-at-revision.yaml"
	if ! git show "${sha}:${keysRel}" >"$atRev" 2>/dev/null; then
		log::error "${sha}: no ${keysRel} in that commit"
		return 1
	fi
	authority="$(yq eval -r ".keys.\"${key}\".authority // \"\"" "$atRev")"
	cert="$(yq eval -r ".keys.\"${key}\".slots.\"${slot}\".certificates.\"${authority}\".\"ssh-host\" // \"\"" "$atRev")"
	if [[ -z "$authority" || -z "$cert" ]]; then
		log::error "${sha}: keys.${key}.slots.${slot} records no ssh-host certificate in that revision"
		return 1
	fi
	IFS=$'\t' read -r type serial ca id < <(revoke::describe "$cert") || true
	if [[ "$type" != host || ! "$serial" =~ ^[0-9]+$ || -z "$ca" || -z "$id" ]]; then
		log::error "${sha}: keys.${key}.slots.${slot}'s ssh-host certificate is not a readable host certificate"
		return 1
	fi

	# A certificate keys.yaml still records is one a host still serves: revoking it would cut that host.
	while IFS=$'\t' read -r where live; do
		[[ -n "$live" ]] || continue
		IFS=$'\t' read -r _ _ _ liveId < <(revoke::describe "$live") || true
		if [[ "$live" == "$cert" || "$liveId" == "$id" ]]; then
			log::error "keys.yaml still records $([[ "$live" == "$cert" ]] && echo "this certificate" || echo "a certificate with its key id") (${where})"
			log::error "re-sign it first (ssh-keys-certify --apply), commit, switch every host, then revoke"
			return 1
		fi
	done < <(yq eval -r '(.keys // {}) | to_entries[] | .key as $k | (.value.slots // {}) | to_entries[] | .key as $s | (.value.certificates // {}) | to_entries[] | .key as $a | .value | to_entries[] | select(.value | tag == "!!str") | ($k + "@" + $s + " " + $a + " " + .key) + "\t" + .value' "$keysYaml")

	name="${key}@${slot}/${serial}"
	if [[ "$(N="$name" I="$id" yq eval -r '(.revoked_certificates // {}) | has(strenv(N)) or ([.[] | .key_id] | any_c(. == strenv(I)))' "$keysYaml")" == true ]]; then
		log::error "revoked_certificates already holds ${name}, or this key id"
		return 1
	fi
	if ! authSlot="$(revoke::authority_slot "$authority" "$ca")"; then
		log::error "its signing CA (${ca}) is no slot of authorities.${authority} in keys.yaml — if that slot is in revoked, every certificate it signed is already cut"
		return 1
	fi

	cat <<-EOF

		keys.yaml     ${keysYaml}
		revoke        revoked_certificates.${name}
		  recorded    keys.${key}.slots.${slot}.certificates.${authority}.ssh-host at ${sha}
		  key id      ${id}
		  serial      ${serial}
		  signed by   ${authority}@${authSlot}
		  reason      ${reason}

	EOF
	if ((apply == 0)); then
		log::info "dry run — pass --apply to record it in keys.yaml"
		return 0
	fi

	entry="$(A="$authority" S="$authSlot" I="$id" N="$serial" R="$sha" W="$reason" yq eval -n -o json --indent=0 \
		'{"authority": strenv(A), "authority_slot": strenv(S), "key_id": strenv(I), "serial": env(N), "revision": strenv(R), "reason": strenv(W)}')"
	# .yaml: sops set reads the format from the extension.
	updated="${tmpdir}/keys.revoked.yaml"
	cp "$keysYaml" "$updated"
	if ! sops set "$updated" "[\"revoked_certificates\"][\"${name}\"]" "$entry"; then
		log::error "sops set failed; keys.yaml left untouched"
		return 1
	fi
	if [[ "$(revoke::rest "$updated" "$name")" != "$(revoke::rest "$keysYaml" "$name")" ]]; then
		log::error "sops set changed more than revoked_certificates.${name}; keys.yaml left untouched"
		return 1
	fi
	if [[ "$(N="$name" yq eval -o json --indent=0 '.revoked_certificates[strenv(N)]' "$updated")" != "$entry" ]]; then
		log::error "revoked_certificates.${name} does not read back in clear, as given; keys.yaml left untouched"
		return 1
	fi
	install -m 0644 "$updated" "$keysYaml" || return 1
	"$keysJson" "$keysYaml" || return 1
	cat <<-EOF

		revoked_certificates.${name} recorded: the KRL cuts that certificate by its key id, and its
		key stays valid.

		Next, in order:
		  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
		  2. commit the keys.yaml diff
		  3. switch every host: sshd and every client, root's included, refuse it from their activation on
	EOF
}

# keys.yaml with one slot's nixSigning left out, as compared JSON: what `sops set` must not have changed.
nixsign::rest() { # <file> <key> <slot>
	K="$2" S="$3" yq eval -o json --indent=0 'del(.sops) | del(.keys[strenv(K)].slots[strenv(S)].nixSigning)' "$1"
}

# Record the nix signing public of keys.<host-MACHINE>'s newest slot, read from stdin. Nothing read is ever
# printed: a mistaken pipe may carry a secret.
nixsign::run() {
	local key="$nixSigningKey" machine="${nixSigningKey#host-}" m known=0 input name pk slot hostBlob hostRaw updated
	for m in "${machines[@]}"; do [[ "$m" == "$machine" ]] && known=1; done
	if [[ "$key" != host-* ]] || ((known == 0)); then
		log::error "--record-nix-signing ${key@Q}: host-MACHINE, MACHINE one of: ${machines[*]}"
		return 1
	fi
	local public=0
	ndh::secret:begin "stdin is read: a mistaken pipe may carry a secret"
	input="$(cat)"
	# A public is 32 bytes, 44 base64 characters; a nix secret, 64 bytes, cannot match.
	if [[ "$input" != *"PRIVATE KEY"* && "$input" != *$'\n'* &&
		"$input" =~ ^(seedmatic-[a-z][a-z0-9.-]*-[0-9]+):([A-Za-z0-9+/]{43}=)$ ]]; then
		public=1
	fi
	input=""
	ndh::secret:end
	if ((public == 0)); then
		log::error "stdin is not ONE nix signing public, <name>:<base64 of 32 bytes> — refused, and not printed"
		log::error "pipe ndh-keyring nix-signing-public ${machine} into it"
		return 1
	fi
	name="${BASH_REMATCH[1]}" pk="${BASH_REMATCH[2]}"
	if [[ ! "$name" =~ ^seedmatic-${machine}-[0-9]+$ ]]; then
		log::error "the public is named ${name}, not seedmatic-${machine}-N: it is another machine's"
		return 1
	fi
	slot="$(K="$key" yq eval -r '.keys[strenv(K)].slots // {} | with_entries(select((.value.state // "") != "pending" and (.value.state // "") != "retired")) | keys | sort | .[-1] // ""' "$keysYaml")"
	if [[ -z "$slot" ]]; then
		log::error "keys.${key} has no slot: record the machine's host key first (--create ${key} --public -)"
		return 1
	fi
	if [[ -n "$(K="$key" S="$slot" yq eval -r '.keys[strenv(K)].slots[strenv(S)].nixSigning // ""' "$keysYaml")" ]]; then
		log::error "keys.${key}.slots.${slot} already records a nixSigning: a new host-key slot records a new one"
		return 1
	fi
	hostBlob="$(K="$key" S="$slot" yq eval -r '.keys[strenv(K)].slots[strenv(S)].public // ""' "$keysYaml")"
	# The ed25519 public is the last 32 bytes of the ssh wire blob.
	hostRaw="$(printf '%s' "$hostBlob" | base64 -d 2>/dev/null | tail -c 32 | base64)"
	if [[ -z "$hostBlob" || "$hostRaw" == "$pk" ]]; then
		log::error "keys.${key}.slots.${slot}: no host public, or the nix public equals it — refused (no derivation)"
		return 1
	fi

	cat <<-EOF

		keys.yaml     ${keysYaml}
		record        keys.${key}.slots.${slot}.nixSigning
		  public      ${name}:${pk}

	EOF
	if ((apply == 0)); then
		log::info "dry run — pass --apply to record it in keys.yaml"
		return 0
	fi
	updated="${tmpdir}/keys.nixsigning.yaml"
	cp "$keysYaml" "$updated"
	if ! sops set "$updated" "[\"keys\"][\"${key}\"][\"slots\"][\"${slot}\"][\"nixSigning\"]" "\"${name}:${pk}\""; then
		log::error "sops set failed; keys.yaml left untouched"
		return 1
	fi
	if [[ "$(nixsign::rest "$updated" "$key" "$slot")" != "$(nixsign::rest "$keysYaml" "$key" "$slot")" ]]; then
		log::error "sops set changed more than keys.${key}.slots.${slot}.nixSigning; keys.yaml left untouched"
		return 1
	fi
	if [[ "$(K="$key" S="$slot" yq eval -r '.keys[strenv(K)].slots[strenv(S)].nixSigning' "$updated")" != "${name}:${pk}" ]]; then
		log::error "keys.${key}.slots.${slot}.nixSigning does not read back in clear, as given; keys.yaml left untouched"
		return 1
	fi
	install -m 0644 "$updated" "$keysYaml" || return 1
	"$keysJson" "$keysYaml" || return 1
	cat <<-EOF

		keys.${key}.slots.${slot}.nixSigning recorded: ${machine} signs with it once it serves its own host
		key, and every fleet machine trusts it while that slot is current.

		Next, in order:
		  1. nix run "git+file://\$PWD?rev=\$(git rev-parse HEAD)#ssh-keys-v2-validate" -- modules/home-manager/ssh.d/keys.yaml
		  2. commit the keys.yaml diff
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
	createPublic=0
	createPublicBlob=""
	revokeTarget=""
	revokeRevision=""
	nixSigningKey=""

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
			--public)
				# stdin only: a path would invite pointing at the keyring's decrypted private.
				if [[ "${2:-}" != - ]]; then
					log::error "--public takes - : the public line is read from stdin (ndh-keyring ... | ...)"
					usage
					return $?
				fi
				createPublic=1
				shift 2
				;;
			--revoke-certificate)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				revokeTarget="$2"
				shift 2
				;;
			--from-revision)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				revokeRevision="$2"
				shift 2
				;;
			--record-nix-signing)
				[[ -n "${2:-}" ]] || return "$(usage || echo $?)"
				nixSigningKey="$2"
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

	if [[ -n "$nixSigningKey" ]]; then
		if [[ -n "$createName$olderThanDays$revokeTarget$revokeRevision$reason" ]] || ((createPublic == 0)) ||
			((${#selectKeys[@]} + ${#selectAuthorities[@]} + ${#createUsages[@]} + ${#createProfiles[@]} + replace > 0)) ||
			[[ -n "$createComment$createType" ]]; then
			log::error "--record-nix-signing goes with --public - and --apply only"
			usage
			return $?
		fi
		keysYaml="$(git rev-parse --show-toplevel)/${keysRel}"
		if [[ ! -r "$keysYaml" ]]; then
			log::error "keys.yaml not readable at ${keysYaml} (run from the ndh repo root)"
			return 1
		fi
		tmpdir="$(mktemp -d)"
		chmod 700 "$tmpdir"
		trap 'rm -rf "$tmpdir"' EXIT
		nixsign::run
		return $?
	fi

	if [[ -n "$revokeTarget" ]]; then
		if [[ -n "$createName$olderThanDays" ]] || ((${#selectKeys[@]} + ${#selectAuthorities[@]} + ${#createUsages[@]} + ${#createProfiles[@]} + createPublic + replace > 0)) ||
			[[ -n "$createComment$createType" ]]; then
			log::error "--revoke-certificate stands alone: only --from-revision, --reason and --apply go with it"
			usage
			return $?
		fi
		# The schema's key and slot patterns, checked here because both are spliced into yq expressions.
		if [[ ! "$revokeTarget" =~ ^[a-z][a-z0-9-]*@[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
			log::error "--revoke-certificate ${revokeTarget@Q}: KEY@YY-MM-DD, the slot that recorded the certificate"
			usage
			return $?
		fi
		if [[ -z "$revokeRevision" || -z "$reason" ]]; then
			log::error "--revoke-certificate needs --from-revision (the commit that recorded it) and --reason"
			usage
			return $?
		fi
		keysYaml="$(git rev-parse --show-toplevel)/${keysRel}"
		if [[ ! -r "$keysYaml" ]]; then
			log::error "keys.yaml not readable at ${keysYaml} (run from the ndh repo root)"
			return 1
		fi
		tmpdir="$(mktemp -d)"
		chmod 700 "$tmpdir"
		trap 'rm -rf "$tmpdir"' EXIT
		revoke::run
		return $?
	elif [[ -n "$revokeRevision" ]]; then
		log::error "--from-revision names the revision of a --revoke-certificate"
		usage
		return $?
	fi

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
		if ((createPublic == 1)); then
			public::check_record || return $?
			public::read || return $?
		fi
		[[ -n "$createComment" ]] || createComment="$createName"
		[[ -n "$createType" ]] || createType="ssh-ed25519"
	elif ((${#createUsages[@]} + ${#createProfiles[@]} + createPublic > 0)) || [[ -n "$createComment$createType" ]]; then
		log::error "--usage, --profile, --comment, --type and --public describe a new entry: they need --create"
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
	keysYaml="$(git rev-parse --show-toplevel)/${keysRel}"
	if [[ ! -r "$keysYaml" ]]; then
		log::error "keys.yaml not readable at ${keysYaml} (run from the ndh repo root)"
		return 1
	fi

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
