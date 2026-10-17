#!/usr/bin/env bats
# ssh-keys-certify against a real sops and a throwaway age key, in a throwaway git repository: an
# authority with two slots (the older compromised), a key with ssh-user, a TLS-only key, a
# machine's public-only host key (host-alpha) and the shared interim host key (rdp-host).
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
  for n in ca-old ca-new host alpha alphan rdp; do ssh-keygen -q -t ed25519 -N '' -f "$n" -C "$n"; done
  keys="$repo/modules/home-manager/ssh.d/keys.yaml"
  OLDPUB="$(cut -d' ' -f2 ca-old.pub)" OLDPRIV="$(<ca-old)" NEWPUB="$(cut -d' ' -f2 ca-new.pub)" NEWPRIV="$(<ca-new)" \
    HOSTPUB="$(cut -d' ' -f2 host.pub)" HOSTPRIV="$(<host)" ALPHAPUB="$(cut -d' ' -f2 alpha.pub)" ALPHANPUB="$(cut -d' ' -f2 alphan.pub)" RDPPUB="$(cut -d' ' -f2 rdp.pub)" \
    yq eval -n '
      .authorities.fabric.type = "ssh-ed25519" |
      .authorities.fabric.usage = ["ssh-authority"] |
      .authorities.fabric.slots."26-01-01".public = strenv(OLDPUB) |
      .authorities.fabric.slots."26-01-01".private = strenv(OLDPRIV) |
      .authorities.fabric.slots."26-01-01".compromised = true |
      .authorities.fabric.slots."26-02-02".public = strenv(NEWPUB) |
      .authorities.fabric.slots."26-02-02".private = strenv(NEWPRIV) |
      .keys.host.type = "ssh-ed25519" |
      .keys.host.authority = "fabric" |
      .keys.host.cert_usage = ["ssh-user"] |
      .keys.host.principals = {"operator": "operator", "deploy": "deploy"} |
      .keys.host.slots."26-03-03".public = strenv(HOSTPUB) |
      .keys.host.slots."26-03-03".private = strenv(HOSTPRIV) |
      .keys.relay.type = "ssh-ed25519" |
      .keys.relay.authority = "fabric" |
      .keys.relay.cert_usage = ["tls-server"] |
      .keys.relay.slots."26-03-03".public = strenv(HOSTPUB) |
      .keys."host-alpha".type = "ssh-ed25519" |
      .keys."host-alpha".authority = "fabric" |
      .keys."host-alpha".cert_usage = ["ssh-host"] |
      .keys."host-alpha".slots."26-03-03".public = strenv(ALPHAPUB) |
      .keys."host-alpha-nixos".type = "ssh-ed25519" |
      .keys."host-alpha-nixos".authority = "fabric" |
      .keys."host-alpha-nixos".cert_usage = ["ssh-host"] |
      .keys."host-alpha-nixos".slots."26-03-03".public = strenv(ALPHANPUB) |
      .keys."rdp-host".type = "ssh-ed25519" |
      .keys."rdp-host".authority = "fabric" |
      .keys."rdp-host".cert_usage = ["ssh-host"] |
      .keys."rdp-host".slots."26-03-03".public = strenv(RDPPUB) |
      (.authorities.fabric.slots."26-01-01".private | key) headComment = "sops:encrypted" |
      (.authorities.fabric.slots."26-02-02".private | key) headComment = "sops:encrypted" |
      (.keys.host.slots."26-03-03".private | key) headComment = "sops:encrypted"
    ' >"$keys"
  (cd "$repo" && sops --input-type yaml --output-type yaml encrypt -i modules/home-manager/ssh.d/keys.yaml)
  # The stub runs the command the way the real ndh::logger:command:run does — through its
  # ndh::logger:command:invoke, sourced from the real logger — without its log sinks: a failure the
  # script does not check behaves here as it does there.
  printf 'source "%s"\nndh::logger:command:run() { shift; ndh::logger:command:invoke "$@"; return "$NDH_LOGGER_COMMAND_RC"; }\n' "$NDH_LOGGER_SH" >"$BATS_TEST_TMPDIR/trampoline.sh"
  bake "$FLEET"
}

