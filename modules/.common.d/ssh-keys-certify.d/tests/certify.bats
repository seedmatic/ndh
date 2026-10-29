#!/usr/bin/env bats
# ssh-keys-certify against a real sops and a throwaway age key, in a throwaway git repository: an
# authority with two slots (the older compromised), a key with ssh-user, a TLS-only key, a
# machine's public-only host key (alpha) and its guest's (alpha-nixos).
# No private value is printed: the assertions read certificates, which are public. The tool reaches
# sops only through a stub that records every call and refuses it (97) unless it is one an --apply
# may make: the --decrypt --extract of one authority slot's private, or a set.

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
  for n in ca-old ca-new host alpha alphan; do ssh-keygen -q -t ed25519 -N '' -f "$n" -C "$n"; done
  keys="$repo/modules/home-manager/ssh.d/keys.yaml"
  OLDPUB="$(cut -d' ' -f2 ca-old.pub)" OLDPRIV="$(<ca-old)" NEWPUB="$(cut -d' ' -f2 ca-new.pub)" NEWPRIV="$(<ca-new)" \
    HOSTPUB="$(cut -d' ' -f2 host.pub)" HOSTPRIV="$(<host)" ALPHAPUB="$(cut -d' ' -f2 alpha.pub)" ALPHANPUB="$(cut -d' ' -f2 alphan.pub)" \
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
      .keys."alpha".type = "ssh-ed25519" |
      .keys."alpha".authority = "fabric" |
      .keys."alpha".cert_usage = ["ssh-host"] |
      .keys."alpha".slots."26-03-03".public = strenv(ALPHAPUB) |
      .keys."alpha-nixos".type = "ssh-ed25519" |
      .keys."alpha-nixos".authority = "fabric" |
      .keys."alpha-nixos".cert_usage = ["ssh-host"] |
      .keys."alpha-nixos".slots."26-03-03".public = strenv(ALPHANPUB) |
      (.authorities.fabric.slots."26-01-01".private | key) headComment = "sops:encrypted" |
      (.authorities.fabric.slots."26-02-02".private | key) headComment = "sops:encrypted" |
      (.keys.host.slots."26-03-03".private | key) headComment = "sops:encrypted"
    ' >"$keys"
  (cd "$repo" && sops --input-type yaml --output-type yaml encrypt -i modules/home-manager/ssh.d/keys.yaml)
  # The stub runs the command the way the real ndh::logger:command:run does — through its
  # ndh::logger:command:invoke, sourced from the real logger — without its log sinks: a failure the
  # script does not check behaves here as it does there.
  printf 'source "%s"\nndh::logger:command:run() { shift; ndh::logger:command:invoke "$@"; return "$NDH_LOGGER_COMMAND_RC"; }\n' "$NDH_LOGGER_SH" >"$BATS_TEST_TMPDIR/trampoline.sh"
  # keys.yaml's public view, rewritten by the real keys-json.sh with the real filter, as the package does.
  printf '#!%s\nexec bash -euo pipefail "%s" "%s" "$@"\n' "$BASH" "$KEYS_JSON_SH" "$PUBLIC_YQ" >"$BATS_TEST_TMPDIR/keys-json"
  chmod +x "$BATS_TEST_TMPDIR/keys-json"
  # The stubs run under the bats bash itself: the darwin build sandbox refuses to exec /usr/bin/env.
  shebang="#!$BASH"
  # The tool takes ssh-agent and ssh-add from ssh-keygen's directory: the real ones, ssh-add recorded.
  local openssh
  openssh="$(dirname "$(command -v ssh-keygen)")"
  mkdir -p "$BATS_TEST_TMPDIR/openssh"
  ln -s "$openssh/ssh-keygen" "$openssh/ssh-agent" "$BATS_TEST_TMPDIR/openssh/"
  printf '%s\nprintf "%%s\\n" "$*" >>%q\nexec %q "$@"\n' "$shebang" "$BATS_TEST_TMPDIR/ssh-add.log" "$openssh/ssh-add" \
    >"$BATS_TEST_TMPDIR/openssh/ssh-add"
  chmod +x "$BATS_TEST_TMPDIR/openssh/ssh-add"
  bake "$FLEET"
  export REAL_SOPS SOPS_LOG="$BATS_TEST_TMPDIR/sops.log"
  REAL_SOPS="$(command -v sops)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  {
    printf '%s\n' "$shebang"
    cat <<'EOF'
