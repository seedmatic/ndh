#!/usr/bin/env bats
# keys-reconcile window (roles × keys K4) against a real sops and a throwaway age key: a fixture ndh revision (an
# authority, one machine's host key with a pending slot, three sops files) pushed to a local bare that stands for the
# remote; the seat as the machine, its publication made as K3 makes it. The « oui » comes on fd 3, as on a terminal.
# It writes into its own worktree and commits there; every postcondition has a mutant. No private is printed.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  : "${NDH_TRAMPOLINE:?the ndh bash trampoline}"
  # The window needs the trampoline's secret window (fix/secret-xtrace-guard): without it, it refuses (a case below).
  declare -F >/dev/null
  age-keygen -o "$t/age.txt" 2>/dev/null
  export SOPS_AGE_KEY_FILE="$t/age.txt"
  operator=$(age-keygen -y "$SOPS_AGE_KEY_FILE")
  for n in ca old new; do ssh-keygen -q -t ed25519 -N '' -C "$n" -f "$t/$n"; done

  : "the fixture revision"
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
  CAPUB="$(cut -d' ' -f2 "$t/ca.pub")" CAPRIV="$(<"$t/ca")" OLDPUB="$(cut -d' ' -f2 "$t/old.pub")" \
    yq -n '
      .authorities.fabric.type = "ssh-ed25519" | .authorities.fabric.usage = ["ssh-authority"] |
      .authorities.fabric.slots."26-01-01".public = strenv(CAPUB) |
      .authorities.fabric.slots."26-01-01".private = strenv(CAPRIV) |
      (.authorities.fabric.slots."26-01-01".private | key) headComment = "sops:encrypted" |
      .keys."host-seat".type = "ssh-ed25519" | .keys."host-seat".usage = ["ssh-host"] | .keys."host-seat".profiles = [] |
      .keys."host-seat".authority = "fabric" | .keys."host-seat".cert_usage = ["ssh-host"] |
      .keys."host-seat".slots."26-10-17" = {"public": strenv(OLDPUB), "state": "serving", "origin": "keyring"} |
      .keys."host-seat".slots."26-11-01" = {"state": "pending", "origin": "host"}
    ' >"$src/modules/home-manager/ssh.d/keys.yaml"
  printf 'caches:\n  k: v1\n  # sops:encrypted\n  s: secret\n' >"$src/catalog/cache-trust.yaml"
  printf '{}\n' >"$src/catalog/private-caches.json"
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

  install -d -m 0755 "$t/published"
  publish "$t/new.pub" "$t/old"
  printf -- '- {name: seat, kind: darwin, ssh: "", ssh_opts: []}\n' >"$t/machines.yaml"
  printf '[{"class": "host-key", "machine": "seat", "key": "host-seat", "slot": "26-11-01", "oldPublic": "%s", "files": [".secrets"], "principals": ["seat", "seat.lan"]}]\n' \
    "$(cut -d' ' -f1,2 "$t/old.pub")" >"$t/batch.json"
  arm "$(($(date +%s) + 600))" keys-reconcile
  render
}

publish() { # <new public file> <old private>
  local public
  public="$(cut -d' ' -f1,2 "$1")"
  printf '%s\n' "$public" >"$t/published/host-seat@26-11-01.public"
  printf 'seedmatic-rotate v1\nname host-seat\nslot 26-11-01\nkey %s\n' "$public" >"$t/published/host-seat@26-11-01.statement"
  rm -f "$t/published/host-seat@26-11-01.statement.sig"
  ssh-keygen -q -Y sign -f "$2" -n seedmatic-rotate "$t/published/host-seat@26-11-01.statement" </dev/null
}

arm() { # <expires> <tools>: the delegation as ndh-ops writes it (owned by the test's uid, which stands for root here)
  printf 'tools=%s\nexpires=%s\narmed_by=test\n' "$2" "$1" >"$t/delegation"
}

render() {
  local -A vars=(
    [nixBashTrampoline]="$NDH_TRAMPOLINE" [toolPath]="$PATH" [verify]="$BATS_TEST_DIRNAME/../verify.sh" [write]="$BATS_TEST_DIRNAME/../write.sh" [classes]="$BATS_TEST_DIRNAME/../classes"
    [revision]="$rev" [remote]="$t/remote.git" [batch]="$t/batch.json" [machines]="$t/machines.yaml"
    [keysJson]="$t/keys.json" [publishDir]="$t/published" [delegation]="$t/delegation" [keysJsonTool]="$t/keys-json" [ttyIn]="$t/tty" [ttyOut]="$t/prompt"
  )
  local text k
  text="$(cat "$BATS_TEST_DIRNAME/../keys-reconcile.sh")"
  for k in "${!vars[@]}"; do
    case $k in
      nixBashTrampoline | toolPath | verify | write | classes | machines | batch | keysJson) text="${text//@$k@/${vars[$k]}}" ;;
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

window() { # <answer>: runs the window with <answer> typed on its terminal (a file standing for the tty)
  printf '%s\n' "$1" >"$t/tty"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$t/home" XDG_CACHE_HOME="$t/cache" XDG_STATE_HOME="$t/state" bash "$t/keys-reconcile" window
}