# alpha, beta and their guests; beta plays nikopol, whose machines the interim key is certified for,
# alpha bioskop, whose machines must serve their own host keys before the interim replaces the union.
# OWN: the machines whose configuration has ndh.hostKey.own on, by default both of alpha's.
OWN="alpha alpha-nixos"
FLEET="alpha=alpha,alpha.lan alpha-nixos=alpha-nixos,nixos.alpha beta=beta,beta.lan beta-nixos=beta-nixos,nixos.beta"
# The names the union host certificate signed before S3a carried: a recorded certificate's, never signed now.
UNION="alpha,alpha-nixos,alpha.lan,beta,beta-nixos,beta.lan,nixos.alpha,nixos.beta"

bake() { # <machine=names …> [own machines]
  sed -e "s#@nixBashTrampoline@#$BATS_TEST_TMPDIR/trampoline.sh#" -e 's#@loggerTag@#test#' -e "s#@hostNames@#$1#" \
    -e 's#@interimKey@#rdp-host#' -e 's#@interimMachines@#beta beta-nixos#' -e "s#@ownMachines@#${2-$OWN}#" \
    -e "s#@sha256sum@#$(command -v sha256sum)#" -e "s#@sshKeygen@#$(command -v ssh-keygen)#" \
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

cert() { # <key> <usage> → describe the recorded certificate
  yq eval -r ".keys.\"$1\".slots.\"26-03-03\".certificates.fabric.\"$2\"" "$keys" | ssh-keygen -L -f -
}

names() { # <key> <usage> → its principals, sorted, comma-separated
  cert "$1" "$2" | awk '/Principals:/{f=1;next} /Critical Options:/{f=0} f{gsub(/^ +/,"");print}' | LC_ALL=C sort | paste -sd, -
}

key_id() { cert "$1" "$2" | awk '/Key ID:/ { sub(/^[^"]*"/, ""); sub(/"$/, ""); print }'; }

serial() { cert "$1" "$2" | awk '/Serial:/ { print $2 }'; }

# A certificate as recorded before S3a: the bare {marker, owner, key, usage} id, every fleet name.
record_legacy() { # <key> <public file> <serial> <ca private>
  ssh-keygen -q -s "$4" -h -I "{\"marker\":\"ndh-ssh-key-meta-v1\",\"owner\":\"home-manager.ssh-add-keys\",\"key\":\"$1\",\"usage\":[\"ssh-host\"]}" \
    -z "$3" -n "$UNION" "$2"
  local c
  c="$(<"${2%.pub}-cert.pub")"
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml "[\"keys\"][\"$1\"][\"slots\"][\"26-03-03\"][\"certificates\"]" \
    "{\"fabric\": {\"ssh-host\": \"$c\"}}")
}

@test "a dry run lists what it would sign and changes nothing" {
  cp "$keys" before
  run certify
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing"*"host"*"ssh-host"*"fabric@26-02-02"* ]]
  [[ "$output" == *"missing"*"host"*"ssh-user"* ]]
  cmp "$keys" before
}

@test "--apply records a host certificate signed by the signing slot, valid forever" {
  run certify --apply
  [ "$status" -eq 0 ]
  run cert host-alpha ssh-host
  [[ "$output" == *"host certificate"* ]]
  [[ "$output" == *"Signing CA: ED25519 $(ssh-keygen -lf ca-new.pub | awk '{print $2}')"* ]]
  [[ "$output" == *"Valid: forever"* ]]
}

@test "an ssh-host key that is neither host-<machine> nor the interim key is refused, and nothing is signed" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["nix-store"]' \
    "{\"type\": \"ssh-ed25519\", \"authority\": \"fabric\", \"cert_usage\": [\"ssh-host\"], \"slots\": {\"26-03-03\": {\"public\": \"$(cut -d' ' -f2 host.pub)\"}}}")
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"nix-store: an ssh-host key is host-<machine> or rdp-host"* ]]
  [[ "$output" != *"signed "* ]]
  cmp "$keys" before
}

@test "a machine's host key gets exactly its machine's names" {
  certify --apply
  [ "$(names host-alpha ssh-host)" = "alpha,alpha.lan" ]
}

