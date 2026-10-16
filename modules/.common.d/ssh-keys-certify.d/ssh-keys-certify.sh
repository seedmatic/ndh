#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true
# ssh-keys-certify — sign, ON THE OPERATOR SEAT, every SSH certificate keys.yaml declares, and record it
# in keys.yaml next to the generation it certifies.
#
# Roles × keys 6a. Every host used to sign its own certificates at activation, which is why every
# host held the authority's private (L4). Here the operator seat signs once, from each key's PUBLIC, and the
# certificates travel in keys.yaml as public data: the activation only installs them.
#
#   ssh-host   the names of the machine(s) the key serves, baked at build per machine from the
#              inventory and the guests' own configurations (each name one machine's only):
#                host-<machine>  that machine's names: its own host key (roles × keys S3a)
#                rdp-host        nikopol's machines only, the interim decided 2026-10-15: the shared key
#                                nikopol's sshd still serves (baked: interimKey), until nikopol's own key
#                                is placed (its push). Gated: only once every other machine's host-<machine>
#                                certificate is current or signed earlier in the same run; until then
#                                its recorded union certificate is left untouched (interim::waiting)
#                any other key   refused: a host key serves one machine, or nikopol's in the interim
#   ssh-user   the principals the key declares (`principals`)
#
# Valid forever, by decision: the hosts are checked strictly, so a certificate that expired
# unrenewed would break every connection. A leaked key is cut by `revoked` instead (sshd's
# RevokedKeys, every client's RevokedHostKeys). Signed by the authority's SIGNING slot — the oldest
# not marked compromised — the generation every trust store already carries.
#
# Every certificate is revocable on its own (S3a K1, K2): its key id adds to {marker, owner, key, usage}
# the sha256 of its sorted principals (`names`; bounded, the names themselves are the principals) and
# its UTC issue stamp (`issued`), and its serial is one above the highest any certificate recorded in
# keys.yaml carries (never 0). So the union host certificate signed before S3a for the shared key, its
# id the bare {marker, owner, key, usage} and its serial 0, is shared by no certificate signed here:
# re-signed for the interim, it leaves keys.yaml but stays valid wherever it was installed, until the
# KRL step revokes it by that exact id (`ssh-keygen -L` on the revision that recorded it, also logged
# here when it is replaced). Nothing here deletes a recorded certificate otherwise.
#
# Idempotent: a certificate already recorded with the same key, authority generation, type,
# principals, identity (its issue stamp aside), a non-zero serial and validity is kept as it is. Dry
# run by default; --apply rewrites keys.yaml.
#
# Usage: ssh-keys-certify [--apply]     (run from the ndh repository root)

# shellcheck disable=SC1091
source @nixBashTrampoline@

# keys.yaml relative to the repository root: the real file, and the copy whose path picks its sops rule.
readonly keysRel="modules/home-manager/ssh.d/keys.yaml"
# ssh-keygen is pinned: the signature AND the comparison of a recorded certificate read its `-L`
# output, and the first ssh-keygen on PATH (Apple's or nix's) made a current certificate look stale.
readonly sshKeygen="@sshKeygen@"
readonly sha256sum="@sha256sum@"
readonly interimKey="@interimKey@"
declare -g keysYaml tmpdir decrypted apply nextSerial interimWaiting=""
declare -ga plan=() current=() unrecorded=() interimMachines=() interimPending=() interimKept=()
# machine → its names, comma-separated: baked as `machine=name,name machine=name,…`.
declare -gA hostNames=()
read -r -a interimMachines <<<"@interimMachines@"
read -r -a hostNameEntries <<<"@hostNames@"
for entry in ${hostNameEntries[@]+"${hostNameEntries[@]}"}; do
	hostNames["${entry%%=*}"]="${entry#*=}"
done
unset entry hostNameEntries

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

