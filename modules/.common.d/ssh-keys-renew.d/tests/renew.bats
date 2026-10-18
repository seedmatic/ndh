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
  # keys.yaml's public view, rewritten by the real keys-json.sh with the real filter, as the package does.
  printf '#!%s\nexec bash -euo pipefail "%s" "%s" "$@"\n' "$BASH" "$KEYS_JSON_SH" "$PUBLIC_YQ" >"$BATS_TEST_TMPDIR/keys-json"
  chmod +x "$BATS_TEST_TMPDIR/keys-json"
  sed -e "s#@nixBashTrampoline@#$BATS_TEST_TMPDIR/trampoline.sh#" -e 's#@loggerTag@#test#' \
    -e 's#@machines@#bioskop nikopol bioskop-nixos nikopol-nixos#' -e 's#@guests@#bioskop-nixos nikopol-nixos#' \
    -e 's#@vzHosts@#nikopol#' -e "s#@toolPath@#$BATS_TEST_TMPDIR/bin:$PATH#" -e "s#@keysJson@#$BATS_TEST_TMPDIR/keys-json#" \
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

# A caller's shell at its worst: failing tools first on PATH, a UTF-8 locale and POSIXLY_CORRECT.
hostile() { # <cmd>... — runs <cmd> under it
  local d="$BATS_TEST_TMPDIR/hostile" c
  mkdir -p "$d"
  for c in yq awk gawk sort tr paste cut sed grep diff sops ssh ssh-keygen openssl step git; do
    printf '#!%s\necho hostile-%s >&2\nexit 1\n' "$BASH" "$c" >"$d/$c" && chmod +x "$d/$c"
  done
  PATH="$d:$PATH" LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 LC_COLLATE=fr_FR.UTF-8 POSIXLY_CORRECT=1 "$@"
}

