#!/usr/bin/env bats
# ssh-keys-certify against a real sops and a throwaway age key, in a throwaway git repository: an
# authority with two slots (the older compromised), a key with ssh-host + ssh-user, a TLS-only key.
# No private value is printed: the assertions read certificates, which are public.

setup() {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/modules/home-manager/ssh.d"
  git -C "$repo" init -q
  age-keygen -o "$BATS_TEST_TMPDIR/age.txt" 2>/dev/null
  export SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/age.txt"
  cat >"$repo/.sops.yaml" <<EOF
creation_rules:
  - path_regex: '.*'
    encrypted_comment_regex: 'sops:encrypted'
    age: $(age-keygen -y "$SOPS_AGE_KEY_FILE")
EOF
  cd "$BATS_TEST_TMPDIR"
  for n in ca-old ca-new host; do ssh-keygen -q -t ed25519 -N '' -f "$n" -C "$n"; done
  keys="$repo/modules/home-manager/ssh.d/keys.yaml"
  OLDPUB="$(cut -d' ' -f2 ca-old.pub)" OLDPRIV="$(<ca-old)" NEWPUB="$(cut -d' ' -f2 ca-new.pub)" NEWPRIV="$(<ca-new)" \
    HOSTPUB="$(cut -d' ' -f2 host.pub)" HOSTPRIV="$(<host)" yq eval -n '
      .authorities.fabric.type = "ssh-ed25519" |
      .authorities.fabric.usage = ["ssh-authority"] |
      .authorities.fabric.slots."26-01-01".public = strenv(OLDPUB) |
      .authorities.fabric.slots."26-01-01".private = strenv(OLDPRIV) |
      .authorities.fabric.slots."26-01-01".compromised = true |
      .authorities.fabric.slots."26-02-02".public = strenv(NEWPUB) |
      .authorities.fabric.slots."26-02-02".private = strenv(NEWPRIV) |
      .keys.host.type = "ssh-ed25519" |
      .keys.host.authority = "fabric" |
      .keys.host.cert_usage = ["ssh-host", "ssh-user"] |
      .keys.host.principals = {"operator": "operator", "deploy": "deploy"} |
      .keys.host.slots."26-03-03".public = strenv(HOSTPUB) |
      .keys.host.slots."26-03-03".private = strenv(HOSTPRIV) |
      .keys.relay.type = "ssh-ed25519" |
      .keys.relay.authority = "fabric" |
      .keys.relay.cert_usage = ["tls-server"] |
      .keys.relay.slots."26-03-03".public = strenv(HOSTPUB) |
      (.authorities.fabric.slots."26-01-01".private | key) headComment = "sops:encrypted" |
      (.authorities.fabric.slots."26-02-02".private | key) headComment = "sops:encrypted" |
      (.keys.host.slots."26-03-03".private | key) headComment = "sops:encrypted"
    ' >"$keys"
  (cd "$repo" && sops --input-type yaml --output-type yaml encrypt -i modules/home-manager/ssh.d/keys.yaml)
  # The real ndh::logger:command:run runs the command as `if "$@"` — errexit is OFF inside it — so the
  # stub does the same: a failure the script does not check would otherwise pass here and not there.
  printf 'ndh::logger:command:run() { shift; local rc=0; if "$@"; then :; else rc=$?; fi; return "$rc"; }\n' >"$BATS_TEST_TMPDIR/trampoline.sh"
  bake "alpha,alpha.lan,beta"
}

bake() { # <host names>
  sed -e "s#@nixBashTrampoline@#$BATS_TEST_TMPDIR/trampoline.sh#" -e 's#@loggerTag@#test#' -e "s#@hostPrincipals@#$1#" -e "s#@sshKeygen@#$(command -v ssh-keygen)#" \
    "$BATS_TEST_DIRNAME/../ssh-keys-certify.sh" >"$BATS_TEST_TMPDIR/ssh-keys-certify"
}

# keys.yaml's own rule names TWO recipients, the catch-all after it only one: the shape that let a
# temp-path encryption drop a recipient. `$1` = sync|nosync: re-key the fixture to its rule or not.
narrow_rule() {
  age-keygen -o "$BATS_TEST_TMPDIR/age2.txt" 2>/dev/null
  local first second
  first="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
  second="$(age-keygen -y "$BATS_TEST_TMPDIR/age2.txt")"
  cat >"$repo/.sops.yaml" <<EOF
creation_rules:
  - path_regex: '(^|/)modules/home-manager/ssh\.d/keys\.yaml$'
    encrypted_comment_regex: 'sops:encrypted'
    age: $first,$second
  - path_regex: '.*'
    encrypted_comment_regex: 'sops:encrypted'
    age: $first
EOF
  if [ "$1" = sync ]; then (cd "$repo" && sops updatekeys -y modules/home-manager/ssh.d/keys.yaml >/dev/null 2>&1); fi
}