# The `-I` identity the downstream consumers (split-exp, extract-keys) read; they match `marker` only.
cert::identity() { # <key> <usage> <principals, comma-separated> <issue stamp>
	local names
	names="$(printf '%s' "$3" | "$sha256sum" | cut -d' ' -f1)" || return 1
	KEYNAME="$1" USAGE="$2" NAMES="$names" ISSUED="$4" yq --null-input --indent=0 --output-format=json eval \
		'{"marker": "ndh-ssh-key-meta-v1", "owner": "home-manager.ssh-add-keys", "key": strenv(KEYNAME), "usage": [strenv(USAGE)], "names": strenv(NAMES), "issued": strenv(ISSUED)}'
}

# An identity as compared: its issue stamp reduced to whether it is one, since every signature has its own.
cert::identity_shape() { # <identity JSON>
	printf '%s' "$1" | yq -p json -o json --indent=0 eval \
		'.issued |= (tag == "!!str" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' -
}

# A host key's names: nikopol's machines' for the interim key, its machine's for host-<machine>.
# plan::build has refused any other ssh-host key, and a host-<machine> naming no baked machine.
cert::host_names() { # <key> → one name per line
	local machine
	if [[ "$1" == "$interimKey" ]]; then
		for machine in "${interimMachines[@]}"; do tr ',' '\n' <<<"${hostNames[$machine]}"; done
	else
		tr ',' '\n' <<<"${hostNames[${1#host-}]}"
	fi
}

# Sorted bytewise: the identity hashes this exact string, so it must not depend on the locale.
cert::principals_for() { # <key> <usage> → comma-separated, sorted
	if [[ "$2" == ssh-host ]]; then
		cert::host_names "$1"
	else
		yq::get ".keys.\"$1\".principals // {} | keys | .[]"
	fi | LC_ALL=C sort -u | paste -sd, -
}

# What a recorded certificate says, normalised: type, key, CA, identity (cert::identity_shape), serial
# (`set`, or 0), validity, principals, critical options and extensions (each list sorted, "(none)" when
# empty).
cert::describe() { # <cert file>
	local line type key ca id serial rest
	line="$(cert::describe_raw "$1")" || return 1
	IFS='|' read -r type key ca id serial rest <<<"$line"
	id="${id#\"}"
	printf '%s|%s|%s|%s|%s|%s\n' "$type" "$key" "$ca" "$(cert::identity_shape "${id%\"}")" \
		"$([[ "$serial" == 0 ]] && echo 0 || echo set)" "$rest"
}

cert::describe_raw() { # <cert file>
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
	local type keyFp caFp principals
	type="$([[ "$5" == ssh-host ]] && echo host || echo user)"
	keyFp="$(printf '%s %s\n' "$(yq::get ".keys.\"$1\".type")" "$(yq::get ".keys.\"$1\".slots.\"$2\".public")" | "$sshKeygen" -lf - | awk '{print $2}')"
	caFp="$(printf '%s %s\n' "$(yq::get ".authorities.\"$3\".type // \"ssh-ed25519\"")" "$(yq::get ".authorities.\"$3\".slots.\"$4\".public")" | "$sshKeygen" -lf - | awk '{print $2}')"
	principals="$(cert::principals_for "$1" "$5")"
	printf '%s|%s|%s|%s|set|forever|%s|(none)|%s\n' "$type" "$keyFp" "$caFp" \
		"$(cert::identity_shape "$(cert::identity "$1" "$5" "$principals" 1970-01-01T00:00:00Z)")" \
		"$principals" "$(cert::default_extensions "$5")"
}

# The serial the next certificate gets: one above the highest any certificate recorded in keys.yaml
# carries, read from each (publics only), so serials never repeat and never are 0. Set in nextSerial,
# not printed: the log lines go to stdout.
serial::next() {
	local cert serial highest=0
	while IFS= read -r cert; do
		[[ -n "$cert" ]] || continue
		if ! serial="$(printf '%s\n' "$cert" | "$sshKeygen" -L -f - | awk '/^ *Serial:/ { print $2 }')" ||
			[[ ! "$serial" =~ ^[0-9]+$ ]]; then
			log::error "a certificate recorded in keys.yaml cannot be read: no serial can be chosen"
			return 1
		fi
		if ((serial > highest)); then highest="$serial"; fi
	done < <(yq::get '(.keys // {})[] | (.slots // {})[] | (.certificates // {})[] | .[] | select(tag == "!!str" and test("^[a-z0-9-]+-cert-v01@openssh\.com "))')
	nextSerial=$((highest + 1))
}