@test "a caller's PATH, locale and POSIXLY_CORRECT change nothing, and none of its tools ran" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  hostile run renew --create bot --usage bot-signing
  [ "$status" -eq 0 ]
  [[ "$output" == *"bot"*"${today} (new entry)"* ]]
  [[ "$output" != *hostile-* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
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

sshfs_record() {
  (cd "$repo" && bash -euo pipefail "$BATS_TEST_TMPDIR/ssh-keys-renew" --create sshfs-bioskop-nixos --public - --usage ssh-user "$@")
}

@test "--public --apply records an sshfs key: public only, in clear, no authority and no certificate" {
  host_public >"$BATS_TEST_TMPDIR/line"
  entry='.keys."sshfs-bioskop-nixos"'
  decrypted | yq eval "del($entry)" - >"$BATS_TEST_TMPDIR/before.yaml"
  run sshfs_record --apply <"$BATS_TEST_TMPDIR/line"
  [ "$status" -eq 0 ]
  [[ "$output" == *"never certified"*"ndh-identity-push bioskop-nixos with the key on fd 5"* ]]
  [[ "$output" != *"ssh-keys-certify"* ]]
  [ "$(yq eval -r "$entry.type" "$keys")" = ssh-ed25519 ]
  [ "$(yq eval -r "$entry.usage | join(\",\")" "$keys")" = ssh-user ]
  [ "$(yq eval -r "$entry | has(\"authority\") or has(\"cert_usage\")" "$keys")" = false ]
  [ "$(yq eval -r "$entry.profiles | length" "$keys")" = 0 ]
  [ "$(yq eval -r "$entry.slots.\"$today\" | keys | join(\",\")" "$keys")" = public ]
  [ "$(yq eval -r "$entry.slots.\"$today\".public" "$keys")" = "$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/line")" ]
  decrypted | yq eval "del($entry)" - >"$BATS_TEST_TMPDIR/after.yaml"
  cmp "$BATS_TEST_TMPDIR/before.yaml" "$BATS_TEST_TMPDIR/after.yaml"
}

@test "a dry run of an sshfs record says no certificate, and writes nothing" {
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run sshfs_record < <(host_public)
  [ "$status" -eq 0 ]
  [[ "$output" == *"sshfs-bioskop-nixos"*"${today} (new entry, public only, no certificate)"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

vz_recover_record() {
  (cd "$repo" && bash -euo pipefail "$BATS_TEST_TMPDIR/ssh-keys-renew" --create vz-recover-nikopol --public - --usage ssh-user "$@")
}

@test "--public --apply records a vz-recover key: public only, in clear, no authority and no certificate" {
  host_public >"$BATS_TEST_TMPDIR/line"
  entry='.keys."vz-recover-nikopol"'
  decrypted | yq eval "del($entry)" - >"$BATS_TEST_TMPDIR/before.yaml"
  run vz_recover_record --apply <"$BATS_TEST_TMPDIR/line"
  [ "$status" -eq 0 ]
  [[ "$output" == *"never certified"*"forcing ndh-vz-recover"*"ssh vzrecover.nikopol list"* ]]
  [[ "$output" != *"ssh-keys-certify"* ]]
  [ "$(yq eval -r "$entry.usage | join(\",\")" "$keys")" = ssh-user ]
  [ "$(yq eval -r "$entry | has(\"authority\") or has(\"cert_usage\")" "$keys")" = false ]
  [ "$(yq eval -r "$entry.profiles | length" "$keys")" = 0 ]
  [ "$(yq eval -r "$entry.slots.\"$today\" | keys | join(\",\")" "$keys")" = public ]
  [ "$(yq eval -r "$entry.slots.\"$today\".public" "$keys")" = "$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/line")" ]
  decrypted | yq eval "del($entry)" - >"$BATS_TEST_TMPDIR/after.yaml"
  cmp "$BATS_TEST_TMPDIR/before.yaml" "$BATS_TEST_TMPDIR/after.yaml"
}

@test "a vz-recover record is a foreign vz-host's, of usage ssh-user only" {
  host_public >"$BATS_TEST_TMPDIR/line"
  for name in vz-recover-bioskop vz-recover-nikopol-nixos vz-recover-elsewhere; do
    run bash -c 'cd "$1" && bash -euo pipefail "$2" --create "$4" --public - --usage ssh-user --apply <"$3"' _ \
      "$repo" "$BATS_TEST_TMPDIR/ssh-keys-renew" "$BATS_TEST_TMPDIR/line" "$name"
    [ "$status" -eq 64 ]
    [[ "$output" == *"vz-recover-HOST, HOST one of: nikopol"* ]]
  done
  run renew --create vz-recover-nikopol --public - --usage ssh-host </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"a vz-recover key: its one --usage is ssh-user"* ]]
}

@test "an sshfs record is a NixOS guest's, of usage ssh-user only, on no profile" {
  host_public >"$BATS_TEST_TMPDIR/line"
  for name in sshfs-bioskop sshfs-elsewhere; do
    run bash -c 'cd "$1" && bash -euo pipefail "$2" --create "$4" --public - --usage ssh-user --apply <"$3"' _ \
      "$repo" "$BATS_TEST_TMPDIR/ssh-keys-renew" "$BATS_TEST_TMPDIR/line" "$name"
    [ "$status" -eq 64 ]
    [[ "$output" == *"sshfs-GUEST, GUEST one of: bioskop-nixos nikopol-nixos"* ]]
  done
  run renew --create sshfs-bioskop-nixos --public - --usage ssh-host </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"an sshfs key: its one --usage is ssh-user"* ]]
  run renew --create host-bioskop-nixos --public - --usage ssh-user </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"a host key: its one --usage is ssh-host"* ]]
  run renew --create sshfs-bioskop-nixos --public - --usage ssh-user --profile system </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"no --profile and no --type"* ]]
}

