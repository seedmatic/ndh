#!/usr/bin/env -S bash -euo pipefail
# @codebase
# SSH keys bundle enrichment — v2 schema.
#
# Reads a v2-shaped keys.yaml:
#
#   authorities:
#     <name>:
#       type: ssh-ed25519
#       usage: [ssh-authority]
#       slots:
#         <YY-MM-DD>:
#           public: <bare base64>
#           private: <pem or ENC[...]>
#   keys:
#     <name>:
#       type: ssh-ed25519
#       authority: <authority-name>        # optional; omit for bare keys
#       cert_usage: [ssh-host, ssh-user]   # required iff authority is set
#       usage: [...]
#       profiles: [bringup, host, user, ...]
#       principals: { ... }                # optional
#       slots:
#         <YY-MM-DD>:
#           public: <bare base64>          # optional; generated if missing
#           private: <pem>                 # optional; generated if missing
#
# Writes the same shape augmented, per key GENERATION, with
# `slots.<YY-MM-DD>.certificates.<authority>.<cert_type>` cert lines for every
# (authority, cert_type) the enrichment produced. A certificate belongs to the
# generation it certifies: during a renewal both generations are published and
# each one needs its own.
#
# Schema validated by modules/home-manager/ssh.d/keys.schema.yaml; cross-
# reference validation (authority names must resolve to top-level entries)
# is enforced here at runtime — a dangling reference is a hard error.

# shellcheck disable=SC1091
source @nixBashTrampoline@

declare -g inputFile outputFile hostName inventoryHostsCsv targetUser extraPrincipalsCsv
declare -g tmpdir

log::info() { echo "[ssh-keys-enrichment][INFO] $*" >&2; }
log::warn() { echo "[ssh-keys-enrichment][WARN] $*" >&2; }
log::error() { echo "[ssh-keys-enrichment][ERROR] $*" >&2; }

# Read a yq path from the input file. Missing paths return the literal
# empty string (caller distinguishes between "absent" and "empty value"
# by checking `yq 'has(path)'` separately when needed).
yq::get() { yq eval -r "${1}" "$inputFile" 2>/dev/null || true; }

# A key entry holds its generations in `slots`, keyed by the date the material was
# created (YY-MM-DD). The generation that is PRESENTED is derived from the newest
# key rather than named by a field, so there is nothing to keep in step and nothing
# that can go stale. All generations are accepted, which is what makes a renewal
# survivable. See docs/ssh-keys-renewal-spec.adoc.
#
# There is no fallback to a flat `public`/`private`: an entry without slots is an
# error. Carrying both shapes would mean testing neither.

# Keys and authorities differ only in which top-level section holds them, so the
# resolution is written once and named twice. Authorities need the overlap most:
# trusted-user-ca.pub concatenates every *-ca.pub on each activation, so two
# authority generations are both trusted while the leaves move across.

slot::count() { # <section> <name>
	local n
	n="$(yq eval -r ".${1}.\"${2}\".slots | length" "$inputFile" 2>/dev/null || true)"
	[[ -n "$n" && "$n" != "null" ]] || n=0
	printf '%s\n' "$n"
}

# Oldest first, which is the order the enrichment walks: a cert is signed for
# every generation, so the retiring one keeps a valid certificate for as long as
# it is still published.
slot::list() { # <section> <name>
	local n
	n="$(slot::count "$1" "$2")"
	if ((n == 0)); then
		log::error "${1} entry ${2} has no slots — the flat public/private shape is not supported"
		return 1
	fi
	yq eval -r ".${1}.\"${2}\".slots | keys | sort | .[]" "$inputFile"
}