line="" prev="" decrypt=0 extract=""
for a in "$@"; do
  case "$a" in -d | --decrypt | decrypt) decrypt=1 ;; esac
  [[ "$prev" == --extract ]] && extract="$a"
  prev="$a"
  if [[ "$a" == \"* ]]; then a="<value>"; elif [[ "$a" == */* ]]; then a="${a##*/}"; fi
  line="${line:+$line }$a"
done
printf '%s\n' "$line" >>"$SOPS_LOG"
op=""
[[ "$1" == set ]] && op=set
((decrypt)) && op=decrypt
private='^\["authorities"\]\["[^"]+"\]\["slots"\]\["[^"]+"\]\["private"\]$'
if [[ "$SOPS_STUB" == apply && "$op" != "${SOPS_STUB_FAIL:-}" ]] &&
  { [[ "$op" == set ]] || { [[ "$op" == decrypt ]] && [[ "$extract" =~ $private ]]; }; }; then
  exec "$REAL_SOPS" "$@"
fi
# A canary for the plaintext sops can quote on stderr: the tool must never show it.
echo "sops stub: refused: $line SOPS-STDERR-CANARY" >&2
exit 97
EOF
  } >"$BATS_TEST_TMPDIR/bin/sops"
  chmod +x "$BATS_TEST_TMPDIR/bin/sops"
}

# alpha, beta and their guests: each machine's names, as the build bakes them.
FLEET="alpha=alpha,alpha.lan alpha-nixos=alpha-nixos,nixos.alpha beta=beta,beta.lan beta-nixos=beta-nixos,nixos.beta"
# The names a union host certificate carried before S3a: a recorded legacy certificate's, never signed now.
UNION="alpha,alpha-nixos,alpha.lan,beta,beta-nixos,beta.lan,nixos.alpha,nixos.beta"

bake() { # <machine=names …>
  sed -e "s#@nixBashTrampoline@#$BATS_TEST_TMPDIR/trampoline.sh#" -e 's#@loggerTag@#test#' -e "s#@hostNames@#$1#" \
    -e "s#@sha256sum@#$(command -v sha256sum)#" -e "s#@sshKeygen@#$BATS_TEST_TMPDIR/openssh/ssh-keygen#" \
    -e "s#@toolPath@#$BATS_TEST_TMPDIR/bin:$PATH#" -e "s#@keysJson@#$BATS_TEST_TMPDIR/keys-json#" \
    "$BATS_TEST_DIRNAME/../ssh-keys-certify.sh" >"$BATS_TEST_TMPDIR/ssh-keys-certify"
}

# keys.yaml's own rule names TWO recipients, the catch-all after it only one: the shape in which a
# re-encryption by rule would drop a recipient, so the tests prove a write keeps the envelope it finds.
# `$1` = sync|nosync: re-key the fixture to its rule or not.
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

# A dry run may call no sops at all; an --apply only what the stub lets through.
certify() {
  local stub=dry
  [[ " $* " == *" --apply "* ]] && stub=apply
  (cd "$repo" && PATH="$BATS_TEST_TMPDIR/bin:$PATH" SOPS_STUB="$stub" bash -euo pipefail "$BATS_TEST_TMPDIR/ssh-keys-certify" "$@")
}

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

@test "a caller's PATH, locale and POSIXLY_CORRECT change nothing: the plan is the same, and none of its tools ran" {
  run certify
  [ "$status" -eq 0 ]
  local want="$output" c
  mkdir -p "$BATS_TEST_TMPDIR/hostile"
  for c in yq awk gawk sort tr paste cut sed grep diff sops ssh-keygen; do
    printf '%s\necho hostile-%s >&2\nexit 1\n' "$shebang" "$c" >"$BATS_TEST_TMPDIR/hostile/$c"
    chmod +x "$BATS_TEST_TMPDIR/hostile/$c"
  done
  # A caller's locale that is not the script's C: C.UTF-8, which both build sandboxes have. fr_FR.UTF-8 is missing in
  # the linux sandbox, and the caller's own bash warned about it into the output compared below. No sandbox has
  # locale data, so none changes sort's order (measured): the collation the script pins is proven outside, never here.
  run env PATH="$BATS_TEST_TMPDIR/hostile:$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 LC_COLLATE=C.UTF-8 \
    POSIXLY_CORRECT=1 SOPS_STUB=dry bash -c 'cd "$1" && bash -euo pipefail "$2"' _ "$repo" "$BATS_TEST_TMPDIR/ssh-keys-certify"
  [ "$status" -eq 0 ]
  [[ "$output" != *hostile-* ]]
  [ "$output" = "$want" ]
}

@test "a dry run plans every missing certificate, in order, each signed by the signing slot, and calls no sops" {
  run certify
  [ "$status" -eq 0 ]
  [[ "$output" == *"next serial  1"* ]]
  [ "$(grep -E '^  (missing|stale|current|kept|unrecorded) ' <<<"$output")" = "$(printf '%s\n' \
    '  missing  host                   26-03-03  ssh-user  signed by fabric@26-02-02' \
    '  missing  alpha                  26-03-03  ssh-host  signed by fabric@26-02-02' \
    '  missing  alpha-nixos            26-03-03  ssh-host  signed by fabric@26-02-02')" ]
  [[ "$output" == *"decrypted: no (dry run)"* ]]
  [ ! -e "$SOPS_LOG" ]
}

@test "--apply decrypts the signing slot's private alone, once, and records each certificate with sops set" {
  run certify --apply
  [ "$status" -eq 0 ]
  [ "$(cat "$SOPS_LOG")" = "$(printf '%s\n' \
    '--decrypt --extract ["authorities"]["fabric"]["slots"]["26-02-02"]["private"] keys.yaml' \
    'set keys.certified.yaml ["keys"]["host"]["slots"]["26-03-03"]["certificates"]["fabric"]["ssh-user"] <value>' \
    'set keys.certified.yaml ["keys"]["alpha"]["slots"]["26-03-03"]["certificates"]["fabric"]["ssh-host"] <value>' \
    'set keys.certified.yaml ["keys"]["alpha-nixos"]["slots"]["26-03-03"]["certificates"]["fabric"]["ssh-host"] <value>')" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ssh-add.log")" = "-t 120 -q -" ]
  [[ "$output" == *"decrypted: fabric@26-02-02"* ]]
}

# Batch 1's flip traces every script: the trace carries the run, and the windows keep every private out of it.
@test "traced, --apply's trace carries the run and no private" {
  (cd "$repo" && PATH="$BATS_TEST_TMPDIR/bin:$PATH" SOPS_STUB=apply bash -x "$BATS_TEST_TMPDIR/ssh-keys-certify" --apply) \
    >/dev/null 2>"$BATS_TEST_TMPDIR/trace"
  grep -q '^+* certify::one ' "$BATS_TEST_TMPDIR/trace"
  for n in ca-old ca-new host alpha alphan; do
    run ! grep -qF -f <(sed -n 2p "$BATS_TEST_TMPDIR/$n") "$BATS_TEST_TMPDIR/trace"
  done
}

@test "a failing decryption says only that sops failed, never what it printed, and changes nothing" {
  export SOPS_STUB_FAIL=decrypt
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"sops decrypt failed (exit 97)"* ]]
  [[ "$output" != *CANARY* ]]
  [[ "$output" == *"decrypted: no"* ]]
  cmp "$keys" before
}

