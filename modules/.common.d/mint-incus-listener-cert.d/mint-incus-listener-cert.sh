#!/usr/bin/env bash
# @codebase
# Mint the Incus LISTENER certificate for a bare-metal, signed by a keys.yaml TLS authority.
#
# Why this exists, measured 2026-09-30: both members of the Incus cluster serve the SAME
# certificate — it is the CLUSTER certificate, self-generated when a member joins — and its SAN is
# `DNS:<host>-nixos, IP:127.0.0.1, IP:::1`. Nothing else. It names NEITHER `nixos.<host>`, the FQDN
# every rke2lab `remote.endpoint` dials, NOR the member's own tailnet URL from `incus cluster list`.
# It works only because every consumer pins the LEAF, and that is the real cost: a pinned leaf makes
# the certificate unreplaceable, since each regeneration — a cold start does one — invalidates every
# pinned copy at once.
#
# So the fix is not a better self-signed cert. It is a leaf signed by an authority clients can trust
# by CA, after which the leaf is replaceable without touching a single consumer.
#
# Status 2026-10-01: a `mammoth-skate-tls` leaf IS installed — the self-signed era is over — but the
# first one carried ONE host's SAN, so only `nixos.bioskop` verifies by name. See the SAN block.
#
# ★ NOTHING SECRET TOUCHES THE DISK. `authority-bootstrap-tls-root` materialises the decrypted
# keys.yaml — and therefore every private key in the fleet — into a temp dir; that is the precedent
# and this deliberately does not follow it. `sops -d` is piped, the values live in shell variables,
# and step-cli receives the CA cert and key through PROCESS SUBSTITUTION (`/dev/fd/N`), verified to
# work with both `--ca` and `--ca-key`. The only pair written out is the LEAF, because
# `incus cluster update-certificate` takes two file arguments — that is its interface, not a choice.
#
# ★ The SAN set is CONSUMED, never retyped. Names come from `catalog.netplan.baremetal` (which
# itself consumes rke2lab's `lib.networkBlueprint.hostFacts` — one author for `nixos.<host>` and
# `<host>-nixos`) crossed with the catalog's own domains, plus `.local` for mDNS. Addresses come
# from the same catalog entries and from rke2lab's segments. Retyping any of them here would be a
# second place a name lives, which is how two spellings come to disagree.
#
# ★ The SAN covers the WHOLE FLEET, not the named host. One cert serves every member, so a
# per-host SAN mints a cert that half the cluster cannot be verified by name against — see the
# measurement at the SAN block below.
#
# ⚠️ The TAILNET carries a NAME and never an address: a tailnet address is assigned by the tailnet,
# so nothing declares it and a cert built on today's value would be wrong after a renew.
#
# ⚠️ This mints; it does not install. Replacing a live cluster's certificate is an operator act with
# a real failure mode — `incus cluster update-certificate` rewrites every member, and an interrupted
# run can leave members distrusting each other — so the command is PRINTED for a human to run when
# every member is ONLINE.
#
# Usage:
#   mint-incus-listener-cert <host> [--authority <name>] [--out-dir <dir>] [--days <n>]
#
# Preconditions:
#   - run from the ndh repo root (keys.yaml is read relative to it)
#   - keys.yaml decryptable with the current sops age key
#   - the authority advertises `tls-authority` in `usage:` and carries a minted `ca_crt`
#     (run `authority-bootstrap-tls-root <name>` first if it does not)

set -euo pipefail

log() { printf '[incus-cert] %s\n' "$*" >&2; }
die() {
	printf '[incus-cert] ERROR: %s\n' "$*" >&2
	exit 1
}

authority="mammoth-skate-tls"
outDir=""
days=365
host=""

while (($#)); do
	case $1 in
	--authority)
		authority="${2:?--authority needs a name}"
		shift 2
		;;
	--out-dir)
		outDir="${2:?--out-dir needs a path}"
		shift 2
		;;
	--days)
		days="${2:?--days needs a number}"
		shift 2
		;;
	-h | --help)
		# The header, DERIVED: from line 3 to whatever precedes `set -euo pipefail`. It used to be a
		# hard-coded range and it silently truncated the last precondition twice in one sitting —
		# every edit to the header moved the end, and nothing failed, it just said less.
		awk 'NR>=3 { if (/^set -euo pipefail$/) exit; print }' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*) die "unknown flag '$1' (try --help)" ;;
	*)
		[[ -n $host ]] && die "only one host at a time (got '$host' and '$1')"
		host="$1"
		shift
		;;
	esac
done

[[ -n $host ]] || die "which bare-metal? usage: mint-incus-listener-cert <host> [--authority <name>]"

repoRoot="$(git rev-parse --show-toplevel)" || die "not inside a git repo"
keysYaml="${repoRoot}/modules/home-manager/ssh.d/keys.yaml"
[[ -f $keysYaml ]] || die "keys.yaml not found at ${keysYaml} — run from the ndh repo root"

