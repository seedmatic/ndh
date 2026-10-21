#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ★ xtrace-guard — no trace, whatever the invocation (bash -x, an inherited SHELLOPTS=xtrace, a
# caller's set -x): this script handles private keys, and a trace prints every value it expands.
case $- in *x*) { set +x; } 2>/dev/null; echo "[xtrace-guard] xtrace disabled: this script handles private keys" >&2 ;; esac
export -n SHELLOPTS 2>/dev/null || true # readonly in bash, so not unset; un-exported, it stops at this process
unset NDH_LOGGER_XTRACE # ndh::logger:command:run traces its command only when this is 1
unset BASH_XTRACEFD 2>/dev/null || true
# The fleet's key revocation list (KRL), built at evaluation from keys.yaml's public fields as
# keys-yaml.nix extracts them: sshd's RevokedKeys and every client's RevokedHostKeys.
#
#   revoked                every public, refused raw and as the key of a certificate; an authority's
#                          public takes every certificate it signed
#   revoked_certificates   ONE certificate, by its exact key id, under the authority slot that signed
#                          it (roles × keys S3a K1): its key stays valid, and so does any other
#                          certificate of it, the union host certificate's case
#
# Never by serial (K2): every certificate signed before S3a has serial 0, so a `serial: 0` line would
# cut them all. Refused, as is a live recorded certificate sharing a revoked id (it would be cut with
# it), and an id ssh-keygen would read as another (a `#` starts its comment, edge spaces are trimmed).
#
# Usage: krl.sh <keys.yaml extraction, JSON> <out>

readonly json="$1" out="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
	echo "ndh.keysYaml KRL: $*" >&2
	exit 1
}

field() { # <revoked certificate name> <field>
	NAME="$1" yq -r ".revoked_certificates[strenv(NAME)].${2} // \"\"" "$json"
}

declare -A revokedIds=()

yq -r '(.revoked // {}) | to_entries[] | .value.type + " " + .value.public + " revoked:" + .key' "$json" >"$work/keys.spec"

while IFS= read -r name; do
	[[ -n "$name" ]] || continue
	id="$(field "$name" key_id)"
	authority="$(field "$name" authority)"
	slot="$(field "$name" authority_slot)"
	[[ -n "$id" ]] || fail "revoked_certificates.${name}: no key_id"
	if [[ "$id" == *"#"* || "$id" =~ ^[[:space:]] || "$id" =~ [[:space:]]$ || "$id" == *[[:cntrl:]]* ]]; then
		fail "revoked_certificates.${name}: its key id holds a '#', a control character or edge spaces, which ssh-keygen would read as another id"
	fi
	caPublic="$(A="$authority" S="$slot" yq -r '.authorities[strenv(A)].slots[strenv(S)].public // .revoked[strenv(A) + "@" + strenv(S)].public // ""' "$json")"
	caType="$(A="$authority" S="$slot" yq -r '.authorities[strenv(A)].type // .revoked[strenv(A) + "@" + strenv(S)].type // "ssh-ed25519"' "$json")"
	[[ -n "$caPublic" ]] || fail "revoked_certificates.${name}: no public for its authority ${authority}@${slot}, in authorities or revoked"
	printf '%s %s %s@%s\n' "$caType" "$caPublic" "$authority" "$slot" >"$work/ca-${authority}@${slot}.pub"
	printf 'id: %s\n' "$id" >>"$work/ca-${authority}@${slot}.spec"
	revokedIds["$id"]="$name"
done < <(yq -r '(.revoked_certificates // {}) | keys | .[]' "$json")

if grep -Eiq '^[[:space:]]*serial:[[:space:]]*0+([[:space:]]|-|$)' "$work"/*.spec; then
	fail "a line revokes serial 0, which every certificate signed before S3a carries"
fi

while IFS=$'\t' read -r where cert; do
	[[ -n "$cert" ]] || continue
	id="$(printf '%s\n' "$cert" | ssh-keygen -L -f - | awk '/^ *Key ID:/ { sub(/^ *Key ID: "/, ""); sub(/"$/, ""); print }')" ||
		fail "${where}: its recorded certificate cannot be read"
	[[ -n "$id" ]] || fail "${where}: its recorded certificate has no key id"
	# Not `-v revokedIds[...]`: the ids are JSON, and a `]` in one ends that subscript early.
	if [[ -n "${revokedIds[$id]+set}" ]]; then
		fail "${where}: its recorded certificate has the key id revoked_certificates.${revokedIds[$id]} revokes — it would be cut with it"
	fi
done < <(yq -r '(.keys // {}) | to_entries[] | .key as $k | (.value.slots // {}) | to_entries[] | .key as $s | (.value.certificates // {}) | to_entries[] | .key as $a | .value | to_entries[] | select(.value | tag == "!!str") | ($k + "@" + $s + " " + $a + " " + .key) + "\t" + .value' "$json")

ssh-keygen -k -f "$work/krl" "$work/keys.spec"
# ssh-keygen stamps the header's generated_date (PROTOCOL.krl: a uint64 after the magic, the format version and
# krl_version, so bytes 20-27) with the time of the build, and honours no SOURCE_DATE_EPOCH: the same revocations
# would give a new file, and every host a new closure, at each rebuild. Zeroed, here and after each -u merge, the
# list is a function of keys.json alone; nothing reads the date to decide.
reproducible() {
	[[ "$(head -c 8 "$work/krl" | od -An -tx1 | tr -d ' \n')" == 5353484b524c0a00 ]] || fail "the built list has no KRL magic"
	printf '\0\0\0\0\0\0\0\0' | dd of="$work/krl" bs=1 seek=20 count=8 conv=notrunc status=none
}
reproducible
for spec in "$work"/ca-*.spec; do
	[[ -e "$spec" ]] || continue
	ssh-keygen -k -u -s "${spec%.spec}.pub" -f "$work/krl" "$spec"
	reproducible
done

# What was asked is what was built: every public reads as revoked, every id is listed.
while IFS= read -r line; do
	[[ -n "$line" ]] || continue
	printf '%s\n' "$line" >"$work/check.pub"
	if ssh-keygen -Q -f "$work/krl" "$work/check.pub" >/dev/null; then
		fail "${line##* }: not revoked by the built list"
	fi
done <"$work/keys.spec"
ssh-keygen -Q -l -f "$work/krl" >"$work/listing"
for id in "${!revokedIds[@]}"; do
	grep -Fxq "id: ${id}" "$work/listing" || fail "revoked_certificates.${revokedIds[$id]}: its key id is not in the built list"
done

install -m 0444 "$work/krl" "$out"
