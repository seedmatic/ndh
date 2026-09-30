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
# ★ NOTHING SECRET TOUCHES THE DISK. `authority-bootstrap-tls-root` materialises the decrypted
# keys.yaml — and therefore every private key in the fleet — into a temp dir; that is the precedent
# and this deliberately does not follow it. `sops -d` is piped, the values live in shell variables,
# and step-cli receives the CA cert and key through PROCESS SUBSTITUTION (`/dev/fd/N`), verified to
# work with both `--ca` and `--ca-key`. The only pair written out is the LEAF, because
# `incus cluster update-certificate` takes two file arguments — that is its interface, not a choice.
#
# ★ The SAN set is CONSUMED, never retyped. Names come from `catalog.netplan.baremetal.<host>`
# (which itself consumes rke2lab's `lib.networkBlueprint.hostFacts` — one author for `nixos.<host>`
# and `<host>-nixos`) crossed with the catalog's own domains, plus `.local` for mDNS. Addresses come
# from the same catalog entry and from rke2lab's segments. Retyping any of them here would be a
# second place a name lives, which is how two spellings come to disagree.
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
		sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'
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

# --- The SAN set, read off the catalog (one authority per name) ---------------------------------
log "reading the SAN set for '${host}' from the catalog"
bm="$(nix eval --json "${repoRoot}#catalog.netplan.baremetal.${host}" 2>/dev/null)" ||
	die "no catalog.netplan.baremetal.${host} — is '${host}' a declared bare-metal?"

hostname="$(jq -r '.nixosHostname // empty' <<<"$bm")"
fabricFqdn="$(jq -r '.fabricFqdn // empty' <<<"$bm")"
[[ -n $hostname && -n $fabricFqdn ]] ||
	die "catalog entry for '${host}' carries no nixosHostname/fabricFqdn — is rke2lab's hostFacts export pinned? (needs rke2lab a0acc778c or later)"

# Every domain the catalog declares, plus `.local` for mDNS — the same derivation the nixos module
# uses for server.crt, read from the same place rather than restated.
mapfile -t suffixes < <(
	nix eval --json "${repoRoot}#catalog.netplan" \
		--apply 'n: builtins.filter (d: d != null && d != "") (map (net: net.domain or "") (builtins.attrValues n))' 2>/dev/null |
		jq -r '.[]' | sed 's/^\.//'
)

sans=("$hostname" "$fabricFqdn" "${hostname}.local")
for s in "${suffixes[@]}"; do sans+=("${hostname}.${s}"); done

# Addresses: this host's fabric gateway and its lan-br link end, plus loopback. The tailnet is
# deliberately a NAME only (see the header).
for key in netGateway hostAddress; do
	v="$(jq -r --arg k "$key" '.[$k] // empty' <<<"$bm")"
	[[ -n $v ]] && sans+=("$v")
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
mapfile -t hostGateways < <(
	jq -r --arg h "$host" '.[] | select((.name // "") | startswith($h + "-")) | .gateway // empty' 		<<<"$segmentsJson" | grep -E '^[0-9a-fA-F:.]+$'
)
((${#hostGateways[@]})) ||
	die "no segment gateway found for '${host}' — refusing to mint a cert with an incomplete SAN"
sans+=("${hostGateways[@]}")

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

caKey="$(yq eval -r ".authorities.\"${authority}\".private // \"\"" - <<<"$decrypted")"
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

Then, so consumers stop pinning the leaf, the identity Secrets must carry the CA instead. Read it
with:

    sops -d ${keysYaml} | yq eval -r '.authorities."${authority}".ca_crt' -

⚠️ Until that last step lands, every consumer still pins the leaf — so this reissue invalidates the
pinned copies exactly as before. The gain arrives only when trust moves to the CA.
INSTALL
