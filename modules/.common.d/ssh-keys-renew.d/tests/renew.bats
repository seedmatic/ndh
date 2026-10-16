#!/usr/bin/env bats
# ssh-keys-renew against a real sops and a throwaway age key, in a throwaway git repository:
# the plan, the creation of a new entry, and the refusals. No value is ever printed — the
# assertions read the decrypted document into files and compare or grep them.

setup() {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/modules/home-manager/ssh.d"
  git -C "$repo" init -q

  age-keygen -o "$BATS_TEST_TMPDIR/age.txt" 2>/dev/null
  export SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/age.txt"
  recipient="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
  cat >"$repo/.sops.yaml" <<EOF
creation_rules:
  - path_regex: '.*'
    encrypted_comment_regex: 'sops:encrypted'
    age: $recipient
EOF

  ssh-keygen -q -t ed25519 -N "" -f "$BATS_TEST_TMPDIR/existing" -C existing
  # The authority host certificates are signed by, and the host key it signs today: what --public
  # reads the new entry's authority from.
  ssh-keygen -q -t ed25519 -N "" -f "$BATS_TEST_TMPDIR/fabric" -C fabric
  ssh-keygen -q -t ed25519 -N "" -f "$BATS_TEST_TMPDIR/shared" -C shared
  keys="$repo/modules/home-manager/ssh.d/keys.yaml"
  PUB="$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/existing.pub")" PRIV="$(<"$BATS_TEST_TMPDIR/existing")" \
    CAPUB="$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/fabric.pub")" CAPRIV="$(<"$BATS_TEST_TMPDIR/fabric")" \
    HPUB="$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/shared.pub")" HPRIV="$(<"$BATS_TEST_TMPDIR/shared")" \
    yq eval -n '
      .authorities.fabric.type = "ssh-ed25519" |
      .authorities.fabric.usage = ["ssh-authority"] |
      .authorities.fabric.slots."26-01-01".public = strenv(CAPUB) |
      .authorities.fabric.slots."26-01-01".private = strenv(CAPRIV) |
      (.authorities.fabric.slots."26-01-01".private | key) headComment = "sops:encrypted" |
      .keys.existing.type = "ssh-ed25519" |
      .keys.existing.comment = "existing" |
      .keys.existing.usage = ["github-signing"] |
      .keys.existing.profiles = ["user"] |
      .keys.existing.slots."26-01-01".public = strenv(PUB) |
      .keys.existing.slots."26-01-01".private = strenv(PRIV) |
      (.keys.existing.slots."26-01-01".private | key) headComment = "sops:encrypted" |
      .keys.shared.type = "ssh-ed25519" |
      .keys.shared.usage = ["ssh-host"] |
      .keys.shared.authority = "fabric" |
      .keys.shared.cert_usage = ["ssh-host"] |
      .keys.shared.profiles = ["system"] |
      .keys.shared.slots."26-01-01".public = strenv(HPUB) |
      .keys.shared.slots."26-01-01".private = strenv(HPRIV) |
      (.keys.shared.slots."26-01-01".private | key) headComment = "sops:encrypted"
    ' >"$keys"
  (cd "$repo" && sops --input-type yaml --output-type yaml encrypt -i modules/home-manager/ssh.d/keys.yaml)

  # The stub runs the command the way the real ndh::logger:command:run does — through its
  # ndh::logger:command:invoke, sourced from the real logger — without its log sinks: a failure the
  # script does not check behaves here as it does there.
  printf 'source "%s"\nndh::logger:command:run() { shift; ndh::logger:command:invoke "$@"; return "$NDH_LOGGER_COMMAND_RC"; }\n' "$NDH_LOGGER_SH" >"$BATS_TEST_TMPDIR/trampoline.sh"
  sed -e "s#@nixBashTrampoline@#$BATS_TEST_TMPDIR/trampoline.sh#" -e 's#@loggerTag@#test#' \
    -e 's#@machines@#bioskop nikopol bioskop-nixos nikopol-nixos#' \
    "$BATS_TEST_DIRNAME/../ssh-keys-renew.sh" >"$BATS_TEST_TMPDIR/ssh-keys-renew"
  today="$(date +%y-%m-%d)"
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

renew() {
  (cd "$repo" && bash -euo pipefail "$BATS_TEST_TMPDIR/ssh-keys-renew" "$@")
}

decrypted() {
  sops --input-type yaml --output-type yaml -d "$keys"
}

