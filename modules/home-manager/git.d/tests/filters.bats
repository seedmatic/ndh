#!/usr/bin/env bats
# The sops clean/smudge filters, as packaged ($GIT_SOPS = the git-sops-diff output), in a throwaway
# repository whose .sops.yaml puts the file's own rule BEFORE a catch-all with fewer recipients: the
# shape in which encrypting at the wrong path silently drops a recipient.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$t/home"
  # An environment-scoped git config (a Claude session's neutraliser) would replace the filters.
  unset GIT_CONFIG_COUNT
  for v in $(compgen -v GIT_CONFIG_KEY_) $(compgen -v GIT_CONFIG_VALUE_); do unset "$v"; done
  mkdir -p "$HOME"
  age-keygen -o "$t/k1.txt" 2>/dev/null
  age-keygen -o "$t/k2.txt" 2>/dev/null
  age-keygen -o "$t/k3.txt" 2>/dev/null
  export SOPS_AGE_KEY_FILE="$t/k1.txt"
  r1="$(age-keygen -y "$t/k1.txt")"
  r2="$(age-keygen -y "$t/k2.txt")"
  repo="$t/repo"
  git init -q "$repo"
  cd "$repo"
  git config user.name t
  git config user.email t@t
  git config include.path "$GIT_SOPS/sops"
  cat >.sops.yaml <<EOF
creation_rules:
  - path_regex: '(^|/)secret\.yaml$'
    age: $r1,$r2
  - path_regex: '.*'
    age: $r1
EOF
  printf '*.yaml filter=sops-yaml diff=sops-yaml\n*.sh filter=sops-binary diff=sops-binary\n.sops.yaml -filter -diff\n' >.gitattributes
  printf 'token: plain-value-1\n' >secret.yaml
  git add .sops.yaml .gitattributes secret.yaml
}

index_blob() { git cat-file blob ":$1"; }

@test "git add encrypts for the file's OWN rule; the worktree stays plaintext" {
  index_blob secret.yaml | grep -q 'ENC\['
  run ! bash -c "git cat-file blob :secret.yaml | grep -q plain-value-1"
  [ "$(index_blob secret.yaml | yq eval '.sops.age | length' -)" = 2 ]
  grep -q plain-value-1 secret.yaml
}

@test "an unchanged plaintext re-adds to the same blob, byte for byte" {
  git commit -q -m one
  before="$(git rev-parse :secret.yaml)"
  touch secret.yaml
  git add secret.yaml
  [ "$(git rev-parse :secret.yaml)" = "$before" ]
  [ -z "$(git status --porcelain)" ]
}

@test "a changed plaintext is re-encrypted" {
  git commit -q -m one
  before="$(git rev-parse :secret.yaml)"
  printf 'token: plain-value-2\n' >secret.yaml
  git add secret.yaml
  [ "$(git rev-parse :secret.yaml)" != "$before" ]
  index_blob secret.yaml | grep -q 'ENC\['
}

@test "a checkout decrypts" {
  git commit -q -m one
  git clone -q "$repo" "$t/clone" 2>/dev/null || true
  cd "$t/clone"
  git config include.path "$GIT_SOPS/sops"
  rm -f secret.yaml
  git checkout -- secret.yaml
  grep -q plain-value-1 secret.yaml
}

@test "a checkout without the key fails, and writes no empty or partial file" {
  git commit -q -m one
  rm -f secret.yaml
  SOPS_AGE_KEY_FILE="$t/k3.txt" run git checkout -- secret.yaml
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot decrypt secret.yaml"* ]]
  [[ "$output" != *"plain-value"* ]]
  [ ! -s secret.yaml ]
}

@test "an envelope added as it is passes through clean unchanged" {
  git commit -q -m one
  index_blob secret.yaml >"$t/envelope"
  cp "$t/envelope" other.yaml
  git add other.yaml
  cmp -s "$t/envelope" <(index_blob other.yaml)
}

@test "a binary file round-trips" {
  printf '#!/bin/sh\necho plain-binary\n' >run.sh
  git add run.sh
  index_blob run.sh | grep -q '"data": "ENC\['
  git commit -q -m bin
  rm -f run.sh
  git checkout -- run.sh
  grep -q plain-binary run.sh
}

@test "without a .sops.yaml there are no recipients, and clean refuses" {
  git commit -q -m one
  git rm -q --cached .sops.yaml
  rm -f .sops.yaml
  printf 'token: x\n' >new.yaml
  run git add new.yaml
  [ "$status" -ne 0 ]
  [[ "$output" == *"no .sops.yaml"* ]]
}