@test "the interim key gets nikopol's machines only, never another machine's" {
  certify --apply
  [ "$(names rdp-host ssh-host)" = "beta,beta-nixos,beta.lan,nixos.beta" ]
}

@test "a host key of a machine the build does not know is refused, and nothing is signed" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["host-gamma"]' \
    "{\"type\": \"ssh-ed25519\", \"authority\": \"fabric\", \"cert_usage\": [\"ssh-host\"], \"slots\": {\"26-03-03\": {\"public\": \"$(cut -d' ' -f2 alpha.pub)\"}}}")
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"host-gamma: no machine gamma"* ]]
  cmp "$keys" before
}

@test "each new key id carries the hash of its names and its issue stamp" {
  certify --apply
  id="$(key_id host-alpha ssh-host)"
  [ "$(yq -p json -r .names <<<"$id")" = "$(printf '%s' alpha,alpha.lan | sha256sum | cut -d' ' -f1)" ]
  [[ "$(yq -p json -r .issued <<<"$id")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [ "$(yq -p json -r .marker <<<"$id")" = ndh-ssh-key-meta-v1 ]
}

recorded_cert() { yq eval -r ".keys.\"$1\".slots.\"26-03-03\".certificates.fabric.\"ssh-host\"" "$keys"; }

@test "the gate closed: a machine without its own host key keeps the union certificate untouched" {
  (cd "$repo" && sops unset modules/home-manager/ssh.d/keys.yaml '["keys"]["host-alpha-nixos"]')
  record_legacy rdp-host rdp.pub 0 ca-new
  recorded_cert rdp-host >union
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"rdp-host keeps its union cert: not yet on their own host key: alpha-nixos (host-alpha-nixos not certified)"* ]]
  [[ "$output" != *"signed rdp-host"* ]]
  [ "$(recorded_cert rdp-host)" = "$(cat union)" ]
  [ "$(names host-alpha ssh-host)" = "alpha,alpha.lan" ]
}

@test "the gate closed: a machine with its host key certified but ndh.hostKey.own off keeps the union certificate byte-identical" {
  record_legacy rdp-host rdp.pub 0 ca-new
  bake "$FLEET" alpha
  certify --apply
  run cert host-alpha-nixos ssh-host
  [[ "$output" == *"host certificate"* ]]
  recorded_cert rdp-host >union
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"current"*"host-alpha-nixos"*"ssh-host"* ]]
  [[ "$output" == *"rdp-host keeps its union cert: not yet on their own host key: alpha-nixos (ndh.hostKey.own off)"* ]]
  [[ "$output" != *"signed rdp-host"* ]]
  [ "$(recorded_cert rdp-host)" = "$(cat union)" ]
}

@test "the gate closed on no machine at all on its own key, each named with why" {
  (cd "$repo" && sops unset modules/home-manager/ssh.d/keys.yaml '["keys"]["host-alpha-nixos"]')
  record_legacy rdp-host rdp.pub 0 ca-new
  bake "$FLEET" ""
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"own key      (none)"* ]]
  [[ "$output" == *"not yet on their own host key: alpha (ndh.hostKey.own off); alpha-nixos (ndh.hostKey.own off, host-alpha-nixos not certified)"* ]]
}

@test "an own machine the build has no names for refuses to run" {
  bake "$FLEET" "alpha gamma"
  run certify
  [ "$status" -eq 1 ]
  [[ "$output" == *"machine gamma serves its own key but has no baked names"* ]]
}

@test "the gate open, every other machine on its own certified key: the interim is signed, the union id logged" {
  certify --apply
  record_legacy rdp-host rdp.pub 0 ca-new
  legacy="$(key_id rdp-host ssh-host)"
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"current"*"host-alpha "*"ssh-host"* ]]
  [[ "$output" == *"current"*"host-alpha-nixos"*"ssh-host"* ]]
  [[ "$output" == *"replaces rdp-host@26-03-03 ssh-host: key id \"$legacy\", serial 0"* ]]
  [[ "$output" != *"keeps its union cert"* ]]
  [ "$(key_id rdp-host ssh-host)" != "$legacy" ]
  [ "$(names rdp-host ssh-host)" = "beta,beta-nixos,beta.lan,nixos.beta" ]
}

