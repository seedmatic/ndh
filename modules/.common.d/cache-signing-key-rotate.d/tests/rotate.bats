#!/usr/bin/env bats
# cache-signing-key-rotate against a real sops, a throwaway age key and a real `nix key`, in a
# throwaway git repository whose cache-trust.yaml rule comes BEFORE a catch-all with different
# recipients — the shape in which encrypting a temp path silently dropped a recipient once.

bats_require_minimum_version 1.5.0

setup() {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/catalog"
  git -C "$repo" init -q
  age-keygen -o "$BATS_TEST_TMPDIR/age.txt" 2>/dev/null
  age-keygen -o "$BATS_TEST_TMPDIR/age2.txt" 2>/dev/null
  export SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/age.txt"
  first="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
  second="$(age-keygen -y "$BATS_TEST_TMPDIR/age2.txt")"
  cat >"$repo/.sops.yaml" <<EOF
creation_rules:
  - path_regex: '(^|/)catalog/cache-trust\.yaml$'
    encrypted_comment_regex: 'sops:encrypted'
    age: $first,$second
  - path_regex: '.*'
    encrypted_comment_regex: 'sops:encrypted'
    age: $first
EOF
  file="$repo/catalog/cache-trust.yaml"
  cat >"$file" <<'EOF'
# Fleet signing private keys, SOPS-encrypted.
caches:
  cachix:
    old-fleet-1:
      # sops:encrypted
      private: old-bare-private
other:
  keep: as-is
EOF
  (cd "$repo" && sops --input-type yaml --output-type yaml encrypt -i catalog/cache-trust.yaml)
  # The real wrapper runs the command as `if "$@"`: errexit is OFF inside it, so the stub does the same.
  printf 'ndh::logger:command:run() { shift; local rc=0; if "$@"; then :; else rc=$?; fi; return "$rc"; }\n' >"$BATS_TEST_TMPDIR/trampoline.sh"
  sed -e "s#@nixBashTrampoline@#$BATS_TEST_TMPDIR/trampoline.sh#" -e 's#@loggerTag@#test#' -e "s#@nix@#$(command -v nix)#" \
    "$BATS_TEST_DIRNAME/../cache-signing-key-rotate.sh" >"$BATS_TEST_TMPDIR/rotate"
}

rotate() { (cd "$repo" && bash -euo pipefail "$BATS_TEST_TMPDIR/rotate" "$@"); }
decrypted() { sops --input-type yaml --output-type yaml -d "$file"; }

@test "a dry run generates nothing, prints no public and leaves the file untouched" {
  cp "$file" "$BATS_TEST_TMPDIR/before"
  run rotate --to new-fleet-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"caches.cachix.old-fleet-1  →  caches.cachix.new-fleet-1"* ]]
  [[ "$output" != *"new-fleet-1:"* ]]
  cmp "$file" "$BATS_TEST_TMPDIR/before"
}

@test "--apply replaces the entry, the new private is ENC[ and the public is printed" {
  run rotate --to new-fleet-1 --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"new-fleet-1:"* ]]
  [ "$(yq eval -r '.caches.cachix | keys | join(",")' "$file")" = new-fleet-1 ]
  yq eval -r '.caches.cachix."new-fleet-1".private' "$file" | grep -q '^ENC\['
  # The recorded private signs for the printed public.
  printf 'new-fleet-1:%s' "$(decrypted | yq eval -r '.caches.cachix."new-fleet-1".private' -)" >"$BATS_TEST_TMPDIR/secret"
  [ "$(nix --extra-experimental-features nix-command key convert-secret-to-public <"$BATS_TEST_TMPDIR/secret")" \
    = "$(printf '%s\n' "$output" | grep -o 'new-fleet-1:[A-Za-z0-9+/=]*' | head -1)" ]
}

@test "--apply keeps the file's own rule's recipients and everything outside caches.cachix" {
  [ "$(yq eval '.sops.age | length' "$file")" = 2 ]
  decrypted | yq eval 'del(.caches.cachix)' - >"$BATS_TEST_TMPDIR/rest.before"
  run rotate --to new-fleet-1 --apply
  [ "$status" -eq 0 ]
  [ "$(yq eval '.sops.age | length' "$file")" = 2 ]
  decrypted | yq eval 'del(.caches.cachix)' - >"$BATS_TEST_TMPDIR/rest.after"
  cmp "$BATS_TEST_TMPDIR/rest.before" "$BATS_TEST_TMPDIR/rest.after"
}

@test "a run whose rule and envelope disagree on recipients is refused, and changes nothing" {
  (cd "$repo" && sops --input-type yaml --output-type yaml -d catalog/cache-trust.yaml >"$BATS_TEST_TMPDIR/plain.yaml")
  cp "$BATS_TEST_TMPDIR/plain.yaml" "$file"
  (cd "$repo" && sops --input-type yaml --output-type yaml encrypt --age "$first" -i catalog/cache-trust.yaml)
  cp "$file" "$BATS_TEST_TMPDIR/before"
  run rotate --to new-fleet-1 --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"recipients would change"*"sops updatekeys"* ]]
  cmp "$file" "$BATS_TEST_TMPDIR/before"
}

@test "the same name, or a name without -<n>, is refused" {
  run rotate --to old-fleet-1 --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"a rotation takes a new name"* ]]
  run rotate --to fleet --apply
  [ "$status" -eq 64 ]
}

@test "two fleet keys in the file are refused: this replaces exactly one" {
  (cd "$repo" && printf '"second-private"' | sops set --input-type yaml --value-stdin catalog/cache-trust.yaml '["caches"]["cachix"]["other-fleet-1"]')
  run rotate --to new-fleet-1 --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds 2 fleet signing keys"* ]]
}

# The REAL wrapper traces its command on request (NDH_LOGGER_XTRACE=1), and a trace writes every
# expanded value — the new private included — into the log sink: the guard must cancel the request.
@test "under the real logger wrapper, even with a trace requested, the sink never carries the new private" {
  sink="$BATS_TEST_TMPDIR/sink"
  sed -e "s#@nixBashTrampoline@#$BATS_TEST_DIRNAME/../../shell.d/nix-bash-trampoline.sh#" \
    -e 's#@loggerTag@#test#' -e "s#@nix@#$(command -v nix)#" \
    "$BATS_TEST_DIRNAME/../cache-signing-key-rotate.sh" >"$BATS_TEST_TMPDIR/rotate"
  NDH_LOGGER_XTRACE=1 NDH_BASH_TRAMPOLINED=1 LOGGER_CMD=cat ACTIVATION_LOG_FILE="$sink" run rotate --to new-fleet-1 --apply
  [ "$status" -eq 0 ]
  # The sink is written by a process substitution that may outlive the script by a moment.
  for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'command:run completed' "$sink" && break; sleep 0.5; done
  grep -q 'command:run completed' "$sink"
  decrypted | yq eval -r '.caches.cachix."new-fleet-1".private' - >"$BATS_TEST_TMPDIR/private"
  [ -s "$BATS_TEST_TMPDIR/private" ]
  run ! grep -qF -f "$BATS_TEST_TMPDIR/private" "$sink"
  run ! grep -q '^\[test\] +' "$sink"
}
