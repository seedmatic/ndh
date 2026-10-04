#!/usr/bin/env bats
#
# The slot resolver: which generation of a key entry the enrichment reads and
# writes. See docs/ssh-keys-renewal-spec.adoc for the model these cases encode.
#
# There is deliberately NO fallback to the flat `public`/`private` shape. An entry
# without `slots` is an error, not a legacy case — the repository migrates all or
# none, so a fallback would mean carrying two shapes forever and testing neither.

load helper

setup() {
  render_and_source "${BATS_TEST_DIRNAME}/../ssh-enrich-keys-yaml.sh"
}

two_slots() {
  write_fixture <<'YAML'
authorities:
  mammoth-skate:
    type: ssh-ed25519
    private: fake-authority-private
keys:
  rdp-host:
    type: ssh-ed25519
    authority: mammoth-skate
    slots:
      26-07-12: { public: older-public, private: older-private }
      26-10-04: { public: newer-public, private: newer-private }
YAML
}

@test "the newest slot is the later date, whatever the document order" {
  write_fixture <<'YAML'
keys:
  rdp-host:
    slots:
      26-10-04: { public: newer-public }
      26-07-12: { public: older-public }
YAML
  run key::newest_slot rdp-host
  [ "$status" -eq 0 ]
  [ "$output" = "26-10-04" ]
}

@test "a single slot is the newest slot" {
  write_fixture <<'YAML'
keys:
  rdp-host:
    slots:
      26-10-04: { public: only-public }
YAML
  run key::newest_slot rdp-host
  [ "$status" -eq 0 ]
  [ "$output" = "26-10-04" ]
}

@test "an entry with no slots FAILS — there is no flat fallback" {
  write_fixture <<'YAML'
keys:
  rdp-host:
    type: ssh-ed25519
    public: flat-public
    private: flat-private
YAML
  run key::newest_slot rdp-host
  [ "$status" -ne 0 ]
  [[ "$output" == *"no slots"* ]]
}

@test "material is read from the newest slot, never from the older one" {
  two_slots
  run key::slot_field rdp-host public
  [ "$status" -eq 0 ]
  [ "$output" = "newer-public" ]

  run key::slot_field rdp-host private
  [ "$status" -eq 0 ]
  [ "$output" = "newer-private" ]
}

@test "an empty newest slot yields empty material, which is how a renewal is requested" {
  write_fixture <<'YAML'
keys:
  rdp-host:
    slots:
      26-07-12: { public: older-public, private: older-private }
      26-10-04: {}
YAML
  run key::newest_slot rdp-host
  [ "$output" = "26-10-04" ]

  run key::slot_field rdp-host public
  [ "$status" -eq 0 ]
  [ -z "${output}" ] || [ "$output" = "null" ]
}

@test "slots are counted, because the count IS the renewal state" {
  two_slots
  run key::slots_count rdp-host
  [ "$output" = "2" ]
}

@test "one slot is settled and two is a renewal in flight — both accepted" {
  write_fixture <<'YAML'
keys:
  a: { slots: { 26-10-04: { public: p } } }
  b: { slots: { 26-07-12: { public: p }, 26-10-04: { public: q } } }
YAML
  run key::assert_slots a
  [ "$status" -eq 0 ]
  run key::assert_slots b
  [ "$status" -eq 0 ]
}

@test "three slots is refused, loudly — phase 2 is not optional" {
  write_fixture <<'YAML'
keys:
  rdp-host:
    slots:
      26-05-01: { public: a }
      26-07-12: { public: b }
      26-10-04: { public: c }
YAML
  run key::assert_slots rdp-host
  [ "$status" -ne 0 ]
  [[ "$output" == *"at most two"* ]]
}

@test "YY-MM-DD slot keys stay strings, so yq does not re-serialise them" {
  two_slots
  run yq -r '.keys."rdp-host".slots | keys | .[] | tag' "$inputFile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"!!str"* ]]
  [[ "$output" != *"!!timestamp"* ]]
}

# --- authorities carry generations too, and they are the ones that most need the
# --- overlap: trusted-user-ca.pub concatenates every *-ca.pub, so two authority
# --- generations are both trusted while leaves move across.

@test "an authority resolves its newest slot like a key does" {
  write_fixture <<'YAML'
authorities:
  mammoth-skate:
    type: ssh-ed25519
    slots:
      26-07-12: { public: older, private: older-priv }
      26-10-04: { public: newer, private: newer-priv }
YAML
  run authority::newest_slot mammoth-skate
  [ "$status" -eq 0 ]
  [ "$output" = "26-10-04" ]

  run authority::slot_field mammoth-skate private
  [ "$output" = "newer-priv" ]
}

@test "an authority with no slots FAILS — same rule, no flat fallback" {
  write_fixture <<'YAML'
authorities:
  mammoth-skate: { type: ssh-ed25519, private: flat-priv }
YAML
  run authority::newest_slot mammoth-skate
  [ "$status" -ne 0 ]
  [[ "$output" == *"no slots"* ]]
}

@test "three authority slots is refused too" {
  write_fixture <<'YAML'
authorities:
  mammoth-skate:
    slots:
      26-05-01: { public: a }
      26-07-12: { public: b }
      26-10-04: { public: c }
YAML
  run authority::assert_slots mammoth-skate
  [ "$status" -ne 0 ]
  [[ "$output" == *"at most two"* ]]
}