# --- The SAN set: the WHOLE FLEET, because ONE cert serves every member --------------------------
#
# ⚠️ Measured 2026-10-01 against the live cluster, and it is why this is a union and not one host's
# names. Both members present the SAME leaf — `CN=bioskop-nixos`, issuer `mammoth-skate-tls` — which
# is precisely what `incus cluster update-certificate` does: it installs ONE cluster certificate
# everywhere. The first version of this script derived the SAN from `baremetal.<host>` alone, so
# `nixos.nikopol` ended up serving a certificate that never names it:
#
#     openssl s_client -connect nixos.bioskop:8443 -verify_hostname nixos.bioskop  → Verification: OK
#     openssl s_client -connect nixos.nikopol:8443 -verify_hostname nixos.nikopol  → hostname mismatch
#
# Pinning HID that (`TLSServerCert` compares the leaf and never checks a name), and trusting the CA
# does not — so the very change that removes the pin is the one that exposes it. A cluster
# certificate must carry every member's name, or CA trust works on exactly one member.
log "reading the FLEET-WIDE SAN set from the catalog (one cert serves every member)"
bmAll="$(nix eval --json "${repoRoot}#catalog.netplan.baremetal" 2>/dev/null)" ||
	die "cannot read catalog.netplan.baremetal — refusing to mint a cert with an incomplete SAN"

