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
  keys="$repo/modules/home-manager/ssh.d/keys.yaml"
  PUB="$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/existing.pub")" PRIV="$(<"$BATS_TEST_TMPDIR/existing")" \
    yq eval -n '
      .keys.existing.type = "ssh-ed25519" |
      .keys.existing.comment = "existing" |
      .keys.existing.usage = ["github-signing"] |
      .keys.existing.profiles = ["user"] |
      .keys.existing.slots."26-01-01".public = strenv(PUB) |
      .keys.existing.slots."26-01-01".private = strenv(PRIV) |
      (.keys.existing.slots."26-01-01".private | key) headComment = "sops:encrypted"
    ' >"$keys"
  (cd "$repo" && sops --input-type yaml --output-type yaml encrypt -i modules/home-manager/ssh.d/keys.yaml)

  printf 'ndh::logger:command:run() { shift; "$@"; }\n' >"$BATS_TEST_TMPDIR/trampoline.sh"
  sed -e "s#@nixBashTrampoline@#$BATS_TEST_TMPDIR/trampoline.sh#" -e 's#@loggerTag@#test#' \
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
