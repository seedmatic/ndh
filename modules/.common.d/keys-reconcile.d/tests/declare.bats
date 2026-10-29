#!/usr/bin/env bats
# keys-reconcile declare <machine> (design §p) against a real sops and a throwaway age key: a fixture revision with
# three machines — `own` serves its own key, `shared` serves the shared key (its pushed slot never served), `busy`
# has a born key not yet served — pushed to a local bare that stands for the remote. The « yes » comes from a file
# standing for the tty. Each refusal has its case; the written slot is checked field by field; no private printed.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  : "${NDH_TRAMPOLINE:?the ndh bash trampoline}"
  age-keygen -o "$t/age.txt" 2>/dev/null
  export SOPS_AGE_KEY_FILE="$t/age.txt"
  operator=$(age-keygen -y "$SOPS_AGE_KEY_FILE")
  for n in ca own shared busy; do ssh-keygen -q -t ed25519 -N '' -C "$n" -f "$t/$n"; done
  today=$(date -u +%y-%m-%d)

  src="$t/src"
  mkdir -p "$src/modules/home-manager/ssh.d" "$src/catalog"
  cat >"$src/.sops.yaml" <<EOF
creation_rules:
  - path_regex: '(^|/)(catalog/cache-trust\.yaml|modules/home-manager/ssh\.d/keys\.yaml)$'
    encrypted_comment_regex: 'sops:encrypted'
    age:
      - '$operator'
  - path_regex: '(^|/)\.secrets$'
    age:
      - '$operator'
EOF
  CAPUB="$(cut -d' ' -f2 "$t/ca.pub")" CAPRIV="$(<"$t/ca")" OWN="$(cut -d' ' -f2 "$t/own.pub")" \
    SHARED="$(cut -d' ' -f2 "$t/shared.pub")" BUSY="$(cut -d' ' -f2 "$t/busy.pub")" \
    yq -n '
      .authorities.fabric.type = "ssh-ed25519" | .authorities.fabric.usage = ["ssh-authority"] |
      .authorities.fabric.slots."20-01-01".public = strenv(CAPUB) |
      .authorities.fabric.slots."20-01-01".private = strenv(CAPRIV) |
      (.authorities.fabric.slots."20-01-01".private | key) headComment = "sops:encrypted" |
      .keys."own" = {"type": "ssh-ed25519", "usage": ["ssh-host"], "profiles": [], "slots": {"20-10-17": {"public": strenv(OWN), "state": "serving", "origin": "keyring"}}} |
      .keys."shared" = {"type": "ssh-ed25519", "usage": ["ssh-host"], "profiles": [], "slots": {"20-10-18": {"public": strenv(SHARED), "state": "recorded", "origin": "keyring"}}} |
      .keys."busy" = {"type": "ssh-ed25519", "usage": ["ssh-host"], "profiles": [], "slots": {"20-10-17": {"public": strenv(OWN), "state": "serving", "origin": "keyring"}, "20-11-01": {"public": strenv(BUSY), "state": "recorded", "origin": "host"}}}
    ' >"$src/modules/home-manager/ssh.d/keys.yaml"
  printf 'caches:\n  k: v1\n  # sops:encrypted\n  s: secret\n' >"$src/catalog/cache-trust.yaml"
  printf 'a: one\nb: two\n' >"$src/.secrets"
  (cd "$src" && for f in modules/home-manager/ssh.d/keys.yaml catalog/cache-trust.yaml .secrets; do
    sops encrypt -i --input-type yaml --output-type yaml "$f"
  done)
  yq -o json '{"keys": .keys, "authorities": .authorities} | del(.. | select(tag == "!!str" and test("^ENC\[")))' \
    "$src/modules/home-manager/ssh.d/keys.yaml" >"$t/keys.json"
  git -C "$src" init -q && git -C "$src" -c user.email=t@t -c user.name=t add -A && git -C "$src" -c user.email=t@t -c user.name=t commit -q -m fixture
  rev=$(git -C "$src" rev-parse HEAD)
  git init -q --bare "$t/remote.git"
  git -C "$src" push -q "$t/remote.git" HEAD:refs/heads/develop HEAD:refs/heads/main

  printf -- '- {name: own, kind: nixos, ssh: x, ssh_opts: []}\n- {name: shared, kind: nixos, ssh: x, ssh_opts: []}\n- {name: busy, kind: darwin, ssh: x, ssh_opts: []}\n' >"$t/machines.yaml"
  echo '[]' >"$t/batch.json"
  printf 'tools=keys-reconcile\nexpires=%s\narmed_by=test\n' "$(($(date +%s) + 600))" >"$t/delegation"
  echo '{}' >"$t/host-names.json"
  render
}

