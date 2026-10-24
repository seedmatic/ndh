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
#           public: <bare base64>
#           private: <pem>
#           certificates: { <authority>: { ssh-host: <cert line>, ssh-user: <cert line> } }
#
# An SSH certificate (ssh-host, ssh-user) is signed ON THE OPERATOR SEAT (ssh-keys-certify) and recorded in
# keys.yaml; the activation installs it as recorded and signs nothing, so no host needs the SSH
# authority's private (roles × keys 6a). A key with an SSH cert_usage whose material or certificate
# is not recorded is a hard error. Only a TLS leaf (tls-server) is still signed here, until its CSR
# path lands; its certificate is added under the same `certificates` map.
#
# Schema validated by modules/home-manager/ssh.d/keys.schema.yaml; cross-
# reference validation (authority names must resolve to top-level entries)
# is enforced here at runtime — a dangling reference is a hard error.

# shellcheck disable=SC1091
source @nixBashTrampoline@

declare -g inputFile outputFile targetUser
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

# A slot `pending` (no key yet) or `retired` (no longer used) is not this machine's to install, sign for or count
# (roles × keys K5+): every slot reader goes through this filter. Authorities' slots carry no state, so it keeps them.
usableSlots='| with_entries(select((.value.state // "") != "pending" and (.value.state // "") != "retired"))'

slot::count() { # <section> <name>
	local n
	n="$(yq eval -r ".${1}.\"${2}\".slots ${usableSlots} | length" "$inputFile" 2>/dev/null || true)"
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
	yq eval -r ".${1}.\"${2}\".slots ${usableSlots} | keys | sort | .[]" "$inputFile"
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