mapfile -t fleetHosts < <(yq -p json 'keys | .[]' <<<"$bmAll")
((${#fleetHosts[@]})) || die "catalog.netplan.baremetal declares no bare-metal"
printf '%s\n' "${fleetHosts[@]}" | grep -qxF "$host" ||
	die "'${host}' is not a declared bare-metal (fleet: ${fleetHosts[*]})"

# The CN names the member this leaf is filed under; every member's names land in the SAN below.
hostname="$(h="$host" yq -p json '.[env(h)].nixosHostname // ""' <<<"$bmAll")"
[[ -n $hostname ]] ||
	die "catalog entry for '${host}' carries no nixosHostname — is rke2lab's hostFacts export pinned? (needs rke2lab a0acc778c or later)"

# Every domain the catalog declares, plus `.local` for mDNS — the same derivation the nixos module
# uses for server.crt, read from the same place rather than restated.
mapfile -t suffixes < <(
	nix eval --json "${repoRoot}#catalog.netplan" \
		--apply 'n: builtins.filter (d: d != null && d != "") (map (net: net.domain or "") (builtins.attrValues n))' 2>/dev/null |
		yq -p json '.[]' | sed 's/^\.//'
)

# Every member's names, and every member's fabric gateway + lan-br link end. A member missing from
# the catalog is FATAL rather than skipped: a cluster cert that silently omits one member is the
# defect this block exists to prevent, and it reads as success everywhere else.
sans=()
for h in "${fleetHosts[@]}"; do
	memberHostname="$(h="$h" yq -p json '.[env(h)].nixosHostname // ""' <<<"$bmAll")"
	memberFqdn="$(h="$h" yq -p json '.[env(h)].fabricFqdn // ""' <<<"$bmAll")"
	[[ -n $memberHostname && -n $memberFqdn ]] ||
		die "catalog entry for '${h}' carries no nixosHostname/fabricFqdn — refusing to mint a cluster cert that would not name every member"
	sans+=("$memberHostname" "$memberFqdn" "${memberHostname}.local")
	for s in "${suffixes[@]}"; do sans+=("${memberHostname}.${s}"); done
	# The tailnet is deliberately a NAME only (see the header).
	for key in netGateway hostAddress; do
		v="$(h="$h" k="$key" yq -p json '.[env(h)][env(k)] // ""' <<<"$bmAll")"
		[[ -n $v ]] && sans+=("$v")
	done
done
sans+=("127.0.0.1" "::1")

# ★ Every gateway this host owns — the per-cluster vmnet /21s (10.80.x.1, how a NODE reaches its
# host's Incus engine, measured OPEN from inside a cluster) and its baremetal fabric /21. Read from
# THIS catalog, which already unions rke2lab's segments: no detour through `inputs.rke2lab`, which is
# not an output attribute and so silently resolved to nothing.
#
# ⚠️ NO `|| true` here, deliberately. The first version swallowed that failed eval and produced an
# empty list, so the cert came out missing 10.80.0.1 and 10.80.8.1 while reporting success — a tool
# answering "less" instead of "I cannot", which is the exact failure this repo has been bitten by
# before. An unreadable segment list must stop the mint.
segmentsJson="$(nix eval --json "${repoRoot}#catalog.netplan.segments" 2>/dev/null)" ||
	die "cannot read catalog.netplan.segments — refusing to mint a cert with an incomplete SAN"
for h in "${fleetHosts[@]}"; do
	mapfile -t hostGateways < <(
		h="$h" yq -p json '.[] | select((.name // "") | test("^" + env(h) + "-")) | .gateway // ""' \
			<<<"$segmentsJson" | grep -E '^[0-9a-fA-F:.]+$'
	)
	((${#hostGateways[@]})) ||
		die "no segment gateway found for '${h}' — refusing to mint a cert with an incomplete SAN"
	sans+=("${hostGateways[@]}")
done

# De-duplicate, keeping order stable so two runs produce the same cert shape.
mapfile -t sans < <(printf '%s\n' "${sans[@]}" | awk 'NF && !seen[$0]++')
log "SAN set (${#sans[@]}): ${sans[*]}"

# --- The authority, never materialised ----------------------------------------------------------
log "reading authority '${authority}' from keys.yaml (piped, nothing written)"
decrypted="$(sops -d "$keysYaml")" || die "cannot decrypt keys.yaml — is the sops age key available?"

authUsage="$(yq eval -r ".authorities.\"${authority}\".usage // [] | join(\",\")" - <<<"$decrypted")"
[[ ,${authUsage}, == *,tls-authority,* ]] ||
	die "authority '${authority}' does not advertise tls-authority (usage: ${authUsage:-none})"

caCrt="$(yq eval -r ".authorities.\"${authority}\".ca_crt // \"\"" - <<<"$decrypted")"
[[ -n $caCrt ]] ||
	die "authority '${authority}' has no minted ca_crt — run: nix run .#authority-bootstrap-tls-root -- ${authority}"

caKey="$(yq eval -r ".authorities.\"${authority}\".slots // {} | to_entries | sort_by(.key) | .[-1].value.private // \"\"" - <<<"$decrypted")"
[[ -n $caKey ]] || die "authority '${authority}' has no private key in keys.yaml"

# --- Mint -------------------------------------------------------------------------------------
outDir="${outDir:-${repoRoot}/.local.d/incus-listener-cert/${host}}"
mkdir -p "$outDir"
crt="${outDir}/listener.crt"
key="${outDir}/listener.key"

sanArgs=()
for s in "${sans[@]}"; do sanArgs+=(--san "$s"); done

log "minting a ${days}d leaf for '${hostname}' from '${authority}'"
# The CA cert and key arrive as /dev/fd/N — no secret on disk. The LEAF pair is written because
# `incus cluster update-certificate` takes two paths; that is its interface.
step certificate create "$hostname" "$crt" "$key" \
	--ca <(printf '%s\n' "$caCrt") \
	--ca-key <(printf '%s\n' "$caKey") \
	--no-password --insecure \
	--not-after "$((days * 24))h" \
	"${sanArgs[@]}" >/dev/null || die "step certificate create failed"

chmod 600 "$key"
chmod 644 "$crt"

log "minted:"
step certificate inspect "$crt" --short 2>/dev/null | sed 's/^/    /' >&2 || true

cat <<INSTALL

The leaf is minted but NOT installed. Replacing a live cluster's certificate rewrites EVERY
member, and an interrupted run can leave them distrusting each other — so run this yourself,
with every member ONLINE (check: incus cluster list):

    incus cluster update-certificate ${crt} ${key}

⚠️ Do NOT try to put the CA into the identity Secrets' \`server-crt\`. Checked against the provider's
source 2026-10-01: cluster-api-provider-incus reads exactly
\`server, server-crt, client-crt, client-key, project, insecure-skip-verify\` — there is NO \`ca-crt\`
key — and it passes \`server-crt\` straight to the incus client's \`TLSServerCert\`, the PINNED remote
certificate (it even logs its fingerprint). Its own docs call that field "the cluster certificate".
A CA there would not match what the server presents.

The way OUT of pinning is the one the incus client documents:

    "Unless the remote server is trusted by the system CA, the remote certificate
     must be provided (TLSServerCert)."

So a CA-signed listener cert + the authority in the CONSUMER's trust store makes the pin
unnecessary — and the provider already accepts an empty \`server-crt\`. That is a change to how the
provider pod is deployed (a CA bundle it trusts), not to the Secret's contents.

Where that stands, measured 2026-10-01: a \`mammoth-skate-tls\` leaf IS installed on the cluster, and
\`nixos.bioskop\` verifies against the CA by name. \`nixos.nikopol\` did NOT — the first leaf carried
one host's SAN while the cluster serves it to every member — which is what the fleet-wide SAN above
fixes, so this needs ONE more \`update-certificate\` before CA trust holds on both members. Verify it
without guessing, per member:

    openssl s_client -connect nixos.<host>:8443 -servername nixos.<host> \\
      -CAfile <(ca-cert) -verify_hostname nixos.<host> </dev/null 2>&1 | grep Verification

Until every member verifies, do NOT drop \`server-crt\` from the identity Secrets: the pin is what is
holding the unnamed member together, and removing it is exactly what turns a hostname mismatch from
invisible into fatal.
INSTALL