@test "the gate opening in the same run: the host keys are signed first, then the interim" {
  record_legacy rdp-host rdp.pub 0 ca-new
  legacy="$(key_id rdp-host ssh-host)"
  run certify
  [[ "$output" == *"stale"*"rdp-host"*"ssh-host"* ]]
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"signed host-alpha@"*"signed host-alpha-nixos@"*"replaces rdp-host@26-03-03 ssh-host: key id \"$legacy\", serial 0"*"signed rdp-host@"* ]]
  [ "$(serial rdp-host ssh-host)" -gt "$(serial host-alpha-nixos ssh-host)" ]
  [ "$(key_id rdp-host ssh-host)" != "$legacy" ]
  [ "$(names rdp-host ssh-host)" = "beta,beta-nixos,beta.lan,nixos.beta" ]
}

@test "new serials are non-zero, distinct, and start one above the highest recorded" {
  record_legacy rdp-host rdp.pub 41 ca-new
  certify --apply
  s="$(for k in host-alpha host-alpha-nixos rdp-host; do serial "$k" ssh-host; done; serial host ssh-user)"
  [ "$(sort -n <<<"$s" | head -1)" = 42 ]
  [ "$(sort -u <<<"$s" | wc -l)" -eq 4 ]
  ! grep -qx 0 <<<"$s"
}

@test "with nothing recorded, serials start at 1" {
  certify --apply
  [ "$({ for k in host-alpha host-alpha-nixos rdp-host; do serial "$k" ssh-host; done; serial host ssh-user; } | sort -n | head -1)" = 1 ]
}

@test "a certificate signed by a compromised authority slot is stale, and re-signed by the signing one" {
  record_legacy host-alpha alpha.pub 0 ca-old
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"signed host-alpha@26-03-03 ssh-host with fabric@26-02-02"* ]]
  run cert host-alpha ssh-host
  [[ "$output" == *"Signing CA: ED25519 $(ssh-keygen -lf ca-new.pub | awk '{print $2}')"* ]]
}

@test "the user certificate carries the key's own principals" {
  certify --apply
  run cert host ssh-user
  [[ "$output" == *"user certificate"* ]]
  [ "$(names host ssh-user)" = "deploy,operator" ]
}

@test "a TLS-only key is left to its own path" {
  certify --apply
  [ "$(yq eval -r '.keys.relay.slots."26-03-03".certificates // "none"' "$keys")" = none ]
}

@test "every private stays encrypted, and the certificates are in clear" {
  certify --apply
  [ "$(yq eval '[.keys[].slots[].private, .authorities[].slots[].private] | map(select(. != null)) | all_c(test("^ENC\["))' "$keys")" = true ]
  yq eval -r '.keys."host-alpha".slots."26-03-03".certificates.fabric."ssh-host"' "$keys" | grep -q '^ssh-ed25519-cert-v01@openssh.com '
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
  bake "${FLEET/alpha.lan/alpha.lan,alpha.local}"
  run certify
  [[ "$output" == *"stale"*"host-alpha"*"ssh-host"* ]]
  [[ "$output" == *"current"*"host-alpha-nixos"*"ssh-host"* ]]
  [[ "$output" == *"current"*"rdp-host"*"ssh-host"* ]]
  [[ "$output" == *"current"*"host"*"ssh-user"* ]]
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
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["host-beta"]' \
    '{"type": "ssh-ed25519", "authority": "fabric", "cert_usage": ["ssh-host"], "slots": {"26-04-04": {}}}')
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecorded"*"host-beta"*"generated and signed at activation"* ]]
  [ "$(yq eval -r '.keys."host-beta".slots."26-04-04".certificates // "none"' "$keys")" = none ]
}

@test "a signature that fails stops the run and leaves keys.yaml untouched" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["host-beta-nixos"]' \
    '{"type": "ssh-ed25519", "authority": "fabric", "cert_usage": ["ssh-host"], "slots": {"26-04-04": {"public": "AAAAnotakey"}}}')
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"keys.yaml left untouched"* ]]
  cmp "$keys" before
}