@test "an sshfs record refuses a public keys.yaml already carries: its guest's host key, for one" {
  host_public >"$BATS_TEST_TMPDIR/line"
  run record --apply <"$BATS_TEST_TMPDIR/line"
  [ "$status" -eq 0 ]
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run sshfs_record --apply <"$BATS_TEST_TMPDIR/line"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already in keys.yaml"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

# --revoke-certificate: `shared` plays rdp-host. Its union certificate is recorded and committed, then
# re-signed (the interim) and committed again; the revocation reads the union one back from history.
LEGACY='{"marker":"ndh-ssh-key-meta-v1","owner":"home-manager.ssh-add-keys","key":"shared","usage":["ssh-host"]}'

commit() { # <message> → the new commit
  git -C "$repo" add .sops.yaml modules/home-manager/ssh.d/keys.yaml
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm "$1"
  git -C "$repo" rev-parse HEAD
}

record_host_cert() { # <key id> <serial>
  rm -f "$BATS_TEST_TMPDIR/shared-cert.pub"
  ssh-keygen -q -s "$BATS_TEST_TMPDIR/fabric" -h -I "$1" -z "$2" -n shared "$BATS_TEST_TMPDIR/shared.pub"
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["shared"]["slots"]["26-01-01"]["certificates"]' \
    "{\"fabric\": {\"ssh-host\": \"$(<"$BATS_TEST_TMPDIR/shared-cert.pub")\"}}")
}

# The fixture's history: before (no certificate), union (the legacy one recorded), interim (re-signed).
history() {
  before="$(commit before)"
  record_host_cert "$LEGACY" 0
  union="$(commit union)"
  record_host_cert '{"marker":"ndh-ssh-key-meta-v1","key":"shared","names":"beta","issued":"2026-10-16T00:00:00Z"}' 7
  interim="$(commit interim)"
}

revoke() { renew --revoke-certificate shared@26-01-01 --reason "union certificate, every machine on its own" "$@"; }

# Every value but the one entry, ciphertexts included, as committed.
rest() { yq eval -o json 'del(.sops) | del(.revoked_certificates)' "$keys"; }

@test "--revoke-certificate dry run names the exact key id and changes nothing" {
  history
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run revoke --from-revision "$union"
  [ "$status" -eq 0 ]
  [[ "$output" == *"revoke        revoked_certificates.shared@26-01-01/0"* ]]
  [[ "$output" == *"key id      ${LEGACY}"* ]]
  [[ "$output" == *"signed by   fabric@26-01-01"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--revoke-certificate --apply records the exact id, its authority slot, serial and revision, in clear" {
  history
  run revoke --from-revision "${union:0:10}" --apply
  [ "$status" -eq 0 ]
  entry='.revoked_certificates."shared@26-01-01/0"'
  [ "$(yq eval -r "${entry}.key_id" "$keys")" = "$LEGACY" ]
  [ "$(yq eval -r "${entry}.authority" "$keys")" = fabric ]
  [ "$(yq eval -r "${entry}.authority_slot" "$keys")" = 26-01-01 ]
  [ "$(yq eval -r "${entry}.serial | tag" "$keys")" = '!!int' ]
  [ "$(yq eval -r "${entry}.serial" "$keys")" = 0 ]
  [ "$(yq eval -r "${entry}.revision" "$keys")" = "$union" ]
  [ "$(yq eval -r "${entry}.reason" "$keys")" = "union certificate, every machine on its own" ]
  # The id ssh-keygen reads from the certificate the revision recorded, character for character.
  [ "$(git -C "$repo" show "${union}:modules/home-manager/ssh.d/keys.yaml" |
    yq eval -r '.keys.shared.slots."26-01-01".certificates.fabric."ssh-host"' - | ssh-keygen -L -f - |
    awk '/Key ID:/ { sub(/^[^"]*"/, ""); sub(/"$/, ""); print }')" = "$LEGACY" ]
  decrypted | yq eval -r "${entry}.key_id" - | grep -Fxq "$LEGACY"
}

@test "--revoke-certificate leaves the rest of keys.yaml, ciphertexts included, byte for byte, and decrypts nothing" {
  history
  rest >"$BATS_TEST_TMPDIR/rest-before"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!%s\necho "$*" >>"%s/sops.log"\nexec %s "$@"\n' "$(command -v bash)" "$BATS_TEST_TMPDIR" "$(command -v sops)" \
    >"$BATS_TEST_TMPDIR/bin/sops"
  chmod +x "$BATS_TEST_TMPDIR/bin/sops"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run revoke --from-revision "$union" --apply
  [ "$status" -eq 0 ]
  rest | cmp - "$BATS_TEST_TMPDIR/rest-before"
  [ "$(cut -d' ' -f1 "$BATS_TEST_TMPDIR/sops.log" | sort -u)" = set ]
  [ "$(yq eval '[.keys[].slots[].private, .authorities[].slots[].private] | map(select(. != null)) | all_c(test("^ENC\["))' "$keys")" = true ]
}

@test "--revoke-certificate refuses a certificate keys.yaml still records, or a live one with its id" {
  history
  git -C "$repo" show "${union}:modules/home-manager/ssh.d/keys.yaml" |
    yq eval -r '.keys.shared.slots."26-01-01".certificates.fabric."ssh-host"' - >"$BATS_TEST_TMPDIR/union-cert.pub"
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["shared"]["slots"]["26-01-01"]["certificates"]["fabric"]["ssh-host"]' \
    "\"$(<"$BATS_TEST_TMPDIR/union-cert.pub")\"")
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run revoke --from-revision "$union" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"keys.yaml still records this certificate (shared@26-01-01 fabric ssh-host)"* ]]
  record_host_cert "$LEGACY" 9
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run revoke --from-revision "$union" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"keys.yaml still records a certificate with its key id (shared@26-01-01 fabric ssh-host)"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--revoke-certificate refuses a revision without that certificate, and an unknown revision" {
  history
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run revoke --from-revision "$before" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"keys.shared.slots.26-01-01 records no ssh-host certificate in that revision"* ]]
  run revoke --from-revision does-not-exist --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such commit"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--revoke-certificate refuses to record the same certificate twice" {
  history
  revoke --from-revision "$union" --apply
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run revoke --from-revision "$union" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"revoked_certificates already holds shared@26-01-01/0"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--revoke-certificate stands alone, and needs --from-revision, --reason and KEY@SLOT" {
  run renew --revoke-certificate shared@26-01-01 --from-revision HEAD --reason r --key existing
  [ "$status" -eq 64 ]
  [[ "$output" == *"--revoke-certificate stands alone"* ]]
  run renew --revoke-certificate shared@26-01-01 --reason r
  [ "$status" -eq 64 ]
  [[ "$output" == *"needs --from-revision"* ]]
  run renew --revoke-certificate shared@26-01-01 --from-revision HEAD
  [ "$status" -eq 64 ]
  run renew --revoke-certificate 'shared"]|del(.)' --from-revision HEAD --reason r
  [ "$status" -eq 64 ]
  [[ "$output" == *"KEY@YY-MM-DD"* ]]
  run renew --key existing --from-revision HEAD
  [ "$status" -eq 64 ]
  [[ "$output" == *"--from-revision names the revision of a --revoke-certificate"* ]]
}

# A machine's host key recorded public-only, as `--create host-<m> --public -` leaves it, then the nix signing
# public of its derived key: 32 bytes, unrelated to the host key, since nothing here can check a derivation.
hostRecorded() {
  ssh-keygen -q -t ed25519 -N "" -f "$BATS_TEST_TMPDIR/host-bioskop" -C host-bioskop
  local entry
  entry="$(B="$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/host-bioskop.pub")" yq eval -n -o json --indent=0 \
    '{"type": "ssh-ed25519", "usage": ["ssh-host"], "profiles": [], "slots": {"26-01-01": {"public": strenv(B)}}}')"
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["host-bioskop"]' "$entry")
  nixPublic="seedmatic-bioskop-1:$(head -c 32 /dev/urandom | base64)"
}
nixRecord() { renew --record-nix-signing host-bioskop --public - "$@"; }
nixRest() { yq eval -o json 'del(.sops) | del(.keys."host-bioskop".slots."26-01-01".nixSigning)' "$keys"; }

