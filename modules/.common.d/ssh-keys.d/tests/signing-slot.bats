#!/usr/bin/env bats
#
# The one signing rule of an authority (keys.schema.yaml, authoritySlots): the
# OLDEST slot that is not `compromised` signs, and it is the slot whose `ca_crt` a
# TLS leaf chains to. A renewal in flight is two real generations here, each with
# its own private and its own root, so the chain is verified, not assumed.

load helper

setup() {
  render_and_source "${BATS_TEST_DIRNAME}/../ssh-enrich-keys-yaml.sh"
  tmpdir="${BATS_TEST_TMPDIR}/work"
  mkdir -p "$tmpdir"

  local gen
  for gen in old new; do
    ssh-keygen -q -t ecdsa -b 256 -N "" -f "${BATS_TEST_TMPDIR}/${gen}-ca" -C "${gen}@test-tls"
    step certificate create test-tls "${BATS_TEST_TMPDIR}/${gen}-root.crt" "${BATS_TEST_TMPDIR}/${gen}-root.unused" \
      --profile root-ca --key "${BATS_TEST_TMPDIR}/${gen}-ca" --no-password --insecure >/dev/null 2>&1
  done
}

# Two generations of a tls-authority and one leaf that asks for a tls-server cert.
# $1, when given, is the reason the OLD slot is marked compromised; $2 the new one's.
two_generation_fixture() {
  local yaml
  yaml="$(OLD_PRIV="$(<"${BATS_TEST_TMPDIR}/old-ca")" NEW_PRIV="$(<"${BATS_TEST_TMPDIR}/new-ca")" \
    OLD_CRT="$(<"${BATS_TEST_TMPDIR}/old-root.crt")" NEW_CRT="$(<"${BATS_TEST_TMPDIR}/new-root.crt")" \
    OLD_BAD="${1:-}" NEW_BAD="${2:-}" yq --null-input '
    {
      "authorities": { "test-tls": {
        "type": "ecdsa-sha2-nistp256",
        "usage": [ "tls-authority" ],
        "slots": {
          "26-07-01": { "private": strenv(OLD_PRIV), "ca_crt": strenv(OLD_CRT) },
          "26-10-01": { "private": strenv(NEW_PRIV), "ca_crt": strenv(NEW_CRT) }
        }
      } },
      "keys": { "leaf": {
        "type": "ssh-ed25519",
        "authority": "test-tls",
        "comment": "leaf@test",
        "cert_usage": [ "tls-server" ],
        "tls": { "common_name": "leaf.test" },
        "slots": { "26-10-01": {} }
      } }
    }
    | with(select(strenv(OLD_BAD) != ""); .authorities."test-tls".slots."26-07-01".compromised = strenv(OLD_BAD))
    | with(select(strenv(NEW_BAD) != ""); .authorities."test-tls".slots."26-10-01".compromised = strenv(NEW_BAD))')"
  write_fixture <<<"$yaml"
}

leaf_cert() {
  sign::tls_server leaf 26-10-01 test-tls >"${BATS_TEST_TMPDIR}/leaf.crt"
}

@test "a TLS leaf chains to the root of the slot that signed it — the oldest" {
  two_generation_fixture
  [ "$(authority::signing_slot test-tls)" = "26-07-01" ]
  leaf_cert
  step certificate verify "${BATS_TEST_TMPDIR}/leaf.crt" --roots "${BATS_TEST_TMPDIR}/old-root.crt"
  run step certificate verify "${BATS_TEST_TMPDIR}/leaf.crt" --roots "${BATS_TEST_TMPDIR}/new-root.crt"
  [ "$status" -ne 0 ]
}

@test "a compromised oldest slot never signs — the newer one signs at once" {
  two_generation_fixture "private published"
  [ "$(authority::signing_slot test-tls)" = "26-10-01" ]
  leaf_cert
  step certificate verify "${BATS_TEST_TMPDIR}/leaf.crt" --roots "${BATS_TEST_TMPDIR}/new-root.crt"
  run step certificate verify "${BATS_TEST_TMPDIR}/leaf.crt" --roots "${BATS_TEST_TMPDIR}/old-root.crt"
  [ "$status" -ne 0 ]
}

@test "when every slot is compromised, nothing signs" {
  two_generation_fixture "private published" "private published"
  run authority::signing_slot test-tls
  [ "$status" -ne 0 ]
  run sign::tls_server leaf 26-10-01 test-tls
  [ "$status" -ne 0 ]
}

# Batch 1's flip traces every script: signing a leaf is traced, and both windows (the authority's private, the leaf
# born and recorded) keep every private out of the trace.
@test "traced, a TLS leaf's signing carries the run and no private" {
  two_generation_fixture
  (set -x; sign::tls_server leaf 26-10-01 test-tls >"${BATS_TEST_TMPDIR}/leaf.crt") 2>"${BATS_TEST_TMPDIR}/trace"
  step certificate verify "${BATS_TEST_TMPDIR}/leaf.crt" --roots "${BATS_TEST_TMPDIR}/old-root.crt"
  grep -qF 'secret window: the leaf' "${BATS_TEST_TMPDIR}/trace"
  grep -qF 'secret window: the authority' "${BATS_TEST_TMPDIR}/trace"
  run ! grep -qF -f <(sed -n 2p "${BATS_TEST_TMPDIR}/old-ca") "${BATS_TEST_TMPDIR}/trace"
  run ! grep -qF -f <(sed -n 2p "${tmpdir}/leaf@26-10-01") "${BATS_TEST_TMPDIR}/trace"
  run ! grep -q 'PRIVATE KEY' "${BATS_TEST_TMPDIR}/trace"
}