slot::newest() { # <section> <name>
	# Not `slot::list | tail -1`: a pipeline reports the LAST command's status, so
	# the failure on a slotless entry would be swallowed wherever pipefail is not
	# set — and it is not set when these functions are sourced by the tests.
	# The emptiness check is the real guard: a process substitution does not
	# propagate its status to mapfile, and slot::list prints its refusal on
	# stderr, so an empty array IS the failure — already reported.
	local -a slots
	mapfile -t slots < <(slot::list "$1" "$2")
	((${#slots[@]} > 0)) || return 1
	printf '%s\n' "${slots[-1]}"
}

# Two slots means a renewal is in flight; one means settled. Three means phase 2
# was skipped, and phase 2 is not optional.
slot::assert() { # <section> <name>
	local n
	n="$(slot::count "$1" "$2")"
	if ((n > 2)); then
		log::error "${1} entry ${2} has ${n} slots; at most two are allowed — phase 2 of a renewal removes the retiring one"
		return 1
	fi
	return 0
}

# The slot is a parameter, never resolved inside the accessor. The enrichment
# works one generation at a time, so a helper that silently picked the newest
# would read the wrong material for every generation but one.
slot::get() { # <section> <name> <slot> <field>
	yq eval -r ".${1}.\"${2}\".slots.\"${3}\".${4} // \"\"" "$inputFile" 2>/dev/null || true
}

slot::set() { # <section> <name> <slot> <field> <value>
	VALUE="$5" yq -i ".${1}.\"${2}\".slots.\"${3}\".${4} = strenv(VALUE)" "$inputFile"
}

key::slots() { slot::list keys "$1"; }
key::slots_count() { slot::count keys "$1"; }
key::newest_slot() { slot::newest keys "$1"; }
key::assert_slots() { slot::assert keys "$1"; }
key::field() { slot::get keys "$1" "$2" "$3"; }
key::set_field() { slot::set keys "$1" "$2" "$3" "$4"; }

authority::slots() { slot::list authorities "$1"; }
authority::slots_count() { slot::count authorities "$1"; }
authority::newest_slot() { slot::newest authorities "$1"; }
authority::assert_slots() { slot::assert authorities "$1"; }
authority::field() { slot::get authorities "$1" "$2" "$3"; }

# The OLDEST generation still published, which is the one that signs.
#
# ★ This is the opposite of a key, and the asymmetry is the whole point. Trust
# DISTRIBUTES slowly — a client learns a new authority only when it activates,
# because KnownHostsCommand globs the live `*-ca.pub` directory. A signature
# takes effect IMMEDIATELY, on the first host that activates. Signing with the
# newest generation therefore opens a window in which an activated host presents
# a certificate that a host which has not activated yet cannot verify, and
# "cannot verify a host certificate" is a blocking failure, not a prompt.
#
# Signing with the oldest closes that window entirely: during phase 1 the new
# authority is distributed but signs nothing, and phase 2 — dropping the retiring
# slot — is what switches the signature over, at a point where every host already
# trusts the new one.
#
# It costs nothing in exposure when the old private is compromised, which is the
# case that prompted this: the old authority stays ACCEPTED throughout phase 1
# either way, so a forged certificate under it would pass either way. Phase 2 is
# what revokes it.
authority::signing_slot() { # <name>
	local -a slots
	mapfile -t slots < <(authority::slots "$1")
	((${#slots[@]} > 0)) || return 1
	printf '%s\n' "${slots[0]}"
}

authority::signing() { # <name> <field>
	local slot
	slot="$(authority::signing_slot "$1")" || return 1
	authority::field "$1" "$slot" "$2"
}

# Emit the comma-separated hostnames the enrichment will list in a host
# certificate's Principals field. Union of: explicit hostName arg,
# .lan/.local/<authority-domain> variants, plus every host from the
# inventory CSV (same variants), plus the extra principals VERBATIM.
#
# The extras are names the platform declares for itself that the variants
# cannot produce: a NixOS guest is reached as `nixos.<host>`, served by the
# bare-metal's dnsmasq, and a `.lan`/`.local` of that is meaningless. Without
# it the client checks the certificate against `nixos.bioskop`, finds it is
# not a listed principal, and falls back to the raw key pinned in known_hosts
# — which a host-key rotation then breaks.
authority::host_principals() {
	local authorityName="$1"
	local domain
	domain="$(yq::get ".authorities.\"${authorityName}\".domain")"

	local -A hosts=()
	hosts["${hostName}"]=1
	hosts["${hostName}.lan"]=1
	hosts["${hostName}.local"]=1
	if [[ -n "${domain}" && "${domain}" != "null" ]]; then
		hosts["${hostName}.${domain}"]=1
	fi
	local localShort localFqdn
	localShort="$(hostname -s 2>/dev/null || true)"
	localFqdn="$(hostname -f 2>/dev/null || true)"
	[[ -n "$localShort" ]] && hosts["$localShort"]=1
	[[ -n "$localFqdn" ]] && hosts["$localFqdn"]=1
	if [[ -n "$localShort" && -n "${domain}" && "${domain}" != "null" ]]; then
		hosts["${localShort}.${domain}"]=1
	fi

	if [[ -n "${inventoryHostsCsv:-}" ]]; then
		local inv
		IFS=',' read -r -a invArr <<<"${inventoryHostsCsv}"
		for inv in "${invArr[@]}"; do
			[[ -n "$inv" ]] || continue
			hosts["$inv"]=1
			hosts["${inv}.lan"]=1
			hosts["${inv}.local"]=1
			if [[ -n "${domain}" && "${domain}" != "null" ]]; then
				hosts["${inv}.${domain}"]=1
			fi
		done
	fi

	if [[ -n "${extraPrincipalsCsv:-}" ]]; then
		local extra
		IFS=',' read -r -a extraArr <<<"${extraPrincipalsCsv}"
		for extra in "${extraArr[@]}"; do
			[[ -n "$extra" ]] || continue
			hosts["$extra"]=1
		done
	fi

	local IFS=','
	echo "${!hosts[*]}"
}

# Build the `-I` cert identity blob (json one-liner) matching the v1 schema
# downstream consumers (split-exp, extract-keys) look for.
cert::identity() {
	local keyName="$1"
	local certUsage="$2"
	env KEYNAME="$keyName" USAGE="$certUsage" yq \
		--null-input --indent=0 --output-format=json eval '
			{
				"marker": "ndh-ssh-key-meta-v1",
				"owner": "home-manager.ssh-add-keys",
				"key": strenv(KEYNAME),
				"usage": [ strenv(USAGE) ]
			}'
}

# Comma-join the keys of the `principals` map for a given key.
key::principals_csv() {
	local keyName="$1"
	local IFS=','
	local -a arr
	mapfile -t arr < <(yq::get ".keys.\"${keyName}\".principals | keys // [] | .[]")
	echo "${arr[*]}"
}

# Sign one (key generation, authority, cert_usage) triple and echo the resulting
# cert line to stdout. Temp files are created under $tmpdir and cleaned
# up in main's trap.
#
# The key generation is explicit: every generation that is published gets its own
# certificate, so the retiring one stays usable for as long as it is on disk.
sign::one_cert() {
	local keyName="$1"
	local keySlot="$2"
	local authorityName="$3"
	local certUsage="$4"

	# x509 TLS leaves are signed via step-cli against the authority's
	# OpenSSH Ed25519 private key.  Dispatch early to keep the SSH path
	# below strictly ssh-keygen-driven.
	if [[ "$certUsage" == "tls-server" ]]; then
		sign::tls_server "$keyName" "$keySlot" "$authorityName"
		return $?
	fi

	# Pull authority private + key public/private.
	local authPriv keyType keyPub keyPriv keyComment
	authority::assert_slots "$authorityName" || return 1
	authPriv="$(authority::signing "$authorityName" private)" || return 1
	keyType="$(yq::get ".keys.\"${keyName}\".type")"
	key::assert_slots "$keyName" || return 1
	keyPub="$(key::field "$keyName" "$keySlot" public)"
	keyPriv="$(key::field "$keyName" "$keySlot" private)"
	keyComment="$(yq::get ".keys.\"${keyName}\".comment")"
	[[ -n "$keyComment" && "$keyComment" != "null" ]] || keyComment="$keyName"

	if [[ -z "$authPriv" || "$authPriv" == "null" ]]; then
		log::error "authority ${authorityName} has no private key (required to sign ${keyName}@${keySlot}/${certUsage})"
		return 1
	fi

	# Cache the authority's private in a tempfile once per (authority)
	# rather than per (authority, cert_usage). Repeated calls of this
	# function with the same authority would otherwise fail to rewrite a
	# 0400 file.
	local authFile="${tmpdir}/auth-${authorityName}"
	if [[ ! -s "$authFile" ]]; then
		printf '%s\n' "$authPriv" >"$authFile"
		chmod 400 "$authFile"
	fi

	# Every tempfile is scoped to the generation: two generations of the same key
	# are signed in the same run, and a shared name would have one overwrite the
	# other's material.
	local stem="${tmpdir}/${keyName}@${keySlot}"

	# Generate key if missing public/private.
	if [[ -z "$keyPub" || "$keyPub" == "null" || -z "$keyPriv" || "$keyPriv" == "null" ]]; then
		local genType="${keyType#ssh-}"
		if ! ssh-keygen -q -t "$genType" -N "" -f "$stem" -C "$keyComment"; then
			log::error "failed to generate keypair for ${keyName}@${keySlot}"
			return 1
		fi
		keyPub="$(cut -d' ' -f2 <"${stem}.pub")"
		keyPriv="$(<"$stem")"
		# Cache so subsequent cert_usage entries see the same pair.
		key::set_field "$keyName" "$keySlot" public "$keyPub"
		key::set_field "$keyName" "$keySlot" private "$keyPriv"
	fi

	# `public` holds the bare base64 blob; the type and the comment have fields of
	# their own, and every consumer rebuilds the line from the three. Writing a
	# whole "<type> <blob> <comment>" line into it doubled the type and the
	# comment in the rebuilt line.
	local keyPubFile="${stem}.pub"
	printf '%s %s %s\n' "$keyType" "$keyPub" "$keyComment" >"$keyPubFile"

	local identity principalsArg
	identity="$(cert::identity "$keyName" "$certUsage")"

	local -a sshKeygenArgs=(-q -s "$authFile" -I "$identity")
	case "$certUsage" in
		ssh-user)
			principalsArg="$(key::principals_csv "$keyName")"
			if [[ -z "$principalsArg" ]]; then
				log::warn "key ${keyName} has no principals; ssh-user cert will be identity-only"
			else
				sshKeygenArgs+=(-n "$principalsArg")
			fi
			;;
		ssh-host)
			sshKeygenArgs+=(-h -n "$(authority::host_principals "$authorityName")")
			;;
		*)
			log::error "unsupported cert_usage ${certUsage} for ${keyName}"
			return 1
			;;
	esac

	if ! ssh-keygen "${sshKeygenArgs[@]}" "$keyPubFile"; then
		log::error "ssh-keygen failed to sign ${keyName}@${keySlot} with ${authorityName} as ${certUsage}"
		return 1
	fi

	local certFile="${keyPubFile%.pub}-cert.pub"
	cat "$certFile"
	rm -f "$certFile"
}