@test "a failing sops set says only that sops failed, never what it printed, and changes nothing" {
  export SOPS_STUB_FAIL=set
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"sops set failed (exit 97)"* ]]
  [[ "$output" != *CANARY* ]]
  [[ "$output" == *"decrypted: fabric@26-02-02"* ]]
  cmp "$keys" before
}

@test "a value the plan reads that is ciphertext refuses the run, before any sops call" {
  (cd "$repo" && sops --input-type yaml --output-type yaml -d -i modules/home-manager/ssh.d/keys.yaml &&
    yq eval -i '(.keys.host.type | key) headComment = "sops:encrypted"' modules/home-manager/ssh.d/keys.yaml &&
    sops --input-type yaml --output-type yaml encrypt -i modules/home-manager/ssh.d/keys.yaml)
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"encrypts values that are not privates"*"keys.host.type"* ]]
  [ ! -e "$SOPS_LOG" ]
}

@test "--apply records a host certificate signed by the signing slot, valid forever" {
  run certify --apply
  [ "$status" -eq 0 ]
  run cert alpha ssh-host
  [[ "$output" == *"host certificate"* ]]
  [[ "$output" == *"Signing CA: ED25519 $(ssh-keygen -lf ca-new.pub | awk '{print $2}')"* ]]
  [[ "$output" == *"Valid: forever"* ]]
}

@test "an ssh-host key not named after a machine is refused, and nothing is signed" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["nix-store"]' \
    "{\"type\": \"ssh-ed25519\", \"authority\": \"fabric\", \"cert_usage\": [\"ssh-host\"], \"slots\": {\"26-03-03\": {\"public\": \"$(cut -d' ' -f2 host.pub)\"}}}")
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"nix-store: an ssh-host key is named after a machine of this build's inventory"* ]]
  [[ "$output" != *"signed "* ]]
  cmp "$keys" before
}

@test "a machine's host key gets exactly its machine's names" {
  certify --apply
  [ "$(names alpha ssh-host)" = "alpha,alpha.lan" ]
}