tree() { echo "$t/state/keys-reconcile/${rev:0:12}"; }
encrypted() { yq -r 'del(.sops) | .. | select(tag == "!!str" and test("^ENC\["))' "$1" | sort; }

@test "the window records, certifies and re-keys the batch, in one local commit, never pushed" {
  run --separate-stderr window oui
  [ "$status" -eq 0 ]
  [[ $output == *"écrit dans $(tree)"* ]]
  k="$(tree)/modules/home-manager/ssh.d/keys.yaml"
  [ "$(yq -r '.keys."host-seat".slots."26-11-01".state' "$k")" = recorded ]
  [ "$(yq -r '.keys."host-seat".slots."26-11-01".public' "$k")" = "$(cut -d' ' -f2 "$t/new.pub")" ]
  [ "$(yq -r '.keys."host-seat".slots."26-11-01".age' "$k")" = "$(ssh-to-age <"$t/new.pub")" ]
  [ "$(yq -r '.keys."host-seat".slots."26-11-01".recipient' "$k")" = true ]
  yq -r '.keys."host-seat".slots."26-11-01".certificates.fabric."ssh-host"' "$k" >"$t/cert.pub"
  ssh-keygen -L -f "$t/cert.pub" | grep -q "host certificate"
  ssh-keygen -L -f "$t/cert.pub" | grep -qE "^ +seat$"
  [ "$(yq -r '.creation_rules[1].age | length' "$(tree)/.sops.yaml")" = 2 ]
  [ "$(git -C "$(tree)" log -1 --format=%s)" = "keys-reconcile: record 1 host key(s) at ${rev:0:12}" ]
  [ "$(git -C "$t/remote.git" rev-parse refs/heads/develop)" = "$rev" ]
}