recipients() { yq eval -r '.sops.age | length' "$keys"; }

certify() { (cd "$repo" && bash -euo pipefail "$BATS_TEST_TMPDIR/ssh-keys-certify" "$@"); }

cert() { # <usage> → describe the recorded certificate
  yq eval -r ".keys.host.slots.\"26-03-03\".certificates.fabric.\"$1\"" "$keys" >"$BATS_TEST_TMPDIR/c-cert.pub"
  ssh-keygen -L -f "$BATS_TEST_TMPDIR/c-cert.pub"
}

@test "a dry run lists what it would sign and changes nothing" {
  cp "$keys" before
  run certify
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing"*"host"*"ssh-host"*"fabric@26-02-02"* ]]
  [[ "$output" == *"missing"*"host"*"ssh-user"* ]]
  cmp "$keys" before
}

@test "--apply records a host certificate for the baked names, signed by the signing slot, valid forever" {
  run certify --apply
  [ "$status" -eq 0 ]
  run cert ssh-host
  [[ "$output" == *"host certificate"* ]]
  [[ "$output" == *"Signing CA: ED25519 $(ssh-keygen -lf ca-new.pub | awk '{print $2}')"* ]]
  [[ "$output" == *"Valid: forever"* ]]
  printf '%s\n' "$output" | awk '/Principals:/{f=1;next} /Critical Options:/{f=0} f{gsub(/^ +/,"");print}' | sort | paste -sd, - >names
  [ "$(cat names)" = "alpha,alpha.lan,beta" ]
}

@test "the user certificate carries the key's own principals" {
  certify --apply
  run cert ssh-user
  [[ "$output" == *"user certificate"* ]]
  printf '%s\n' "$output" | awk '/Principals:/{f=1;next} /Critical Options:/{f=0} f{gsub(/^ +/,"");print}' | sort | paste -sd, - >names
  [ "$(cat names)" = "deploy,operator" ]
}

@test "a TLS-only key is left to its own path" {
  certify --apply
  [ "$(yq eval -r '.keys.relay.slots."26-03-03".certificates // "none"' "$keys")" = none ]
}

@test "every private stays encrypted, and the certificates are in clear" {
  certify --apply
  [ "$(yq eval '[.keys[].slots[].private, .authorities[].slots[].private] | map(select(. != null)) | all_c(test("^ENC\["))' "$keys")" = true ]
  yq eval -r '.keys.host.slots."26-03-03".certificates.fabric."ssh-host"' "$keys" | grep -q '^ssh-ed25519-cert-v01@openssh.com '
}

@test "a second run finds everything current and leaves keys.yaml byte-identical" {
  certify --apply
  cp "$keys" after-first
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"every certificate is current"* ]]
  cmp "$keys" after-first
}

@test "a changed name list makes the host certificate stale, and only that one is re-signed" {
  certify --apply
  bake "alpha,alpha.lan,beta,gamma"
  run certify
  [[ "$output" == *"stale"*"ssh-host"* ]]
  [[ "$output" == *"current"*"ssh-user"* ]]
}

@test "no baked name refuses to run" {
  bake ""
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no host names were baked"* ]]
}

@test "--apply keeps keys.yaml's own rule's recipients, not the catch-all's" {
  narrow_rule sync
  [ "$(recipients)" = 2 ]
  run certify --apply
  [ "$status" -eq 0 ]
  [ "$(recipients)" = 2 ]
}

@test "a run that would change keys.yaml's recipients is refused, and changes nothing" {
  narrow_rule nosync
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"recipients would change"*"sops updatekeys"* ]]
  cmp "$keys" before
}

@test "a slot with no recorded public is reported as unrecorded, and nothing is recorded for it" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["ephemeral"]' \
    '{"type": "ssh-ed25519", "authority": "fabric", "cert_usage": ["ssh-host"], "slots": {"26-04-04": {}}}')
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecorded"*"ephemeral"*"generated and signed at activation"* ]]
  [ "$(yq eval -r '.keys.ephemeral.slots."26-04-04".certificates // "none"' "$keys")" = none ]
}

@test "a signature that fails stops the run and leaves keys.yaml untouched" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["broken"]' \
    '{"type": "ssh-ed25519", "authority": "fabric", "cert_usage": ["ssh-host"], "slots": {"26-04-04": {"public": "AAAAnotakey"}}}')
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"keys.yaml left untouched"* ]]
  cmp "$keys" before
}