@test "a host key of a machine the build does not know is refused, and nothing is signed" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["gamma"]' \
    "{\"type\": \"ssh-ed25519\", \"authority\": \"fabric\", \"cert_usage\": [\"ssh-host\"], \"slots\": {\"26-03-03\": {\"public\": \"$(cut -d' ' -f2 alpha.pub)\"}}}")
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"gamma: an ssh-host key is named after a machine of this build's inventory"* ]]
  cmp "$keys" before
}

@test "each new key id carries the hash of its names and its issue stamp" {
  certify --apply
  id="$(key_id alpha ssh-host)"
  [ "$(yq -p json -r .names <<<"$id")" = "$(printf '%s' alpha,alpha.lan | sha256sum | cut -d' ' -f1)" ]
  [[ "$(yq -p json -r .issued <<<"$id")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [ "$(yq -p json -r .marker <<<"$id")" = ndh-ssh-key-meta-v1 ]
}

@test "new serials are non-zero, distinct, and start one above the highest recorded" {
  record_legacy alpha alpha.pub 41 ca-new
  certify --apply
  s="$(for k in alpha alpha-nixos; do serial "$k" ssh-host; done; serial host ssh-user)"
  [ "$(sort -n <<<"$s" | head -1)" = 42 ]
  [ "$(sort -u <<<"$s" | wc -l)" -eq 3 ]
  ! grep -qx 0 <<<"$s"
}

@test "with nothing recorded, serials start at 1" {
  certify --apply
  [ "$({ for k in alpha alpha-nixos; do serial "$k" ssh-host; done; serial host ssh-user; } | sort -n | head -1)" = 1 ]
}

@test "a certificate signed by a compromised authority slot is stale, and re-signed by the signing one" {
  record_legacy alpha alpha.pub 0 ca-old
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"signed alpha@26-03-03 ssh-host with fabric@26-02-02"* ]]
  run cert alpha ssh-host
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
  yq eval -r '.keys."alpha".slots."26-03-03".certificates.fabric."ssh-host"' "$keys" | grep -q '^ssh-ed25519-cert-v01@openssh.com '
}

@test "a second run finds everything current and leaves keys.yaml byte-identical" {
  certify --apply
  cp "$keys" after-first
  rm "$SOPS_LOG"
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"every certificate is current"* ]]
  [[ "$output" == *"decrypted: no (nothing to sign)"* ]]
  cmp "$keys" after-first
  [ ! -e "$SOPS_LOG" ]
}

@test "a changed name list makes the host certificate stale, and only that one is re-signed" {
  certify --apply
  bake "${FLEET/alpha.lan/alpha.lan,alpha.local}"
  run certify
  [[ "$output" == *"stale"*"alpha"*"ssh-host"* ]]
  [[ "$output" == *"current"*"alpha-nixos"*"ssh-host"* ]]
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

@test "a creation rule that disagrees with keys.yaml's envelope changes no recipient: sops set keeps the envelope" {
  narrow_rule nosync
  [ "$(recipients)" = 1 ]
  run certify --apply
  [ "$status" -eq 0 ]
  [ "$(recipients)" = 1 ]
}

@test "a slot with no recorded public is reported as unrecorded, and nothing is recorded for it" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["beta"]' \
    '{"type": "ssh-ed25519", "authority": "fabric", "cert_usage": ["ssh-host"], "slots": {"26-04-04": {}}}')
  run certify --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"unrecorded"*"beta"*"generated and signed at activation"* ]]
  [ "$(yq eval -r '.keys."beta".slots."26-04-04".certificates // "none"' "$keys")" = none ]
}

@test "a signature that fails stops the run and leaves keys.yaml untouched" {
  (cd "$repo" && sops set modules/home-manager/ssh.d/keys.yaml '["keys"]["beta-nixos"]' \
    '{"type": "ssh-ed25519", "authority": "fabric", "cert_usage": ["ssh-host"], "slots": {"26-04-04": {"public": "AAAAnotakey"}}}')
  cp "$keys" before
  run certify --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"keys.yaml left untouched"* ]]
  cmp "$keys" before
}

@test "--apply rewrites keys.json, keys.yaml's public view, without a ciphertext or the sops metadata" {
  run certify --apply
  [ "$status" -eq 0 ]
  json="${keys%/*}/keys.json"
  [ -f "$json" ]
  run grep -cF 'ENC[' "$json"
  [ "$output" = 0 ]
  [ "$(yq -r 'has("sops")' "$json")" = false ]
  diff <(yq -o=json --from-file "$PUBLIC_YQ" "$keys") "$json"
}

@test "a dry run writes no keys.json" {
  run certify
  [ "$status" -eq 0 ]
  [ ! -e "${keys%/*}/keys.json" ]
}