plan::build() {
	local key authority authSlot slot usage recorded line
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
				if [[ "$usage" == ssh-host && "$key" != "$interimKey" ]]; then
					if [[ "$key" != host-* ]]; then
						log::error "${key}: an ssh-host key is host-<machine> or ${interimKey} — refusing to certify it for any machine"
						return 1
					fi
					if [[ ! -v "hostNames[${key#host-}]" ]]; then
						log::error "${key}: no machine ${key#host-} in this build's inventory — refusing to guess its names"
						return 1
					fi
				fi
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
				line="${key}	${slot}	${authority}	${authSlot}	${usage}	$([[ -n "$recorded" ]] && echo stale || echo missing)"
				if [[ "$key" == "$interimKey" && "$usage" == ssh-host ]]; then
					interimPending+=("$line")
				else
					plan+=("$line")
				fi
			done < <(yq::get ".keys.\"${key}\".cert_usage // [] | .[]")
		done < <(yq::get ".keys.\"${key}\".slots // {} | keys | sort | .[]")
	done < <(yq::get '.keys // {} | keys | .[]')
	interimWaiting="$(interim::waiting)"
	if [[ -n "$interimWaiting" ]]; then
		interimKept=(${interimPending[@]+"${interimPending[@]}"})
	else
		# Last, so the host-<machine> certificates the gate counted are signed before it in the run.
		plan+=(${interimPending[@]+"${interimPending[@]}"})
	fi
	serial::next
}

# The rollout gate (S3a K3: every host serves its OWN certificate before the union one goes away):
# until every machine outside the interim set has its own host key certified, current or signed in
# this run, its sshd still serves the interim key, so the interim key keeps the union certificate it
# has, untouched; re-signing it would also mint a second union id for the KRL to cut. Prints the
# machines still waiting, space-separated.
interim::waiting() {
	local machine line key usage waiting=() found
	while IFS= read -r machine; do
		[[ -n "$machine" ]] || continue
		[[ " ${interimMachines[*]} " == *" ${machine} "* ]] && continue
		found=0
		for line in ${current[@]+"${current[@]}"}; do
			IFS=$'\t' read -r key _ usage <<<"$line"
			[[ "$key" == "host-${machine}" && "$usage" == ssh-host ]] && found=1
		done
		for line in ${plan[@]+"${plan[@]}"}; do
			IFS=$'\t' read -r key _ _ _ usage _ <<<"$line"
			[[ "$key" == "host-${machine}" && "$usage" == ssh-host ]] && found=1
		done
		# a slot of its key with no recorded public is not certified: not yet its own
		for line in ${unrecorded[@]+"${unrecorded[@]}"}; do
			IFS=$'\t' read -r key _ usage <<<"$line"
			[[ "$key" == "host-${machine}" && "$usage" == ssh-host ]] && found=0
		done
		((found)) || waiting+=("$machine")
	done < <(printf '%s\n' "${!hostNames[@]}" | LC_ALL=C sort)
	printf '%s\n' "${waiting[*]}"
}