@test "a dry run of --create shows the new entry and leaves keys.yaml untouched" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run renew --create bot --usage bot-signing
  [ "$status" -eq 0 ]
  [[ "$output" == *"bot"*"${today} (new entry)"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--create --apply declares the entry and generates its first slot, private encrypted" {
  run renew --create bot --usage bot-signing --comment "rke2lab bot" --apply
  [ "$status" -eq 0 ]
  [ "$(yq eval -r '.keys.bot.type' "$keys")" = ssh-ed25519 ]
  [ "$(yq eval -r '.keys.bot.comment' "$keys")" = "rke2lab bot" ]
  [ "$(yq eval -r '.keys.bot.usage | join(",")' "$keys")" = bot-signing ]
  [ "$(yq eval -r '.keys.bot.profiles | length' "$keys")" = 0 ]
  [ "$(yq eval -r ".keys.bot.slots | keys | join(\",\")" "$keys")" = "$today" ]
  yq eval -r ".keys.bot.slots.\"$today\".public" "$keys" | grep -qE '^[A-Za-z0-9+/]{40,}={0,2}$'
  yq eval -r ".keys.bot.slots.\"$today\".private" "$keys" | grep -q '^ENC\['
  decrypted | yq eval -r ".keys.bot.slots.\"$today\".private" - | grep -q 'BEGIN OPENSSH PRIVATE KEY'
}

@test "the profiles of a new entry are recorded in order, and none means none" {
  run renew --create host-bot --usage bot-signing --profile system --profile user --apply
  [ "$status" -eq 0 ]
  [ "$(yq eval -r '.keys."host-bot".profiles | join(",")' "$keys")" = system,user ]
}

@test "creating an entry leaves every other entry's material as it was" {
  decrypted | yq eval '.keys.existing' - >"$BATS_TEST_TMPDIR/existing.before"
  run renew --create bot --usage bot-signing --apply
  [ "$status" -eq 0 ]
  decrypted | yq eval '.keys.existing' - >"$BATS_TEST_TMPDIR/existing.after"
  cmp "$BATS_TEST_TMPDIR/existing.before" "$BATS_TEST_TMPDIR/existing.after"
}

@test "--create refuses a name that already exists, and changes nothing" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run renew --create existing --usage bot-signing --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"keys.existing: already exists"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--create refuses a name outside the schema's pattern before any yq expression sees it" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  for name in 'bot"' 'Bot' '-bot' 'bot.x' 'a b'; do
    run renew --create "$name" --usage bot-signing --apply
    [ "$status" -eq 64 ]
    [[ "$output" == *"a key name is"* ]]
  done
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--create without --usage is a usage error" {
  run renew --create bot
  [ "$status" -eq 64 ]
  [[ "$output" == *"needs at least one --usage"* ]]
}

@test "--create stands alone: no renewal or replacement mixed in" {
  run renew --create bot --usage bot-signing --key existing
  [ "$status" -eq 64 ]
  run renew --create bot --usage bot-signing --replace --reason x
  [ "$status" -eq 64 ]
}

@test "the fields of a new entry need --create" {
  run renew --key existing --usage bot-signing
  [ "$status" -eq 64 ]
  run renew --key existing --type ssh-rsa
  [ "$status" -eq 64 ]
}

@test "--apply keeps keys.yaml's own rule's recipients, not the catch-all's" {
  narrow_rule sync
  [ "$(recipients)" = 2 ]
  run renew --create bot --usage bot-signing --apply
  [ "$status" -eq 0 ]
  [ "$(recipients)" = 2 ]
}

@test "a run that would change keys.yaml's recipients is refused, and changes nothing" {
  narrow_rule nosync
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run renew --create bot --usage bot-signing --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"recipients would change"*"sops updatekeys"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

# A machine's host key, as ndh-keyring host-key prints it: generated here, its private thrown away.
host_public() {
  rm -f "$BATS_TEST_TMPDIR/machine-${1:-ed25519}" "$BATS_TEST_TMPDIR/machine-${1:-ed25519}.pub"
  ssh-keygen -q -t "${1:-ed25519}" -N "" -f "$BATS_TEST_TMPDIR/machine-${1:-ed25519}" -C host-bioskop-nixos
  cat "$BATS_TEST_TMPDIR/machine-${1:-ed25519}.pub"
}

record() {
  (cd "$repo" && bash -euo pipefail "$BATS_TEST_TMPDIR/ssh-keys-renew" --create host-bioskop-nixos --public - --usage ssh-host "$@")
}

@test "--public --apply records a public-only slot, in clear, under the host certificates' authority" {
  host_public >"$BATS_TEST_TMPDIR/line"
  entry='.keys."host-bioskop-nixos"'
  decrypted | yq eval "del($entry)" - >"$BATS_TEST_TMPDIR/before.yaml"
  run record --comment "bioskop-nixos host" --apply <"$BATS_TEST_TMPDIR/line"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ssh-keys-certify"*"commit"* ]]
  [ "$(yq eval -r "$entry.type" "$keys")" = ssh-ed25519 ]
  [ "$(yq eval -r "$entry.comment" "$keys")" = "bioskop-nixos host" ]
  [ "$(yq eval -r "$entry.usage | join(\",\")" "$keys")" = ssh-host ]
  [ "$(yq eval -r "$entry.authority" "$keys")" = fabric ]
  [ "$(yq eval -r "$entry.cert_usage | join(\",\")" "$keys")" = ssh-host ]
  [ "$(yq eval -r "$entry.profiles | length" "$keys")" = 0 ]
  [ "$(yq eval -r "$entry.slots | keys | join(\",\")" "$keys")" = "$today" ]
  [ "$(yq eval -r "$entry.slots.\"$today\" | keys | join(\",\")" "$keys")" = public ]
  [ "$(yq eval -r "$entry.slots.\"$today\".public" "$keys")" = "$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/line")" ]
  # Nothing else changed: the decrypted document minus the new entry is the one before.
  decrypted | yq eval "del($entry)" - >"$BATS_TEST_TMPDIR/after.yaml"
  cmp "$BATS_TEST_TMPDIR/before.yaml" "$BATS_TEST_TMPDIR/after.yaml"
  # And every private is still ciphertext.
  [ "$(yq eval '[.keys[].slots[].private, .authorities[].slots[].private] | map(select(. != null)) | all_c(test("^ENC\\["))' "$keys")" = true ]
}

@test "a dry run of --public shows the record and writes nothing" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run record < <(host_public)
  [ "$status" -eq 0 ]
  [[ "$output" == *"host-bioskop-nixos"*"${today} (new entry, public only, under fabric)"* ]]
  [[ "$output" == *"dry run"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--public refuses a private on stdin, and never prints it" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  host_public >/dev/null
  run record --apply <"$BATS_TEST_TMPDIR/machine-ed25519"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PRIVATE key"*"not printed"* ]]
  # No line of the private's body reaches the output.
  while IFS= read -r line; do
    [[ "$line" == -----* ]] && continue
    [[ "$output" != *"$line"* ]]
  done <"$BATS_TEST_TMPDIR/machine-ed25519"
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--public refuses a non-ed25519 public, two lines, an empty stdin and a malformed blob" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run record --apply < <(host_public rsa)
  [ "$status" -eq 1 ]
  [[ "$output" == *"ed25519 only"* ]]
  host_public >"$BATS_TEST_TMPDIR/line"
  run record --apply < <(cat "$BATS_TEST_TMPDIR/line" "$BATS_TEST_TMPDIR/line")
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly ONE line"* ]]
  run record --apply </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"exactly ONE line"* ]]
  run record --apply <<<"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA== host-bioskop-nixos"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ssh-keygen -l refused it"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--public refuses a machine outside the inventory" {
  host_public >"$BATS_TEST_TMPDIR/line"
  run bash -c 'cd "$1" && bash -euo pipefail "$2" --create host-elsewhere --public - --usage ssh-host --apply <"$3"' _ \
    "$repo" "$BATS_TEST_TMPDIR/ssh-keys-renew" "$BATS_TEST_TMPDIR/line"
  [ "$status" -eq 64 ]
  [[ "$output" == *"host-MACHINE, MACHINE one of: bioskop nikopol bioskop-nixos nikopol-nixos"* ]]
}

@test "--public needs --create, takes only -, and only usage ssh-host" {
  run renew --key existing --public -
  [ "$status" -eq 64 ]
  [[ "$output" == *"they need --create"* ]]
  run renew --create host-bioskop --public "$BATS_TEST_TMPDIR/line" --usage ssh-host
  [ "$status" -eq 64 ]
  [[ "$output" == *"--public takes -"* ]]
  run renew --create host-bioskop --public - --usage ssh-user </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"its one --usage is ssh-host"* ]]
  run renew --create host-bioskop --public - --usage ssh-host --usage ssh-user </dev/null
  [ "$status" -eq 64 ]
  run renew --create host-bioskop --public - --usage ssh-host --profile system </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"no --profile and no --type"* ]]
}

@test "--public refuses an existing entry name, and a public keys.yaml already carries" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run record --apply < <(host_public)
  [ "$status" -eq 0 ]
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run record --apply < <(host_public)
  [ "$status" -eq 1 ]
  [[ "$output" == *"keys.host-bioskop-nixos: already exists"* ]]
  run bash -c 'cd "$1" && bash -euo pipefail "$2" --create host-nikopol --public - --usage ssh-host --apply <"$3"' _ \
    "$repo" "$BATS_TEST_TMPDIR/ssh-keys-renew" "$BATS_TEST_TMPDIR/shared.pub"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already in keys.yaml"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}