@test "--record-nix-signing dry run shows the slot and the public, and changes nothing" {
  hostRecorded
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run nixRecord <<<"$nixPublic"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keys.host-bioskop.slots.26-01-01.nixSigning"* ]]
  [[ "$output" == *"dry run"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--record-nix-signing --apply records it in clear, in the newest slot, with sops set alone, the rest byte for byte" {
  hostRecorded
  nixRest >"$BATS_TEST_TMPDIR/rest-before"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!%s\necho "$*" >>"%s/sops.log"\nexec %s "$@"\n' "$(command -v bash)" "$BATS_TEST_TMPDIR" "$(command -v sops)" \
    >"$BATS_TEST_TMPDIR/bin/sops"
  chmod +x "$BATS_TEST_TMPDIR/bin/sops"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run nixRecord --apply <<<"$nixPublic"
  [ "$status" -eq 0 ]
  [ "$(yq eval -r '.keys."host-bioskop".slots."26-01-01".nixSigning' "$keys")" = "$nixPublic" ]
  nixRest | cmp - "$BATS_TEST_TMPDIR/rest-before"
  [ "$(cut -d' ' -f1 "$BATS_TEST_TMPDIR/sops.log" | sort -u)" = set ]
}

@test "--record-nix-signing refuses a secret, a private, two lines, and never prints what it read" {
  hostRecorded
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  secret="seedmatic-bioskop-1:$(head -c 64 /dev/urandom | base64 | tr -d '\n')"
  for input in "$secret" "$(<"$BATS_TEST_TMPDIR/host-bioskop")" "$nixPublic"$'\n'"$nixPublic" ""; do
    run nixRecord --apply <<<"$input"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refused, and not printed"* ]]
    [[ "$output" != *"${secret#*:}"* && "$output" != *"PRIVATE KEY"* ]]
  done
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--record-nix-signing refuses another machine's name, the host key itself, and a slot that has one" {
  hostRecorded
  run nixRecord --apply <<<"seedmatic-nikopol-1:${nixPublic#*:}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not seedmatic-bioskop-N"* ]]
  hostRaw="$(cut -d' ' -f2 <"$BATS_TEST_TMPDIR/host-bioskop.pub" | base64 -d | tail -c 32 | base64)"
  run nixRecord --apply <<<"seedmatic-bioskop-1:${hostRaw}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"equals it"* ]]
  run nixRecord --apply <<<"$nixPublic"
  [ "$status" -eq 0 ]
  cp "$keys" "$BATS_TEST_TMPDIR/before"
  run nixRecord --apply <<<"seedmatic-bioskop-1:$(head -c 32 /dev/urandom | base64)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already records a nixSigning"* ]]
  cmp "$keys" "$BATS_TEST_TMPDIR/before"
}