plan::show() {
	local line key slot authority authSlot usage why machine
	printf '\nkeys.yaml    %s\n' "$keysYaml"
	while IFS= read -r machine; do
		printf 'host names   %-14s %s\n' "$machine" "${hostNames[$machine]}"
	done < <(printf '%s\n' "${!hostNames[@]}" | LC_ALL=C sort)
	printf 'interim      %-14s %s\nnext serial  %s\n\n' "$interimKey" "${interimMachines[*]}" "$nextSerial"
	for line in ${current[@]+"${current[@]}"}; do
		IFS=$'\t' read -r key slot usage <<<"$line"
		printf '  current  %-22s %-9s %s\n' "$key" "$slot" "$usage"
	done
	for line in ${unrecorded[@]+"${unrecorded[@]}"}; do
		IFS=$'\t' read -r key slot usage <<<"$line"
		printf '  unrecorded %-20s %-9s %-9s no public in keys.yaml: generated and signed at activation\n' "$key" "$slot" "$usage"
	done
	for line in ${interimKept[@]+"${interimKept[@]}"}; do
		IFS=$'\t' read -r key slot authority authSlot usage why <<<"$line"
		printf '  kept     %-22s %-9s %-9s its sshd still serves it on %s\n' "$key" "$slot" "$usage" "$interimWaiting"
	done
	for line in ${plan[@]+"${plan[@]}"}; do
		IFS=$'\t' read -r key slot authority authSlot usage why <<<"$line"
		printf '  %-8s %-22s %-9s %-9s signed by %s@%s\n' "$why" "$key" "$slot" "$usage" "$authority" "$authSlot"
	done
	printf '\n'
	if ((${#interimKept[@]} > 0)); then
		log::info "${interimKey} keeps its union cert until ${interimWaiting} have their own host key"
	fi
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

certify::one() { # <key> <slot> <authority> <authority slot> <usage> <serial>
	local key="$1" slot="$2" authority="$3" authSlot="$4" usage="$5" serial="$6" principals identity replaced
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
	principals="$(cert::principals_for "$key" "$usage")"
	if ! identity="$(cert::identity "$key" "$usage" "$principals" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" || [[ -z "$identity" ]]; then
		log::error "cannot compose the key id of ${key}@${slot} ${usage}"
		return 1
	fi
	local -a args=(-q -s "$authFile" -I "$identity" -z "$serial" -n "$principals")
	[[ "$usage" == ssh-host ]] && args+=(-h)
	# The certificate this one replaces keeps its id and serial wherever it was installed: logged, so
	# the revocation that cuts it can name it exactly.
	replaced="$(yq::get ".keys.\"${key}\".slots.\"${slot}\".certificates.\"${authority}\".\"${usage}\" // \"\"")"
	if [[ -n "$replaced" ]]; then
		replaced="$(printf '%s\n' "$replaced" | "$sshKeygen" -L -f - | awk '/^ *Key ID:/ { sub(/^ *Key ID: /, ""); id = $0 } /^ *Serial:/ { serial = $2 } END { print "key id " id ", serial " serial }')" ||
			replaced="(unreadable)"
		log::info "replaces ${key}@${slot} ${usage}: ${replaced}"
	fi
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
	log::info "signed ${key}@${slot} ${usage} with ${authority}@${authSlot}, serial ${serial}"
}

certify::apply() {
	local line reencrypted
	for line in "${plan[@]}"; do
		IFS=$'\t' read -r key slot authority authSlot usage _ <<<"$line"
		certify::one "$key" "$slot" "$authority" "$authSlot" "$usage" "$nextSerial" || {
			log::error "keys.yaml left untouched"
			return 1
		}
		nextSerial=$((nextSerial + 1))
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
		  3. switch: each host installs the certificates recorded for it

		A re-signed certificate has a new key id and serial, user certificates included: a copy
		pinned elsewhere (another machine's known_hosts, a saved user cert) is the old one.
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
	if ((${#hostNames[@]} == 0)); then
		log::error "no host names were baked into this build — refusing to sign a host certificate for nobody"
		return 1
	fi
	local machine
	if [[ -z "$interimKey" ]] || ((${#interimMachines[@]} == 0)); then
		log::error "no interim host key and machines were baked into this build"
		return 1
	fi
	for machine in "${interimMachines[@]}"; do
		[[ -v "hostNames[$machine]" ]] && continue
		log::error "interim machine ${machine} has no baked names"
		return 1
	done

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