@test "after the window, every value it did not set is byte-identical; the new recipient opens the files" {
  window oui
  for f in .secrets catalog/cache-trust.yaml; do
    [ "$(git -C "$t/src" show "HEAD:$f" | yq -r 'del(.sops) | .. | select(tag == "!!str" and test("^ENC\["))' | sort)" = "$(encrypted "$(tree)/$f")" ]
  done
  ssh-to-age -private-key -i "$t/new" >"$t/new.age"
  SOPS_AGE_KEY_FILE="$t/new.age" sops decrypt --input-type yaml --output-type yaml "$(tree)/.secrets" >/dev/null
}

@test "no « oui », nothing written" {
  run --separate-stderr window non
  [ "$status" -eq 5 ]
  [[ $output == *"rien écrit"* ]]
  [ ! -e "$(tree)" ]
}

@test "unarmed, expired, or armed for another tool: refused before anything is measured" {
  for case in "$(($(date +%s) - 1)) keys-reconcile" "$(($(date +%s) + 600)) ndh-keyring"; do
    arm ${case}
    run --separate-stderr window oui
    [ "$status" -eq 3 ]
    [[ $stderr == *"the window is not armed"* ]]
  done
  rm -f "$t/delegation"
  run --separate-stderr window oui
  [ "$status" -eq 3 ]
  [ ! -e "$(tree)" ]
}

@test "mutant: a public swapped between the measure and the write is refused" {
  ssh-keygen -q -t ed25519 -N '' -C other -f "$t/other"
  : "a writer racing the window: the publication changes right after the « oui » (injected into a test copy)"
  printf 'swap() { cut -d" " -f1,2 %q >%q; }\n' "$t/other.pub" "$t/published/host-seat@26-11-01.public" >"$t/swap.sh"
  sed -i -e "s|^source .*/write.sh\$|&\nsource $t/swap.sh|" \
    -e 's|^  local again class$|  swap\n&|' "$t/keys-reconcile"
  grep -q '^  swap$' "$t/keys-reconcile"
  run --separate-stderr window oui
  [ "$status" -ne 0 ]
  [[ $stderr == *"its publication changed since it was measured"* ]]
  [ ! -e "$(tree)" ]
}

@test "mutant: a forged statement is refused, nothing written" {
  ssh-keygen -q -t ed25519 -N '' -C forger -f "$t/forger"
  publish "$t/new.pub" "$t/forger"
  run --separate-stderr window oui
  [ "$status" -eq 4 ]
  [[ $output == *"not signed by the old public keys.yaml records"* ]]
  [ ! -e "$(tree)" ]
}

@test "mutant: a whole-file re-encryption is refused, nothing committed" {
  : "sops rotate stands in for a re-encryption: every value gets a fresh data key and IV"
  cp "$BATS_TEST_DIRNAME/../write.sh" "$t/write.sh"
  : ".secrets only, a file the window sets no field in: the ENC[…] guard alone must refuse it"
  sed -i 's|sops updatekeys -y --input-type yaml "\$f"|sops updatekeys -y --input-type yaml "$f" \&\& { [[ $f != .secrets ]] \|\| sops rotate -i --input-type yaml --output-type yaml "$f"; }|' "$t/write.sh"
  grep -q 'sops rotate -i' "$t/write.sh"
  sed -i "s|^source .*/write.sh\$|source $t/write.sh|" "$t/keys-reconcile"
  run --separate-stderr window oui
  [ "$status" -ne 0 ]
  [[ $stderr == *".secrets: an encrypted value changed (a whole-file re-encryption?)"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "mutant: a field set beyond the window's is refused, nothing committed" {
  cp "$BATS_TEST_DIRNAME/../write.sh" "$t/write.sh"
  sed -i 's|^  kill "\$agentPid" 2>/dev/null \|\| true$|  reconcile::sopsSet "$keysYaml" "[\\"keys\\"][\\"host-seat\\"][\\"comment\\"]" "\\"x\\""\n&|' "$t/write.sh"
  grep -q 'host-seat\\"\]\[\\"comment' "$t/write.sh"
  sed -i "s|^source .*/write.sh\$|source $t/write.sh|" "$t/keys-reconcile"
  run --separate-stderr window oui
  [ "$status" -ne 0 ]
  [[ $stderr == *"keys.yaml changed more than the fields this window set"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "a window left open is refused, not overwritten" {
  window oui
  run --separate-stderr window oui
  [ "$status" -ne 0 ]
  [[ $stderr == *"a previous window was not closed"* ]]
}

@test "without the trampoline's secret window, nothing is decrypted" {
  if (source "$NDH_TRAMPOLINE" >/dev/null 2>&1; declare -F ndh::secret:begin >/dev/null); then
    skip "this trampoline has the secret window"
  fi
  run --separate-stderr window oui
  [ "$status" -ne 0 ]
  [[ $stderr == *"has no ndh::secret window"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

attic() { # the guest's attic publication, signed by the seat's serving (old) key, appended to the batch
  local public sum
  public="seedmatic-m1-attic-1:$(printf 'A%.0s' {1..43})="
  install -d -m 0755 "$t/attic"
  printf '%s\n' "$public" >"$t/attic/attic-m1.cache-key.public"
  sum="$(sha256sum "$t/attic/attic-m1.cache-key.public" | cut -d' ' -f1)"
  printf 'seedmatic-attic v1\nclass attic-cache-key\ncache m1\nmachine seat\nsha256 %s\n' "$sum" >"$t/attic/attic-m1.cache-key.statement"
  ssh-keygen -q -Y sign -f "$t/old" -n seedmatic-attic "$t/attic/attic-m1.cache-key.statement" </dev/null
  D="$t/attic" S="$(cut -d' ' -f1,2 "$t/old.pub")" yq -i -p json -o json \
    '. += [{"class": "attic-cache-key", "machine": "seat", "cache": "m1", "fqdn": "attic.m1", "dir": strenv(D), "keyNameRegex": "seedmatic-m1-attic-[0-9]+", "servingPublic": strenv(S)}]' \
    "$t/batch.json"
}

@test "a window holding a host key and an attic cache key: one worktree, one commit, both recorded" {
  attic
  run --separate-stderr window oui
  [ "$status" -eq 0 ]
  [ "$(yq -r '.keys."host-seat".slots."26-11-01".state' "$(tree)/modules/home-manager/ssh.d/keys.yaml")" = recorded ]
  [ "$(yq -r -p json -o json '.m1.publicKey' "$(tree)/catalog/private-caches.json")" = "$(cat "$t/attic/attic-m1.cache-key.public")" ]
  [ "$(yq -r -p json -o json '.m1.consumers[0]' "$(tree)/catalog/private-caches.json")" = attic.m1 ]
  [ "$(yq -r -p json -o json '.m1.origin.revision' "$(tree)/catalog/private-caches.json")" = "$rev" ]
  cmp "$t/attic/attic-m1.cache-key.statement" "$(tree)/catalog/private-caches.d/statements/attic-m1.cache-key.statement"
  [ "$(git -C "$(tree)" rev-list --count "$rev..HEAD")" = 1 ]
  git -C "$(tree)" log -1 --format=%B | grep -q '^keys-reconcile: record 1 host key(s) at '
  git -C "$(tree)" log -1 --format=%B | grep -q '^keys-reconcile: record 1 attic cache key(s) at '
  [ -z "$(git -C "$(tree)" status --porcelain)" ]
}

@test "attic-cache-key: a cache whose key the revision already records is refused, nothing committed" {
  attic
  : "the revision records a key for m1: a new one is a declared rotation, not a window's"
  printf '{"m1": {"publicKey": "seedmatic-m1-attic-1:%s="}}\n' "$(printf 'B%.0s' {1..43})" >"$t/src/catalog/private-caches.json"
  git -C "$t/src" -c user.email=t@t -c user.name=t commit -q -am recorded
  rev=$(git -C "$t/src" rev-parse HEAD)
  git -C "$t/src" push -q -f "$t/remote.git" HEAD:refs/heads/develop HEAD:refs/heads/main
  render
  run --separate-stderr window oui
  [ "$status" -ne 0 ]
  [[ $stderr == *"privateCaches.m1 already records a key"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "no private is ever printed" {
  run --separate-stderr window oui
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [[ $output$stderr != *"$(sed -n 2p "$t/ca")"* ]]
  [[ $output$stderr != *"AGE-SECRET-KEY"* ]]
}