render() {
  local -A vars=(
    [nixBashTrampoline]="$NDH_TRAMPOLINE" [toolPath]="$PATH" [verify]="$BATS_TEST_DIRNAME/../verify.sh"
    [write]="$BATS_TEST_DIRNAME/../write.sh" [declare]="$BATS_TEST_DIRNAME/../declare.sh" [close]="$BATS_TEST_DIRNAME/../close.sh" [retire]="$BATS_TEST_DIRNAME/../retire.sh" [hostNamesJson]="$t/host-names.json" [classes]="$BATS_TEST_DIRNAME/../classes"
    [revision]="$rev" [remote]="$t/remote.git" [batch]="$t/batch.json" [machines]="$t/machines.yaml"
    [keysJson]="$t/keys.json" [publishDir]="$t/published" [delegation]="$t/delegation" [keysJsonTool]="$t/keys-json"
    [ttyIn]="$t/tty" [ttyOut]="$t/prompt"
  )
  local text k
  text="$(cat "$BATS_TEST_DIRNAME/../keys-reconcile.sh")"
  for k in "${!vars[@]}"; do
    case $k in
      nixBashTrampoline | toolPath | verify | write | declare | close | retire | classes | machines | batch | keysJson) text="${text//@$k@/${vars[$k]}}" ;;
      *) text="${text//@$k@/$(printf '%q' "${vars[$k]}")}" ;;
    esac
  done
  : "the delegation's owner check reads uid 0: here the test's uid stands for root"
  text="${text//== 0 ]] || return 1/== $(id -u) ]] || return 1}"
  printf '%s\n' "$text" >"$t/keys-reconcile"
  ! grep -q '@[a-zA-Z]*@' "$t/keys-reconcile"
  printf '#!%s\nset -euo pipefail\nset -- %q "$@"\n' "$BASH" "$BATS_TEST_DIRNAME/../../keys-yaml.d/public.yq" >"$t/keys-json"
  cat "$BATS_TEST_DIRNAME/../../keys-yaml.d/keys-json.sh" >>"$t/keys-json"
  chmod +x "$t/keys-json"
}

declare_() { # <answer> <args>...
  printf '%s\n' "$1" >"$t/tty"
  shift
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$t/home" \
    XDG_CACHE_HOME="$t/cache" XDG_STATE_HOME="$t/state" bash "$t/keys-reconcile" declare "$@"
}

tree() { echo "$t/state/keys-reconcile/${rev:0:12}"; }
keys() { echo "$(tree)/modules/home-manager/ssh.d/keys.yaml"; }

@test "a machine serving its own key: the slot is declared pending, born on it, with no bootstrap" {
  run --separate-stderr declare_ yes own
  [ "$status" -eq 0 ]
  [[ $output == *"own.slots.\"$today\".state = pending"* ]]
  [[ $output == *"own.slots.\"$today\".origin = host"* ]]
  [[ $output != *"bootstrap"* ]]
  [ "$(yq -r ".keys.\"own\".slots.\"$today\".state" "$(keys)")" = pending ]
  [ "$(yq -r ".keys.\"own\".slots.\"$today\".origin" "$(keys)")" = host ]
  [ "$(yq -r ".keys.\"own\".slots.\"$today\" | has(\"bootstrap\")" "$(keys)")" = false ]
  [ "$(git -C "$(tree)" log -1 --format=%s)" = "keys-reconcile declare: own@$today, pending, born on own, at ${rev:0:12}" ]
  git -C "$(tree)" log -1 --format=%B | grep -qxF "own.slots.\"$today\".origin = host"
  [ "$(git -C "$t/remote.git" rev-parse refs/heads/develop)" = "$rev" ]
}

@test "a machine on the shared key: the console bootstrap is derived, and its recorded keyring slot does not block" {
  run --separate-stderr declare_ yes shared
  [ "$status" -eq 0 ]
  [[ $output == *"shared.slots.\"$today\".bootstrap = console"* ]]
  [[ $output == *"bound by your witness, its console or your tailnet's node list"* ]]
  [ "$(yq -r ".keys.\"shared\".slots.\"$today\".bootstrap" "$(keys)")" = console ]
}

@test "the fields are shown before the « yes », and nothing is written without it" {
  run --separate-stderr declare_ no own
  [ "$status" -eq 5 ]
  [[ $output == *"own.slots.\"$today\".state = pending"* ]]
  [[ $output == *"nothing written"* ]]
  [ ! -e "$(tree)" ]
}

@test "refused: a born key recorded but not yet served (a rotation in flight)" {
  run --separate-stderr declare_ yes busy
  [ "$status" -eq 3 ]
  [[ $stderr == *"has a rotation in flight"* ]]
  [ ! -e "$(tree)" ]
}

@test "refused: a machine that already has a pending slot" {
  declare_ yes own
  rm -rf "$t/state"
  yq -i ".keys.\"own\".slots.\"$today\" = {\"state\": \"pending\", \"origin\": \"host\"}" "$t/keys.json"
  run --separate-stderr declare_ yes own
  [ "$status" -eq 3 ]
  [[ $stderr == *"has a rotation in flight"* ]]
}