@test "--record-nix-signing is for host-MACHINE only, with --public - and nothing else" {
  hostRecorded
  run renew --record-nix-signing shared --public - <<<"$nixPublic"
  [ "$status" -eq 1 ]
  [[ "$output" == *"host-MACHINE, MACHINE one of"* ]]
  run renew --record-nix-signing host-corp-mac --public - <<<"$nixPublic"
  [ "$status" -eq 1 ]
  run renew --record-nix-signing host-bioskop <<<"$nixPublic"
  [ "$status" -eq 64 ]
  [[ "$output" == *"goes with --public - and --apply only"* ]]
  run renew --record-nix-signing host-bioskop --public - --key existing <<<"$nixPublic"
  [ "$status" -eq 64 ]
}

@test "--apply rewrites keys.json, keys.yaml's public view, without a ciphertext or the sops metadata" {
  run renew --create bot --usage bot-signing --comment "rke2lab bot" --apply
  [ "$status" -eq 0 ]
  json="${keys%/*}/keys.json"
  [ -f "$json" ]
  run grep -cF 'ENC[' "$json"
  [ "$output" = 0 ]
  [ "$(yq -r 'has("sops")' "$json")" = false ]
  diff <(yq -o=json --from-file "$PUBLIC_YQ" "$keys") "$json"
}

@test "a dry run writes no keys.json" {
  run renew --create bot --usage bot-signing --comment "rke2lab bot"
  [ "$status" -eq 0 ]
  [ ! -e "${keys%/*}/keys.json" ]
}