# Sign a TLS x509 leaf certificate for `keyName` using the named
# authority's OpenSSH-format Ed25519 private key.  Emits a PEM blob on
# stdout.
#
# Preconditions (hard errors, not auto-provisioning):
#   - The authority must advertise `tls-authority` in its `usage:` list.
#   - The authority must carry `ca_crt:` (the self-signed root), which
#     the operator mints once via bin/authority-bootstrap-tls-root.sh.
#     The enrichment step is not authorised to mint new trust roots.
#   - `step-cli` must be on PATH (threaded in via
#     modules/.common.d/system-packages.nix and the per-platform
#     enrichment unit's `path` list).
#   - The key must carry a `tls:` block with at least `common_name`.
#
# step-cli reads OpenSSH Ed25519 keys natively (both signer and subject),
# so no openssl/PEM conversion is required despite Ed25519 SSH keys
# being opaque to stock openssl builds.
sign::tls_server() {
	local keyName="$1"
	local keySlot="$2"
	local authorityName="$3"

	# Authority must advertise tls-authority before it is allowed to sign
	# TLS leaves.  The schema already constrains the enum; this guards
	# against a schema-valid authority that simply forgot to opt in.
	# yq-go uses `contains()` for array-membership; `index()` exists in
	# jq but not here and throws a lexer error.
	if ! yq eval -e "(.authorities.\"${authorityName}\".usage // []) | contains([\"tls-authority\"])" \
		"$inputFile" >/dev/null 2>&1; then
		log::error "authority ${authorityName} does not advertise tls-authority (cannot sign ${keyName}/tls-server)"
		return 1
	fi

	# Materialise the CA cert from keys.yaml to a tempfile step-cli can
	# read.  Missing ca_crt means the authority hasn't been bootstrapped
	# yet — hard error rather than auto-mint.
	local caCrtPem
	caCrtPem="$(yq::get ".authorities.\"${authorityName}\".ca_crt")"
	if [[ -z "$caCrtPem" || "$caCrtPem" == "null" ]]; then
		log::error "authority ${authorityName} has no ca_crt (run bin/authority-bootstrap-tls-root.sh ${authorityName})"
		return 1
	fi
	local caCrt="${tmpdir}/auth-${authorityName}-ca.crt"
	if [[ ! -s "$caCrt" ]]; then
		printf '%s\n' "$caCrtPem" >"$caCrt"
		chmod 0444 "$caCrt"
	fi

	if ! command -v step >/dev/null 2>&1; then
		log::error "step-cli not found on PATH (add pkgs.step-cli to the enrichment unit's path)"
		return 1
	fi

	local commonName
	commonName="$(yq::get ".keys.\"${keyName}\".tls.common_name")"
	if [[ -z "$commonName" || "$commonName" == "null" ]]; then
		log::error "key ${keyName} requested tls-server but has no .tls.common_name"
		return 1
	fi

	local notAfterDays notAfterHours
	notAfterDays="$(yq::get ".keys.\"${keyName}\".tls.not_after_days // 365")"
	notAfterHours=$((notAfterDays * 24))

	# Materialise the signer (authority) and subject (leaf) privates as
	# tempfiles step-cli can read.  Re-uses the $tmpdir/auth-<name> cache
	# populated by the SSH signing path when present; otherwise creates
	# it here so TLS-only enrichment runs don't depend on SSH-cert order.
	local authPriv
	authority::assert_slots "$authorityName" || return 1
	authPriv="$(authority::signing "$authorityName" private)" || return 1
	if [[ -z "$authPriv" || "$authPriv" == "null" ]]; then
		log::error "authority ${authorityName} has no private key"
		return 1
	fi
	local authFile="${tmpdir}/auth-${authorityName}"
	if [[ ! -s "$authFile" ]]; then
		printf '%s\n' "$authPriv" >"$authFile"
		chmod 400 "$authFile"
	fi

	# The subject key must already exist (either present in the input
	# yaml or generated earlier in this enrichment run by the SSH path).
	# tls-server is never the first cert_usage we process for a key in
	# practice — cert_usage is an ordered list and ssh-host/ssh-user
	# entries populate the key first.  If a key declares only
	# `cert_usage: [tls-server]` we still need material, so re-run the
	# generate-if-missing dance.
	local leafKeyFile="${tmpdir}/${keyName}@${keySlot}"
	if [[ ! -s "$leafKeyFile" ]]; then
		local keyPriv keyType keyComment
		keyPriv="$(key::field "$keyName" "$keySlot" private)"
		keyType="$(yq::get ".keys.\"${keyName}\".type")"
		keyComment="$(yq::get ".keys.\"${keyName}\".comment")"
		[[ -n "$keyComment" && "$keyComment" != "null" ]] || keyComment="$keyName"
		if [[ -z "$keyPriv" || "$keyPriv" == "null" ]]; then
			local genType="${keyType#ssh-}"
			if ! ssh-keygen -q -t "$genType" -N "" -f "$leafKeyFile" -C "$keyComment"; then
				log::error "failed to generate keypair for ${keyName}@${keySlot}"
				return 1
			fi
			local keyPub
			keyPub="$(cut -d' ' -f2 <"${leafKeyFile}.pub")"
			keyPriv="$(<"$leafKeyFile")"
			key::set_field "$keyName" "$keySlot" public "$keyPub"
			key::set_field "$keyName" "$keySlot" private "$keyPriv"
		else
			printf '%s\n' "$keyPriv" >"$leafKeyFile"
			chmod 0400 "$leafKeyFile"
		fi
	fi

	# SAN flags — step-cli accepts repeated --san whose arguments may be
	# DNS names or IP literals; step's autodetection picks the right
	# x509 SAN type from the string shape.
	local -a sanFlags=()
	local san
	while IFS= read -r san; do
		[[ -n "$san" && "$san" != "null" ]] || continue
		sanFlags+=(--san "$san")
	done < <(yq eval -r ".keys.\"${keyName}\".tls.sans.dns // [] | .[]" "$inputFile" 2>/dev/null)
	while IFS= read -r san; do
		[[ -n "$san" && "$san" != "null" ]] || continue
		sanFlags+=(--san "$san")
	done < <(yq eval -r ".keys.\"${keyName}\".tls.sans.ip // [] | .[]" "$inputFile" 2>/dev/null)

	# step certificate create always writes a PKCS8 copy of the subject
	# key next to the cert; we don't need it (the real private stays in
	# the sops-sealed yaml) and delete immediately.
	local leafCrtFile="${tmpdir}/${keyName}@${keySlot}-tls-${authorityName}.crt"
	local leafKeyCopy="${tmpdir}/${keyName}@${keySlot}-tls-${authorityName}.key"

	if ! step certificate create "$commonName" \
		"$leafCrtFile" "$leafKeyCopy" \
		--profile leaf \
		--ca "$caCrt" \
		--ca-key "$authFile" \
		--key "$leafKeyFile" \
		--no-password --insecure \
		--not-after "${notAfterHours}h" \
		"${sanFlags[@]}" >/dev/null 2>&1; then
		log::error "step certificate create failed for ${keyName}/tls-server under ${authorityName}"
		rm -f "$leafCrtFile" "$leafKeyCopy"
		return 1
	fi

	cat "$leafCrtFile"
	rm -f "$leafCrtFile" "$leafKeyCopy"
}