@test "a window of this revision still open: refused BEFORE the « yes », on the terminal, nothing asked" {
  : "the operator's case (2026-10-25): a first declare left its window open; the second must say so before asking"
  declare_ yes own
  : >"$t/prompt"
  run --separate-stderr declare_ yes shared
  [ "$status" -ne 0 ]
  [[ $stderr == *"is still open"* ]]
  grep -q "refused: .*is still open: read it, then close it" "$t/prompt"
  run grep -q 'declare these fields' "$t/prompt"
  [ "$status" -eq 1 ]
}

@test "mutant: a declare that checks the open window only after its « yes » asks first" {
  declare_ yes own
  : >"$t/prompt"
  grep -F -v 'reconcile::tree::free || return 1' "$BATS_TEST_DIRNAME/../declare.sh" >"$t/declare.sh"
  [ "$(grep -c -F 'reconcile::tree::free' "$t/declare.sh")" -eq 0 ]
  sed -i "s|^source .*/declare.sh\$|source $t/declare.sh|" "$t/keys-reconcile"
  grep -q "^source $t/declare.sh\$" "$t/keys-reconcile"
  run --separate-stderr declare_ yes shared
  : "still refused, by tree::open's own check, but only after the operator was asked: what the case above guards"
  [ "$status" -ne 0 ]
  grep -q 'declare these fields' "$t/prompt"
}

@test "refused: a slot that would not sort after the newest one" {
  yq -i ".keys.\"own\".slots.\"99-01-01\" = {\"state\": \"serving\", \"origin\": \"keyring\"}" "$t/keys.json"
  run --separate-stderr declare_ yes own
  [ "$status" -eq 3 ]
  [[ $stderr == *"would not sort after its newest slot 99-01-01"* ]]
}

@test "refused: an unknown machine, a name that is not one, a machine with no host entry" {
  run --separate-stderr declare_ yes nobody
  [ "$status" -eq 3 ]
  [[ $stderr == *"is not in the machine list"* ]]
  run --separate-stderr declare_ yes 'own;rm -rf /'
  [ "$status" -eq 3 ]
  [[ $stderr == *"is not a machine name"* ]]
  printf -- '- {name: ghost, kind: nixos, ssh: x, ssh_opts: []}\n' >>"$t/machines.yaml"
  run --separate-stderr declare_ yes ghost
  [ "$status" -eq 3 ]
  [[ $stderr == *"has no ghost entry"* ]]
}

@test "refused: unarmed, or a second argument" {
  rm -f "$t/delegation"
  run --separate-stderr declare_ yes own
  [ "$status" -eq 3 ]
  [[ $stderr == *"declare is not armed"* ]]
  printf 'tools=keys-reconcile\nexpires=%s\n' "$(($(date +%s) + 600))" >"$t/delegation"
  run --separate-stderr declare_ yes own extra
  [ "$status" -eq 3 ]
  [[ $stderr == *"usage"* ]]
}

@test "mutant: a declaration that re-encrypts .secrets is refused, nothing committed" {
  cp "$BATS_TEST_DIRNAME/../declare.sh" "$t/declare.sh"
  sed -i 's|^  reconcile::tree::check \|\| return 1$|  (cd "$tree" \&\& sops rotate -i --input-type yaml --output-type yaml .secrets >/dev/null 2>\&1)\n&|' "$t/declare.sh"
  grep -q 'sops rotate -i' "$t/declare.sh"
  sed -i "s|^source .*/declare.sh\$|source $t/declare.sh|" "$t/keys-reconcile"
  run --separate-stderr declare_ yes own
  [ "$status" -ne 0 ]
  [[ $stderr == *".secrets: an encrypted value changed"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "mutant: a declaration that writes another field is refused, nothing committed" {
  cp "$BATS_TEST_DIRNAME/../declare.sh" "$t/declare.sh"
  sed -i 's|^  : "postconditions: exactly these fields added|  reconcile::sopsSet "$keysYaml" "[\\"keys\\"][\\"own\\"][\\"comment\\"]" "\\"x\\""\n&|' "$t/declare.sh"
  grep -q 'own\\"\]\[\\"comment' "$t/declare.sh"
  sed -i "s|^source .*/declare.sh\$|source $t/declare.sh|" "$t/keys-reconcile"
  run --separate-stderr declare_ yes own
  [ "$status" -ne 0 ]
  [[ $stderr == *"keys.yaml changed more than the declared slot"* ]]
}

@test "no private is ever printed" {
  run --separate-stderr declare_ yes own
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [[ $output$stderr != *"$(sed -n 2p "$t/ca")"* ]]
  [[ $output$stderr != *"AGE-SECRET-KEY"* ]]
}