# The OLDEST generation still published that is not marked `compromised` — the
# one that signs, and the one an authority PRESENTS: its `ca_crt` is the root a
# TLS leaf chains to, so signer and presented root are always the same slot.
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
# The exception is a COMPROMISED slot. Keeping a leaked private as the signer
# through a whole phase would mint fresh certificates an attacker can match, so a
# slot that carries `compromised: <reason>` never signs: the signature moves to the
# other generation at once, and the breakage that causes is accepted (the screen
# is the fallback). The slot is revoked in the same renewal.
authority::signing_slot() { # <name>
	local -a slots
	mapfile -t slots < <(authority::slots "$1")
	((${#slots[@]} > 0)) || return 1
	local slot
	for slot in "${slots[@]}"; do
		[[ -n "$(authority::field "$1" "$slot" compromised)" ]] && continue
		printf '%s\n' "$slot"
		return 0
	done
	log::error "authority $1: every slot is marked compromised — nothing may sign"
	return 1
}

authority::signing() { # <name> <field>
	local slot
	slot="$(authority::signing_slot "$1")" || return 1
	authority::field "$1" "$slot" "$2"
}

# Sign a TLS x509 leaf certificate for `keyName` using the named
# authority's OpenSSH-format Ed25519 private key.  Emits a PEM blob on
# stdout.
#
# Preconditions (hard errors, not auto-provisioning):
#   - The authority must advertise `tls-authority` in its `usage:` list.
#   - The authority's SIGNING slot must carry `ca_crt:` (that generation's
#     self-signed root), minted by bin/authority-bootstrap-tls-root.sh. The
#     leaf is signed by that slot's private, so it chains to that root.
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
	authority::assert_slots "$authorityName" || return 1
	caCrtPem="$(authority::signing "$authorityName" ca_crt)" || return 1
	if [[ -z "$caCrtPem" || "$caCrtPem" == "null" ]]; then
		log::error "authority ${authorityName}: its signing slot has no ca_crt (run bin/authority-bootstrap-tls-root.sh ${authorityName})"
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

	# Materialise the signer (authority) and subject (leaf) privates as tempfiles step-cli can read, once per run:
	# the authority's $tmpdir/auth-<name> is written by the first TLS leaf it signs and reused by the next. No SSH
	# path reads a private here (SSH certificates are signed on the operator seat).
	# The returns sit outside the windows: a window is closed on every path, then the outcome is judged.
	local authPriv authRead=1 authHeld=1
	local authFile="${tmpdir}/auth-${authorityName}"
	authority::assert_slots "$authorityName" || return 1
	ndh::secret:begin "the authority's private is materialised for step"
	authPriv="$(authority::signing "$authorityName" private)" || authRead=0
	if [[ -z "$authPriv" || "$authPriv" == "null" ]]; then
		authHeld=0
	elif [[ ! -s "$authFile" ]]; then
		printf '%s\n' "$authPriv" >"$authFile"
		chmod 400 "$authFile"
	fi
	authPriv=""
	ndh::secret:end
	((authRead == 1)) || return 1
	if ((authHeld == 0)); then
		log::error "authority ${authorityName} has no private key"
		return 1
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
		local keyPriv keyType comment keygenFailed=0
		keyType="$(yq::get ".keys.\"${keyName}\".type")"
		comment="$(yq::get ".keys.\"${keyName}\".comment")"
		[[ -n "$comment" && "$comment" != "null" ]] || comment="$keyName"
		ndh::secret:begin "the leaf's private is read, or born and recorded"
		keyPriv="$(key::field "$keyName" "$keySlot" private)"
		if [[ -z "$keyPriv" || "$keyPriv" == "null" ]]; then
			if ssh-keygen -q -t "${keyType#ssh-}" -N "" -f "$leafKeyFile" -C "$comment"; then
				keyPriv="$(<"$leafKeyFile")"
				key::set_field "$keyName" "$keySlot" public "$(cut -d' ' -f2 <"${leafKeyFile}.pub")"
				key::set_field "$keyName" "$keySlot" private "$keyPriv"
			else
				keygenFailed=1
			fi
		else
			printf '%s\n' "$keyPriv" >"$leafKeyFile"
			chmod 0400 "$leafKeyFile"
		fi
		keyPriv=""
		ndh::secret:end
		if ((keygenFailed == 1)); then
			log::error "failed to generate keypair for ${keyName}@${keySlot}"
			return 1
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

# Walk every key with an authority ref. For each GENERATION: its SSH certificates must be recorded
# (installed as they are), and a TLS leaf is signed and recorded back into the in-memory yaml
# (through repeated yq -i updates on the working copy $inputFile). A certificate belongs to the
# generation it certifies: during a renewal both generations are published and each one needs its own.
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
				case "$certUsage" in
					ssh-host | ssh-user)
						if [[ -z "$(yq::get ".keys.\"${keyName}\".slots.\"${keySlot}\".public // \"\"")" ]]; then
							log::error "${keyName}@${keySlot} ${certUsage}: no recorded material — record it on the operator seat (ssh-keys-renew), then sign it (ssh-keys-certify)"
							return 1
						fi
						if [[ -z "$(yq::get ".keys.\"${keyName}\".slots.\"${keySlot}\".certificates.\"${authorityName}\".\"${certUsage}\" // \"\"")" ]]; then
							log::error "${keyName}@${keySlot} ${certUsage}: its public is recorded but its certificate is not — run ssh-keys-certify on the operator seat"
							return 1
						fi
						continue
						;;
					tls-server) ;;
					*)
						log::error "unsupported cert_usage ${certUsage} for ${keyName}"
						return 1
						;;
				esac
				certLine="$(sign::tls_server "$keyName" "$keySlot" "$authorityName")" || return 1
				# Inject under .keys.<k>.slots.<slot>.certificates.<auth>.<cert_usage>.
				# yq -i with literal strings containing newlines/special chars
				# via env to avoid quoting issues.
				# Checked: the logger wrapper runs this script with errexit OFF.
				if ! env CERT="$certLine" yq -i "
					.keys.\"${keyName}\".slots.\"${keySlot}\".certificates.\"${authorityName}\".\"${certUsage}\" = strenv(CERT)
				" "$inputFile"; then
					log::error "cannot record the ${certUsage} certificate of ${keyName}@${keySlot}"
					return 1
				fi
			done
		done
	done
}

main() {
	if (($# < 2)); then
		log::error "usage: ssh-enrich-keys-yaml <inputYaml> <outputYaml> [<targetUser>]"
		return 64
	fi

	inputFile="$1"
	outputFile="$2"
	targetUser="${3:-${USER:-root}}"

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
