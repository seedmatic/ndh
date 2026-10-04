#!/usr/bin/env bats
#
# The split expression: which FILES a generation becomes.
#
# The rule it encodes (docs/ssh-keys-renewal-spec.adoc): the PRESENTED generation
# — the newest slot — keeps the canonical name, and every other generation takes
# a `-<slot>` segment. A settled entry therefore produces exactly the file set it
# produced before slots existed, and the extra files appear only while a renewal
# is in flight.
#
# The names matter because two aggregators glob them: both platforms rebuild
# trusted-user-ca.pub from `*-ca.pub` on every activation, so a second authority
# generation joins the trust set with no change on either side.

SPLIT_EXP="${BATS_TEST_DIRNAME}/../../../home-manager/ssh-key.d/ssh-extract-keys.split-exp.yq"

setup() {
  [ -r "$SPLIT_EXP" ]
  tmp="$BATS_TEST_TMPDIR"
}

# Run the split expression and print "<target_dir> <rel_path>" for every artefact
# whose content is non-empty — the trailing `select` in the expression is what
# drops the empty ones, so this mirrors what the extractor actually writes.
artefacts() {
  local out="${tmp}/split"
  rm -rf "$out"
  mkdir -p "$out"
  env TMPDIR="${out}/" yq eval --from-file "$SPLIT_EXP" "$1" -s '.yamlfile' >/dev/null
  local f content
  for f in "$out"/*; do
    content="$(yq -r '.content // ""' "$f")"
    [[ -n "$content" && "$content" != "null" ]] || continue
    printf '%s %s\n' "$(yq -r '.target_dir' "$f")" "$(yq -r '.rel_path' "$f")"
  done | sort
}

one_slot() {
  cat >"${tmp}/keys.yaml" <<'YAML'
authorities:
  mammoth-skate:
    type: ssh-ed25519
    comment: ca
    slots:
      26-05-29: { public: AUTHPUBLIC }
keys:
  rdp-host:
    type: ssh-ed25519
    comment: host
    slots:
      26-05-29: { public: NEWPUBLIC, private: NEWPRIVATE }
YAML
  printf '%s\n' "${tmp}/keys.yaml"
}

two_slots() {
  cat >"${tmp}/keys.yaml" <<'YAML'
authorities:
  mammoth-skate:
    type: ssh-ed25519
    comment: ca
    slots:
      26-05-29: { public: OLDAUTHPUBLIC }
      26-10-04: { public: NEWAUTHPUBLIC }
keys:
  rdp-host:
    type: ssh-ed25519
    comment: host
    slots:
      26-05-29: { public: OLDPUBLIC, private: OLDPRIVATE }
      26-10-04: { public: NEWPUBLIC, private: NEWPRIVATE }
YAML
  printf '%s\n' "${tmp}/keys.yaml"
}

@test "a settled entry produces the canonical names and nothing else" {
  run artefacts "$(one_slot)"
  [ "$status" -eq 0 ]
  [ "$output" = "system mammoth-skate-ca.pub
system-private rdp-host
user rdp-host.pub" ]
}

@test "a renewal in flight materialises BOTH generations" {
  run artefacts "$(two_slots)"
  [ "$status" -eq 0 ]
  [ "$output" = "system mammoth-skate-26-05-29-ca.pub
system mammoth-skate-ca.pub
system-private rdp-host
system-private rdp-host-26-05-29
user rdp-host-26-05-29.pub
user rdp-host.pub" ]
}

@test "the canonical name carries the NEWEST generation, not the first written" {
  local src
  src="$(two_slots)"
  local out="${tmp}/split"
  rm -rf "$out"; mkdir -p "$out"
  env TMPDIR="${out}/" yq eval --from-file "$SPLIT_EXP" "$src" -s '.yamlfile' >/dev/null

  # rdp-host (canonical) must hold the 26-10-04 material, and the suffixed file
  # the 26-05-29 one. Getting this backwards would publish the retiring key as
  # the presented identity — the exact failure the dated slots exist to prevent.
  run yq -r '.content' "${out}/rdp-host.yaml"
  [ "$output" = "NEWPRIVATE" ]
  run yq -r '.content' "${out}/rdp-host-26-05-29.yaml"
  [ "$output" = "OLDPRIVATE" ]
}

@test "the public line is rebuilt as type + blob + comment, once each" {
  local src
  src="$(one_slot)"
  local out="${tmp}/split"
  rm -rf "$out"; mkdir -p "$out"
  env TMPDIR="${out}/" yq eval --from-file "$SPLIT_EXP" "$src" -s '.yamlfile' >/dev/null

  run yq -r '.content' "${out}/rdp-host-public.yaml"
  [ "$output" = "ssh-ed25519 NEWPUBLIC host" ]
}

@test "a slot with no public yields no .pub artefact, not an empty one" {
  cat >"${tmp}/empty.yaml" <<'YAML'
authorities:
  mammoth-skate:
    type: ssh-ed25519
    slots:
      26-05-29: { public: AUTHPUBLIC }
keys:
  pending:
    type: ssh-ed25519
    slots:
      26-10-04: {}
YAML
  run artefacts "${tmp}/empty.yaml"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pending"* ]]
}