# Walk every key with an authority ref, sign each of its GENERATIONS for each
# cert_usage, and record the resulting cert line back into the in-memory yaml
# (through repeated yq -i updates on the working copy $inputFile).
#
# A certificate belongs to the generation it certifies, so it is recorded inside
# the slot. Signing only the newest left the retiring generation materialised on
# disk with no certificate, which is half a renewal.
enrich::all_keys() {
	local -a keyNames
	mapfile -t keyNames < <(yq eval -r '.keys | keys // [] | .[]' "$inputFile")

	local keyName
	for keyName in "${keyNames[@]}"; do
		[[ -n "$keyName" ]] || continue
		local authorityName
		authorityName="$(yq::get ".keys.\"${keyName}\".authority")"
		if [[ -z "$authorityName" || "$authorityName" == "null" ]]; then
			continue
		fi

		# Cross-reference check: authority must exist.
		if ! yq eval -e ".authorities | has(\"${authorityName}\")" "$inputFile" >/dev/null 2>&1; then
			log::error "key ${keyName} references unknown authority ${authorityName}"
			return 1
		fi

		local -a certUsages
		mapfile -t certUsages < <(yq eval -r ".keys.\"${keyName}\".cert_usage // [] | .[]" "$inputFile")
		if ((${#certUsages[@]} == 0)); then
			log::error "key ${keyName} has authority ${authorityName} but empty cert_usage"
			return 1
		fi

		key::assert_slots "$keyName" || return 1
		local -a keySlots
		mapfile -t keySlots < <(key::slots "$keyName")
		if ((${#keySlots[@]} == 0)); then
			return 1
		fi

		local keySlot certUsage certLine
		for keySlot in "${keySlots[@]}"; do
			for certUsage in "${certUsages[@]}"; do
				certLine="$(sign::one_cert "$keyName" "$keySlot" "$authorityName" "$certUsage")"
				# Inject under .keys.<k>.slots.<slot>.certificates.<auth>.<cert_usage>.
				# yq -i with literal strings containing newlines/special chars
				# via env to avoid quoting issues.
				env CERT="$certLine" yq -i "
					.keys.\"${keyName}\".slots.\"${keySlot}\".certificates.\"${authorityName}\".\"${certUsage}\" = strenv(CERT)
				" "$inputFile"
			done
		done
	done
}

main() {
	if (($# < 3)); then
		log::error "usage: ssh-enrich-keys-yaml <hostName> <inputYaml> <outputYaml> [<inventoryHostsCsv>] [<targetUser>] [<extraPrincipalsCsv>]"
		return 64
	fi

	hostName="$1"
	inputFile="$2"
	outputFile="$3"
	inventoryHostsCsv="${4:-}"
	targetUser="${5:-${USER:-root}}"
	extraPrincipalsCsv="${6:-}"

	if [[ ! -r "$inputFile" ]]; then
		log::error "input yaml unreadable: $inputFile"
		return 1
	fi

	tmpdir="$(mktemp -d --suffix=.enrich)"
	trap 'rm -rf "$tmpdir"' EXIT

	# Create the output directory before enrichment so that it exists even
	# if enrich::all_keys exits early (set -e); callers that check for the
	# directory's presence can distinguish "not started" from "failed".
	local outDir
	outDir="$(dirname "$outputFile")"
	if [[ "$(id -u)" -eq 0 && -n "$targetUser" ]]; then
		local targetGroup
		targetGroup="$(id -gn "$targetUser" 2>/dev/null || echo "$targetUser")"
		install -o "$targetUser" -g "$targetGroup" -m 0700 -d "$outDir"
	else
		install -m 0700 -d "$outDir"
	fi

	# Work on a mutable copy so repeated yq -i calls stay scoped.
	local workFile="${tmpdir}/keys.work.yaml"
	cp "$inputFile" "$workFile"
	inputFile="$workFile"

	enrich::all_keys

	# Atomic install.
	local tmpOut
	tmpOut="$(mktemp)"
	cp "$inputFile" "$tmpOut"
	rm -f "$outputFile"
	if ! install -m 0400 "$tmpOut" "$outputFile"; then
		log::error "failed to install enriched yaml at $outputFile"
		rm -f "$tmpOut"
		return 1
	fi
	rm -f "$tmpOut"

	if [[ "$(id -u)" -eq 0 && -n "$targetUser" ]]; then
		chown "$targetUser" "$outputFile" 2>/dev/null || true
	fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
