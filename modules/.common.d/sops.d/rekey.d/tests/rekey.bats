#!/usr/bin/env bats
# sops-rekey against a real sops and throwaway age keys, in a throwaway repository: two files sealed to three
# recipients, then .sops.yaml retires one of them. No value is printed: the assertions read the sops metadata.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  export HOME="$t/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  for k in op host interim; do age-keygen -o "$t/$k.txt" 2>/dev/null; done
  op=$(age-keygen -y "$t/op.txt") host=$(age-keygen -y "$t/host.txt") interim=$(age-keygen -y "$t/interim.txt")
  export SOPS_AGE_KEY_FILE="$t/op.txt"
  repo="$t/repo"
  git init -q "$repo" && cd "$repo"
  git config user.name t && git config user.email t@t
  rules "$op" "$host" "$interim"
  printf 'a: secret-one\n' >one.yaml
  printf 'b: secret-two\n' >two.yaml
  printf 'not sealed\n' >plain.txt
  : "a YAML file with no extension, as .secrets: sops would take it for binary"
  printf 'c: secret-three\n' >.secrets
  sops encrypt -i one.yaml && sops encrypt -i two.yaml
  sops encrypt -i --input-type yaml --output-type yaml .secrets
  git add .sops.yaml one.yaml two.yaml .secrets plain.txt && git commit -q -m fixture
  rules "$op" "$host"
  git commit -q -am "retire the interim"
}

rules() { # <recipient>…: one rule for the yaml files, one for .secrets
  local IFS=,
  printf 'creation_rules:\n  - path_regex: "\\\\.yaml$"\n    age: "%s"\n  - path_regex: "(^|/)\\\\.secrets$"\n    age: "%s"\n' "$*" "$*" >.sops.yaml
}
recipients() { yq -r '.sops.age[].recipient' "$1" | sort -u | tr '\n' ' '; }
rekey() { run --separate-stderr bash "$BATS_TEST_DIRNAME/../rekey.sh" "$@"; }

@test "re-seals every file to its rule, stages them by name, prints no value" {
  rekey
  [ "$status" -eq 0 ]
  [[ $output == *"re-sealed one.yaml"* && $output == *"re-sealed two.yaml"* && $output == *"re-sealed .secrets"* ]]
  [[ "$output$stderr" != *secret-* ]]
  for f in one.yaml two.yaml .secrets; do
    [ "$(recipients "$f")" = "$(printf '%s\n' "$op" "$host" | sort -u | tr '\n' ' ')" ]
  done
  [ "$(git diff --cached --name-only | sort | tr '\n' ' ')" = ".secrets one.yaml two.yaml " ]
  : "the retired identity opens neither any more, the remaining ones both"
  ! SOPS_AGE_KEY_FILE="$t/interim.txt" sops decrypt one.yaml >/dev/null 2>&1
  SOPS_AGE_KEY_FILE="$t/host.txt" sops decrypt two.yaml >/dev/null 2>&1
  : "staged and not committed, a second run refuses; committed, it has nothing to do"
  rekey
  [ "$status" -eq 1 ]
  git commit -q -m re-sealed
  rekey
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to do"* ]]
}

@test "refused, nothing changed: not at the root, or a sealed file with uncommitted changes" {
  mkdir sub && cd sub
  rekey
  [ "$status" -eq 1 ]
  [[ $stderr == *"run it from the repository's root"* ]]
  cd ..
  printf 'x\n' >>two.yaml
  rekey
  [ "$status" -eq 1 ]
  [[ $stderr == *"two.yaml has uncommitted changes"* ]]
  [ "$(recipients one.yaml | wc -w)" -eq 3 ]
}

@test "mutant: a rekey that skips its postcondition stages a file still sealed to the retired recipient" {
  : "the mutant re-seals nothing and still reports success"
  sed -e 's/^  sops updatekeys -y --input-type "\$(typeOf "\$f")" "\$f".*$/  :/' -e '/is not sealed to its rule.s recipients after updatekeys/d' \
    "$BATS_TEST_DIRNAME/../rekey.sh" >"$t/rekey.sh"
  ! cmp -s "$BATS_TEST_DIRNAME/../rekey.sh" "$t/rekey.sh"
  run --separate-stderr bash "$t/rekey.sh"
  [ "$status" -eq 0 ]
  [[ "$(recipients one.yaml)" == *"$interim"* ]]
}

@test "mutant: a rekey that guesses the type from the extension alone skips .secrets, still sealed to the retired recipient" {
  sed 's/^    \*) set -- "\$1" yaml json ;;$/    *) set -- "$1" binary ;;/' "$BATS_TEST_DIRNAME/../rekey.sh" >"$t/rekey.sh"
  ! cmp -s "$BATS_TEST_DIRNAME/../rekey.sh" "$t/rekey.sh"
  run --separate-stderr bash "$t/rekey.sh"
  [[ $output != *"re-sealed .secrets"* ]]
  [[ "$(recipients .secrets)" == *"$interim"* ]]
}
