#!/usr/bin/env bats
# keys-reconcile window (roles × keys K4) against a real sops and a throwaway age key: a fixture ndh revision (an
# authority, one machine's host key with a pending slot, three sops files) pushed to a local bare that stands for the
# remote; the seat as the machine, its publication made as K3 makes it. The « yes » comes on fd 3, as on a terminal.
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
  for n in ca old new shared spare; do ssh-keygen -q -t ed25519 -N '' -C "$n" -f "$t/$n"; done
  : "a shared key (as rdp-host was) whose ssh-host certificate names the seat alone, with a known id: retire revokes it"
  ssh-keygen -q -s "$t/ca" -I shared-host-cert -h -z 7 -n seat,seat.lan "$t/shared.pub"
  mv "$t/shared-cert.pub" "$t/shared-host-cert.pub"
  : "and a user certificate on the same key, another certificate that retire must leave byte-identical"
  ssh-keygen -q -s "$t/ca" -I shared-user-cert -z 9 -n rdp "$t/shared.pub"
  mv "$t/shared-cert.pub" "$t/shared-user-cert.pub"

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
    SHAREDPUB="$(cut -d' ' -f2 "$t/shared.pub")" SPAREPUB="$(cut -d' ' -f2 "$t/spare.pub")" SHAREDCERT="$(cut -d' ' -f1,2 "$t/shared-host-cert.pub")" SHAREDUSER="$(cut -d' ' -f1,2 "$t/shared-user-cert.pub")" \
    yq -n '
      .authorities.fabric.type = "ssh-ed25519" | .authorities.fabric.usage = ["ssh-authority"] |
      .authorities.fabric.slots."26-01-01".public = strenv(CAPUB) |
      .authorities.fabric.slots."26-01-01".private = strenv(CAPRIV) |
      (.authorities.fabric.slots."26-01-01".private | key) headComment = "sops:encrypted" |
      .keys."seat".type = "ssh-ed25519" | .keys."seat".usage = ["ssh-host"] | .keys."seat".profiles = [] |
      .keys."seat".authority = "fabric" | .keys."seat".cert_usage = ["ssh-host"] |
      .keys."seat".slots."26-10-17" = {"public": strenv(OLDPUB), "state": "serving", "origin": "keyring"} |
      .keys."seat".slots."26-11-01" = {"state": "pending", "origin": "host"} |
      .keys."shared".type = "ssh-ed25519" | .keys."shared".usage = ["user-signing"] | .keys."shared".profiles = [] |
      .keys."spare".type = "ssh-ed25519" | .keys."spare".usage = ["user-signing"] | .keys."spare".profiles = [] |
      .keys."spare".slots."26-02-01".public = strenv(SPAREPUB) |
      .keys."shared".slots."26-01-01".public = strenv(SHAREDPUB) |
      .keys."shared".slots."26-01-01".private = "shared-private-fixture" |
      (.keys."shared".slots."26-01-01".private | key) headComment = "sops:encrypted" |
      .keys."shared".slots."26-01-01".certificates.fabric."ssh-host" = strenv(SHAREDCERT) |
      .keys."shared".slots."26-01-01".certificates.fabric."ssh-user" = strenv(SHAREDUSER)
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
  printf '[{"class": "host-key", "machine": "seat", "key": "seat", "slot": "26-11-01", "oldPublic": "%s", "files": [".secrets"], "principals": ["seat", "seat.lan"]}]\n' \
    "$(cut -d' ' -f1,2 "$t/old.pub")" >"$t/batch.json"
  arm "$(($(date +%s) + 600))" keys-reconcile
  echo '{"seat": ["seat", "seat.lan"]}' >"$t/host-names.json"
  echo '[]' >"$t/in-use.json"
  render
}

publish() { # <new public file> <old private>
  local public
  public="$(cut -d' ' -f1,2 "$1")"
  printf '%s\n' "$public" >"$t/published/seat@26-11-01.public"
  printf 'seedmatic-rotate v1\nname seat\nslot 26-11-01\nkey %s\n' "$public" >"$t/published/seat@26-11-01.statement"
  rm -f "$t/published/seat@26-11-01.statement.sig"
  ssh-keygen -q -Y sign -f "$2" -n seedmatic-rotate "$t/published/seat@26-11-01.statement" </dev/null
}

arm() { # <expires> <tools>: the delegation as ndh-ops writes it (owned by the test's uid, which stands for root here)
  printf 'tools=%s\nexpires=%s\narmed_by=test\n' "$2" "$1" >"$t/delegation"
}

render() {
  local -A vars=(
    [nixBashTrampoline]="$NDH_TRAMPOLINE" [toolPath]="$PATH" [verify]="$BATS_TEST_DIRNAME/../verify.sh" [declare]="$BATS_TEST_DIRNAME/../declare.sh" [close]="$BATS_TEST_DIRNAME/../close.sh" [retire]="$BATS_TEST_DIRNAME/../retire.sh" [hostNamesJson]="$t/host-names.json" [inUseKeys]="$t/in-use.json" [write]="$BATS_TEST_DIRNAME/../write.sh" [classes]="$BATS_TEST_DIRNAME/../classes"
    [revision]="$rev" [remote]="$t/remote.git" [batch]="$t/batch.json" [machines]="$t/machines.yaml"
    [keysJson]="$t/keys.json" [publishDir]="$t/published" [delegation]="$t/delegation" [keysJsonTool]="$t/keys-json" [ttyIn]="$t/tty" [ttyOut]="$t/prompt"
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

window() { # <answer>...: runs the window with each <answer> typed on its terminal, in order (a file standing for the tty)
  printf '%s\n' "$@" >"$t/tty"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$t/home" XDG_CACHE_HOME="$t/cache" XDG_STATE_HOME="$t/state" bash "$t/keys-reconcile" window
}

tree() { echo "$t/state/keys-reconcile/${rev:0:12}"; }
encrypted() { yq -r 'del(.sops) | .. | select(tag == "!!str" and test("^ENC\["))' "$1" | sort; }

@test "the window records, certifies and re-keys the batch, the born key serving and the old one retired, in one local commit" {
  run --separate-stderr window yes
  [ "$status" -eq 0 ]
  [[ $output == *"written in $(tree)"* ]]
  k="$(tree)/modules/home-manager/ssh.d/keys.yaml"
  [ "$(yq -r '.keys."seat".slots."26-11-01".state' "$k")" = serving ]
  [ "$(yq -r '.keys."seat".slots."26-10-17".state' "$k")" = retired ]
  [ "$(yq -r '.keys."seat".slots."26-11-01".public' "$k")" = "$(cut -d' ' -f2 "$t/new.pub")" ]
  [ "$(yq -r '.keys."seat".slots."26-11-01".age' "$k")" = "$(ssh-to-age <"$t/new.pub")" ]
  [ "$(yq -r '.keys."seat".slots."26-11-01".recipient' "$k")" = true ]
  yq -r '.keys."seat".slots."26-11-01".certificates.fabric."ssh-host"' "$k" >"$t/cert.pub"
  ssh-keygen -L -f "$t/cert.pub" | grep -q "host certificate"
  ssh-keygen -L -f "$t/cert.pub" | grep -qE "^ +seat$"
  [ "$(yq -r '.creation_rules[1].age | length' "$(tree)/.sops.yaml")" = 2 ]
  [ "$(git -C "$(tree)" log -1 --format=%s)" = "keys-reconcile: record 1 host key(s) at ${rev:0:12}" ]
  [ "$(git -C "$t/remote.git" rev-parse refs/heads/develop)" = "$rev" ]
}

@test "after the window, every value it did not set is byte-identical; the new recipient opens the files" {
  window yes
  for f in .secrets catalog/cache-trust.yaml; do
    [ "$(git -C "$t/src" show "HEAD:$f" | yq -r 'del(.sops) | .. | select(tag == "!!str" and test("^ENC\["))' | sort)" = "$(encrypted "$(tree)/$f")" ]
  done
  ssh-to-age -private-key -i "$t/new" >"$t/new.age"
  SOPS_AGE_KEY_FILE="$t/new.age" sops decrypt --input-type yaml --output-type yaml "$(tree)/.secrets" >/dev/null
}

@test "mutant: a window that leaves the replaced slot unretired is refused by its own postcondition" {
  : "the mutant drops the sops write of the retirement and keeps its expected-state line"
  grep -F -v '[\"${replaced}\"][\"state\"]" '"'"'"retired"'"'"'' "$BATS_TEST_DIRNAME/../write.sh" >"$t/write.sh"
  [ "$(grep -c -F '"retired"' "$BATS_TEST_DIRNAME/../write.sh")" -gt "$(grep -c -F '"retired"' "$t/write.sh")" ]
  sed -i "s|^source .*/write.sh\$|source $t/write.sh|" "$t/keys-reconcile"
  grep -q "^source $t/write.sh\$" "$t/keys-reconcile"
  run --separate-stderr window yes
  [ "$status" -ne 0 ]
  [[ $stderr == *"keys.yaml changed more than the fields this window set"* ]]
}

@test "no « yes », nothing written" {
  run --separate-stderr window no
  [ "$status" -eq 5 ]
  [[ $output == *"nothing written"* ]]
  [ ! -e "$(tree)" ]
}

@test "unarmed, expired, or armed for another tool: refused before anything is measured" {
  for case in "$(($(date +%s) - 1)) keys-reconcile" "$(($(date +%s) + 600)) ndh-keyring"; do
    arm ${case}
    run --separate-stderr window yes
    [ "$status" -eq 3 ]
    [[ $stderr == *"the window is not armed"* ]]
  done
  rm -f "$t/delegation"
  run --separate-stderr window yes
  [ "$status" -eq 3 ]
  [ ! -e "$(tree)" ]
}

@test "mutant: a public swapped between the measure and the write is refused" {
  ssh-keygen -q -t ed25519 -N '' -C other -f "$t/other"
  : "a writer racing the window: the publication changes right after the « yes » (injected into a test copy)"
  printf 'swap() { cut -d" " -f1,2 %q >%q; }\n' "$t/other.pub" "$t/published/seat@26-11-01.public" >"$t/swap.sh"
  sed -i -e "s|^source .*/write.sh\$|&\nsource $t/swap.sh|" \
    -e 's|^  local again class$|  swap\n&|' "$t/keys-reconcile"
  grep -q '^  swap$' "$t/keys-reconcile"
  run --separate-stderr window yes
  [ "$status" -ne 0 ]
  [[ $stderr == *"its publication changed since it was measured"* ]]
  [ ! -e "$(tree)" ]
}

@test "mutant: a forged statement is refused, nothing written" {
  ssh-keygen -q -t ed25519 -N '' -C forger -f "$t/forger"
  publish "$t/new.pub" "$t/forger"
  run --separate-stderr window yes
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
  run --separate-stderr window yes
  [ "$status" -ne 0 ]
  [[ $stderr == *".secrets: an encrypted value changed (a whole-file re-encryption?)"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "mutant: a field set beyond the window's is refused, nothing committed" {
  cp "$BATS_TEST_DIRNAME/../write.sh" "$t/write.sh"
  sed -i 's|^  kill "\$agentPid" 2>/dev/null \|\| true$|  reconcile::sopsSet "$keysYaml" "[\\"keys\\"][\\"seat\\"][\\"comment\\"]" "\\"x\\""\n&|' "$t/write.sh"
  grep -q 'seat\\"\]\[\\"comment' "$t/write.sh"
  sed -i "s|^source .*/write.sh\$|source $t/write.sh|" "$t/keys-reconcile"
  run --separate-stderr window yes
  [ "$status" -ne 0 ]
  [[ $stderr == *"keys.yaml changed more than the fields this window set"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "a window left open is refused BEFORE any question, on the terminal too, not overwritten" {
  window yes
  : >"$t/prompt"
  run --separate-stderr window yes
  [ "$status" -ne 0 ]
  [[ $stderr == *"is still open"* ]]
  : "the operator's terminal says it, and was asked nothing"
  grep -q "refused: .*is still open: read it, then close it (ndh-ops keys-reconcile close ${rev:0:12})" "$t/prompt"
  run grep -q '\[yes/no\]' "$t/prompt"
  [ "$status" -eq 1 ]
}

close() { # <answer> <rev12>
  printf '%s\n' "$1" >"$t/tty"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$t/home" XDG_CACHE_HOME="$t/cache" XDG_STATE_HOME="$t/state" bash "$t/keys-reconcile" close "$2"
}

@test "close: an open, unmerged window is removed after « yes », its worktree and its branch, and a new window opens" {
  window yes
  [ -d "$(tree)" ]
  run --separate-stderr close yes "${rev:0:12}"
  [ "$status" -eq 0 ]
  [[ $output == *"closed: keys-reconcile/${rev:0:12} deleted"* ]]
  [ ! -e "$(tree)" ]
  run git -C "$t/cache/keys-reconcile/ndh.git" rev-parse --verify -q "refs/heads/keys-reconcile/${rev:0:12}"
  [ "$status" -ne 0 ]
  run --separate-stderr window yes
  [ "$status" -eq 0 ]
}

@test "close: without « yes », nothing removed" {
  window yes
  run --separate-stderr close no "${rev:0:12}"
  [ "$status" -eq 5 ]
  [ -d "$(tree)" ]
}

@test "close: refused, nothing removed — a path, an unknown window, uncommitted changes, unarmed" {
  window yes
  run --separate-stderr close yes "../../etc"
  [ "$status" -eq 3 ]
  [[ $stderr == *"is not a revision's 12-character prefix"* ]]
  grep -q "refused: close: '../../etc' is not a revision's 12-character prefix" "$t/prompt"
  run --separate-stderr close yes "0123456789ab"
  [ "$status" -eq 3 ]
  [[ $stderr == *"no window"* ]]
  printf 'x\n' >>"$(tree)/.secrets"
  run --separate-stderr close yes "${rev:0:12}"
  [ "$status" -eq 3 ]
  [[ $stderr == *"has uncommitted changes"* ]]
  [ -d "$(tree)" ]
  git -C "$(tree)" checkout -q -- .secrets
  rm -f "$t/delegation"
  run --separate-stderr close yes "${rev:0:12}"
  [ "$status" -eq 3 ]
  [[ $stderr == *"close is not armed"* ]]
  [ -d "$(tree)" ]
}

@test "close: a window already merged into develop is removed after « yes », said merged, its commit kept on develop" {
  window yes
  head="$(git -C "$(tree)" rev-parse HEAD)"
  git -C "$t/cache/keys-reconcile/ndh.git" update-ref refs/heads/develop "$head"
  run --separate-stderr close yes "${rev:0:12}"
  [ "$status" -eq 0 ]
  [[ $output == *"merged already: keys-reconcile/${rev:0:12} (${head:0:12}) is on develop, nothing is lost"* ]]
  [[ $output == *"closed: keys-reconcile/${rev:0:12} deleted, its commit stays on develop."* ]]
  [ ! -e "$(tree)" ]
  ! git -C "$t/cache/keys-reconcile/ndh.git" rev-parse --verify -q "refs/heads/keys-reconcile/${rev:0:12}"
  [ "$(git -C "$t/cache/keys-reconcile/ndh.git" rev-parse refs/heads/develop)" = "$head" ]
}

@test "close: a merged window with uncommitted changes is still refused, nothing removed" {
  window yes
  git -C "$t/cache/keys-reconcile/ndh.git" update-ref refs/heads/develop "$(git -C "$(tree)" rev-parse HEAD)"
  echo stray >"$(tree)/stray"
  run --separate-stderr close yes "${rev:0:12}"
  [ "$status" -eq 3 ]
  [[ $stderr == *"has uncommitted changes"* ]]
  [ -d "$(tree)" ]
}

@test "mutant: a close that does not see the merge says it discards a merged window, and fails the case above" {
  window yes
  git -C "$t/cache/keys-reconcile/ndh.git" update-ref refs/heads/develop "$(git -C "$(tree)" rev-parse HEAD)"
  : "the mutant never finds the merge"
  sed 's|then mergedOn=$ref \&\& break; fi|then :; fi|' "$BATS_TEST_DIRNAME/../close.sh" >"$t/close.sh"
  ! cmp -s "$BATS_TEST_DIRNAME/../close.sh" "$t/close.sh"
  bash -n "$t/close.sh"
  sed -i "s|^source .*/close.sh\$|source $t/close.sh|" "$t/keys-reconcile"
  grep -q "^source $t/close.sh\$" "$t/keys-reconcile"
  run --separate-stderr close yes "${rev:0:12}"
  [[ $output == *"without merging it"* ]]
  [[ $output != *"nothing is lost"* ]]
}

@test "without the trampoline's secret window, nothing is decrypted" {
  if (source "$NDH_TRAMPOLINE" >/dev/null 2>&1; declare -F ndh::secret:begin >/dev/null); then
    skip "this trampoline has the secret window"
  fi
  run --separate-stderr window yes
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
  run --separate-stderr window yes
  [ "$status" -eq 0 ]
  [ "$(yq -r '.keys."seat".slots."26-11-01".state' "$(tree)/modules/home-manager/ssh.d/keys.yaml")" = serving ]
  [ "$(yq -r '.keys."seat".slots."26-10-17".state' "$(tree)/modules/home-manager/ssh.d/keys.yaml")" = retired ]
  [ "$(yq -r -p json -o json '.m1.publicKey' "$(tree)/catalog/private-caches.json")" = "$(cat "$t/attic/attic-m1.cache-key.public")" ]
  [ "$(yq -r -p json -o json '.m1.consumers[0]' "$(tree)/catalog/private-caches.json")" = attic.m1 ]
  [ "$(yq -r -p json -o json '.m1.origin.revision' "$(tree)/catalog/private-caches.json")" = "$rev" ]
  cmp "$t/attic/attic-m1.cache-key.statement" "$(tree)/catalog/private-caches.d/statements/attic-m1.cache-key.statement"
  [ "$(git -C "$(tree)" rev-list --count "$rev..HEAD")" = 1 ]
  git -C "$(tree)" log -1 --format=%B | grep -q '^keys-reconcile: record 1 host key(s) at '
  git -C "$(tree)" log -1 --format=%B | grep -q '^keys-reconcile: record 1 attic cache key(s) at '
  [ -z "$(git -C "$(tree)" status --porcelain)" ]
}

@test "mutant: a class that writes after another and spoils its file is refused, nothing committed" {
  attic
  : "the attic row, written second, also re-encrypts .secrets: the check after ALL writes must catch it"
  cp "$BATS_TEST_DIRNAME/../classes/attic-cache-key.sh" "$t/attic-cache-key.sh"
  sed -i '/catalog\/private-caches.json >>"\$work\/staged"$/i\  (cd "$tree" \&\& sops rotate -i --input-type yaml --output-type yaml .secrets)' "$t/attic-cache-key.sh"
  grep -q 'sops rotate -i' "$t/attic-cache-key.sh"
  sed -i "s|^source .*/attic-cache-key.sh\$|source $t/attic-cache-key.sh|" "$t/keys-reconcile"
  grep -q "^source $t/attic-cache-key.sh\$" "$t/keys-reconcile"
  run --separate-stderr window yes
  [ "$status" -ne 0 ]
  [[ $stderr == *".secrets: an encrypted value changed (a whole-file re-encryption?)"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "mutant: an attic entry without its statement pair is refused, nothing committed" {
  attic
  cp "$BATS_TEST_DIRNAME/../classes/attic-cache-key.sh" "$t/attic-cache-key.sh"
  sed -i 's|^    cp "\$work/attic-\${cache}.cache-key.statement" "\$work/attic-\${cache}.cache-key.statement.sig" "\$statements/"$|    :|' "$t/attic-cache-key.sh"
  ! grep -q 'cache-key.statement.sig" "$statements/"' "$t/attic-cache-key.sh" || false
  sed -i "s|^source .*/attic-cache-key.sh\$|source $t/attic-cache-key.sh|" "$t/keys-reconcile"
  run --separate-stderr window yes
  [ "$status" -ne 0 ]
  [[ $stderr == *"privateCaches.m1 has no statement pair beside it"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "attic-cache-key: a cache whose key the revision already records is refused, nothing committed" {
  attic
  : "the revision records a key for m1: a new one is a declared rotation, not a window's"
  printf '{"m1": {"publicKey": "seedmatic-m1-attic-1:%s="}}\n' "$(printf 'B%.0s' {1..43})" >"$t/src/catalog/private-caches.json"
  git -C "$t/src" -c user.email=t@t -c user.name=t commit -q -am recorded
  rev=$(git -C "$t/src" rev-parse HEAD)
  git -C "$t/src" push -q -f "$t/remote.git" HEAD:refs/heads/develop HEAD:refs/heads/main
  render
  run --separate-stderr window yes
  [ "$status" -ne 0 ]
  [[ $stderr == *"privateCaches.m1 already records a key"* ]]
  [ "$(git -C "$(tree)" rev-parse HEAD)" = "$rev" ]
}

@test "no private is ever printed" {
  run --separate-stderr window yes
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [[ $output$stderr != *"$(sed -n 2p "$t/ca")"* ]]
  [[ $output$stderr != *"AGE-SECRET-KEY"* ]]
}

bootstrap_batch() { # <console|tailnet|…>: the slot as a bootstrap: no old public, no statement published
  printf '[{"class": "host-key", "machine": "seat", "key": "seat", "slot": "26-11-01", "oldPublic": "", "bootstrap": "%s", "files": [".secrets"], "principals": ["seat", "seat.lan"]}]\n' "$1" >"$t/batch.json"
  rm -f "$t/published/seat@26-11-01".statement{,.sig}
}
fp() { ssh-keygen -lf "$t/new.pub" | cut -d' ' -f2; }

@test "a console bootstrap: ONE « yes », nothing typed, the key recorded with no statement; the full fingerprint and the witness shown" {
  bootstrap_batch console
  run --separate-stderr window yes
  [ "$status" -eq 0 ]
  [[ $output == *"seat@26-11-01 $(fp)"* ]]
  [[ $output == *"witness: you, at the console of seat, or the node list of your tailnet"* ]]
  [ "$(yq -r '.keys."seat".slots."26-11-01".state' "$(tree)/modules/home-manager/ssh.d/keys.yaml")" = serving ]
  [ "$(yq -r '.keys."seat".slots."26-10-17".state' "$(tree)/modules/home-manager/ssh.d/keys.yaml")" = retired ]
  : "no question but the « yes »: each layer trusts the one below (the operator, 2026-10-26)"
  [ "$(grep -o '\[yes/no\]' "$t/prompt" | wc -l)" -eq 1 ]
  run grep -q '8 premiers' "$t/prompt"
  [ "$status" -eq 1 ]
}

@test "a tailnet bootstrap: the same, its witness the tailnet's node list" {
  bootstrap_batch tailnet
  run --separate-stderr window yes
  [ "$status" -eq 0 ]
  [[ $output == *"witness: the node list of your tailnet (seat alone under its name)"* ]]
  [ "$(yq -r '.keys."seat".slots."26-11-01".state' "$(tree)/modules/home-manager/ssh.d/keys.yaml")" = serving ]
}

@test "a bootstrap without « yes » writes nothing" {
  bootstrap_batch console
  run --separate-stderr window no
  [ "$status" -eq 5 ]
  [ ! -e "$(tree)" ]
}

@test "a bootstrap still refuses a reused public (F2)" {
  bootstrap_batch tailnet
  cut -d' ' -f1,2 "$t/old.pub" >"$t/published/seat@26-11-01.public"
  run --separate-stderr window yes
  [ "$status" -eq 4 ]
  [[ $output == *"already in keys.yaml"* ]]
}

@test "an unknown bootstrap value is refused, never taken for a bootstrap: F1 is not skipped" {
  bootstrap_batch somethingelse
  run --separate-stderr window yes
  [ "$status" -eq 4 ]
  [[ $output == *"unknown bootstrap 'somethingelse'"* ]]
  [ ! -e "$(tree)" ]
}

@test "mutant: a verify that takes any non-empty bootstrap for one skips F1 for an unknown value" {
  bootstrap_batch somethingelse
  cp "$BATS_TEST_DIRNAME/../verify.sh" "$t/verify.sh"
  sed -i 's/^    console | tailnet) published=(public) ;;$/    *) published=(public) ;;/; /unknown bootstrap/d' "$t/verify.sh"
  sed -i 's/^  if \[\[ -z \$bootstrap \]\]; then$/  if [[ -z $bootstrap ]]; then/' "$t/verify.sh"
  run grep -c "unknown bootstrap" "$t/verify.sh"
  [ "$output" = 0 ]
  bash -n "$t/verify.sh"
  sed -i "s|^source .*/verify.sh\$|source $t/verify.sh|" "$t/keys-reconcile"
  grep -q "^source $t/verify.sh\$" "$t/keys-reconcile"
  : "the published files list keeps the statement for an unknown value (keys-reconcile.sh's own allow-list), so here"
  : "the mutant's verify accepts the public alone: the slot measures as ready, which the case above refuses"
  run --separate-stderr bash -c 'HOME="$1/home" XDG_CACHE_HOME="$1/cache" bash "$1/keys-reconcile" plan' _ "$t"
  [[ $output == *"✓ seat — seat@26-11-01"* ]]
}

@test "a normal slot never takes the bootstrap path: its statement stays required" {
  rm -f "$t/published/seat@26-11-01.statement.sig"
  run --separate-stderr window yes
  [ "$status" -eq 4 ]
  [[ $output == *"statement.sig was not published"* ]]
}

# keys-reconcile retire: the window's commit merged as 🧭 merges it, the tool re-rendered at that revision.
merged() { # the window's branch becomes the remote's develop, and the tool reads that revision's keys.json
  local wt
  wt=$(tree)
  git -C "$wt" push -q "$t/remote.git" "HEAD:refs/heads/develop"
  rev=$(git -C "$wt" rev-parse HEAD)
  yq -o json '{"keys": .keys, "authorities": .authorities, "revoked": (.revoked // {}), "revoked_certificates": (.revoked_certificates // {})} | del(.. | select(tag == "!!str" and test("^ENC\[")))' \
    "$wt/modules/home-manager/ssh.d/keys.yaml" >"$t/keys.json"
  render
}
retire() { # <answer> <machine>
  printf '%s\n' "$1" >"$t/tty"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$t/home" XDG_CACHE_HOME="$t/cache" XDG_STATE_HOME="$t/state" bash "$t/keys-reconcile" retire "$2"
}
@test "retire: the retired slot deleted and revoked, the shared host cert removed and revoked by its id, in one commit" {
  window yes
  merged
  run --separate-stderr retire yes seat
  [ "$status" -eq 0 ]
  k="$(tree)/modules/home-manager/ssh.d/keys.yaml"
  [ "$(yq -r '.keys."seat".slots | has("26-10-17")' "$k")" = false ]
  [ "$(yq -r '.keys."seat".slots."26-11-01".state' "$k")" = serving ]
  [ "$(yq -r '.revoked."seat@26-10-17".public' "$k")" = "$(cut -d' ' -f2 "$t/old.pub")" ]
  [ "$(yq -r '.keys.shared.slots."26-01-01".certificates.fabric | has("ssh-host")' "$k")" = false ]
  : "the shared key's user certificate is another certificate: byte-identical"
  [ "$(yq -r '.keys.shared.slots."26-01-01".certificates.fabric."ssh-user"' "$k")" = "$(cut -d' ' -f1,2 "$t/shared-user-cert.pub")" ]
  [ "$(yq -r '.revoked_certificates."shared@26-01-01/7".key_id' "$k")" = shared-host-cert ]
  [ "$(yq -r '.revoked_certificates."shared@26-01-01/7".authority' "$k")" = fabric ]
  [ "$(git -C "$(tree)" log -1 --format=%s)" = "keys-reconcile retire: seat, at ${rev:0:12}" ]
}

@test "retire: the KRL built from its result revokes the old key's certificate and the shared cert, not the new key's" {
  window yes
  merged
  retire yes seat
  k="$(tree)/modules/home-manager/ssh.d/keys.yaml"
  yq -o json '{"keys": .keys, "authorities": .authorities, "revoked": (.revoked // {}), "revoked_certificates": (.revoked_certificates // {})} | del(.. | select(tag == "!!str" and test("^ENC\[")))' "$k" >"$t/after.json"
  run bash "$BATS_TEST_DIRNAME/../../keys-yaml.d/krl.sh" "$t/after.json" "$t/krl"
  [ "$status" -eq 0 ]
  : "a certificate over the revoked old key, valid forever: cut by the key's revocation"
  ssh-keygen -q -s "$t/ca" -I old-host -h -n seat "$t/old.pub"
  run ssh-keygen -Q -f "$t/krl" "$t/old-cert.pub"
  [[ $output == *"REVOKED"* ]]
  run ssh-keygen -Q -f "$t/krl" "$t/shared-host-cert.pub"
  [[ $output == *"REVOKED"* ]]
  yq -r '.keys."seat".slots."26-11-01".certificates.fabric."ssh-host"' "$k" >"$t/new-cert.pub"
  run ssh-keygen -Q -f "$t/krl" "$t/new-cert.pub"
  [[ $output == *": ok"* ]]
  run ssh-keygen -Q -f "$t/krl" "$t/shared-user-cert.pub"
  [[ $output == *": ok"* ]]
}

@test "retire: without « yes », nothing written" {
  window yes
  merged
  run --separate-stderr retire no seat
  [ "$status" -eq 5 ]
  [ ! -e "$(tree)" ]
}

@test "retire: refused before the « yes » — the current slot not serving, an unknown machine, unarmed" {
  yq -i -p json -o json '.keys."seat".slots."26-10-17".state = "recorded"' "$t/keys.json"
  run --separate-stderr retire yes seat
  [ "$status" -eq 3 ]
  [[ $stderr == *"current slot is not serving"* ]]
  run --separate-stderr retire yes nobody
  [ "$status" -eq 3 ]
  [[ $stderr == *"not in the machine list"* ]]
  rm -f "$t/delegation"
  run --separate-stderr retire yes seat
  [ "$status" -eq 3 ]
  [[ $stderr == *"retire is not armed"* ]]
  run grep -q 'retire and revoke' "$t/prompt"
  [ "$status" -eq 1 ]
}

@test "retire: a certificate principal that maps to no machine is refused, nothing written" {
  window yes
  merged
  echo '{"seat": ["seat"]}' >"$t/host-names.json"
  run --separate-stderr retire yes seat
  [ "$status" -eq 3 ]
  [[ $stderr == *"names 'seat.lan', which maps to no machine"* ]]
  [ ! -e "$(tree)" ]
}

@test "mutant: a retire that keeps the revoked slot in keys.yaml is refused by its postcondition" {
  window yes
  merged
  grep -F -v 'sops unset --input-type yaml --output-type yaml "$keysYaml" "[\"keys\"][\"${keyName}\"][\"slots\"][\"${slot}\"]"' "$BATS_TEST_DIRNAME/../retire.sh" |
    sed 's/^      reconcile::fail "sops unset failed on ${keyName}@${slot}" || return 1$/      :/' >"$t/retire.sh"
  [ "$(grep -c -F '[\"slots\"][\"${slot}\"]" 2>/dev/null' "$t/retire.sh")" -eq 0 ]
  bash -n "$t/retire.sh"
  sed -i "s|^source .*/retire.sh\$|source $t/retire.sh|" "$t/keys-reconcile"
  grep -q "^source $t/retire.sh\$" "$t/keys-reconcile"
  run --separate-stderr retire yes seat
  [ "$status" -ne 0 ]
  [[ $stderr == *"keys.yaml changed more than the retired slots and certificates"* ]]
}

: "a principal that is a substring of another machine's name: the serving seat, listed first, must not stand for sea"
substring_cert() {
  ssh-keygen -q -s "$t/ca" -I sea-host-cert -h -z 11 -n sea "$t/shared.pub"
  C="$(cut -d' ' -f1,2 "$t/shared-cert.pub")" yq -i -p json -o json '.keys.shared.slots."26-01-01".certificates.fabric."ssh-host" = strenv(C)' "$t/keys.json"
  echo '{"seat": ["seat", "seat.lan"], "sea": ["sea"]}' >"$t/host-names.json"
}

@test "retire: a principal matched exactly, never as a substring of another machine's name: sea's cert is not revoked" {
  window yes
  merged
  substring_cert
  run --separate-stderr retire yes seat
  [ "$status" -eq 0 ]
  [[ $output != *"shared@26-01-01: host certificate removed"* ]]
  [ "$(yq -r '.revoked_certificates // {} | length' "$(tree)/modules/home-manager/ssh.d/keys.yaml")" = 0 ]
}

@test "mutant: retire matching principals by substring revokes sea's cert, so the exact-match case bites" {
  window yes
  merged
  substring_cert
  : "the code before the fix: a substring match, its first machine taken"
  sed 's/any_c(\. == strenv(P))) | \.key'"'"' "\$hostNamesJson"$/contains([strenv(P)])) | .key'"'"' "$hostNamesJson" | head -1/' \
    "$BATS_TEST_DIRNAME/../retire.sh" >"$t/retire.sh"
  [ "$(grep -c -F 'contains([strenv(P)])) | .key'"'"' "$hostNamesJson" | head -1' "$t/retire.sh")" -eq 1 ]
  sed -i "s|^source .*/retire.sh\$|source $t/retire.sh|" "$t/keys-reconcile"
  run --separate-stderr retire yes seat
  [[ $output == *"shared@26-01-01: host certificate removed"* ]]
}

@test "retire: a principal that maps to more than one machine is refused, nothing written" {
  window yes
  merged
  echo '{"seat": ["seat", "seat.lan"], "other": ["seat.lan"]}' >"$t/host-names.json"
  run --separate-stderr retire yes seat
  [ "$status" -eq 3 ]
  [[ $stderr == *"names 'seat.lan', which maps to more than one machine (seat other)"* ]]
  [ ! -e "$(tree)" ]
}

# keys-reconcile retire-key: a whole key no configuration uses, at the fixture's pushed revision.
retire_key() { # <answer> <key>…
  printf '%s\n' "$1" >"$t/tty"
  shift
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t HOME="$t/home" XDG_CACHE_HOME="$t/cache" XDG_STATE_HOME="$t/state" bash "$t/keys-reconcile" retire-key "$@"
}

@test "retire-key: each slot's public revoked and the key deleted, every other encrypted value kept, in one commit" {
  run --separate-stderr retire_key yes shared
  [ "$status" -eq 0 ]
  k="$(tree)/modules/home-manager/ssh.d/keys.yaml"
  [ "$(yq -r '.keys | has("shared")' "$k")" = false ]
  [ "$(yq -r '.revoked."shared@26-01-01".public' "$k")" = "$(cut -d' ' -f2 "$t/shared.pub")" ]
  [ "$(yq -r '.keys."seat".slots."26-10-17".public' "$k")" = "$(cut -d' ' -f2 "$t/old.pub")" ]
  [ "$(encrypted "$k" | grep -c .)" -eq "$(($(encrypted "$src/modules/home-manager/ssh.d/keys.yaml" | grep -c .) - 1))" ]
  [ "$(yq -p json -r '.keys | has("shared")' "$(tree)/modules/home-manager/ssh.d/keys.json")" = false ]
  [ "$(git -C "$(tree)" log -1 --format=%s)" = "keys-reconcile retire-key: shared, at ${rev:0:12}" ]
}

@test "retire-key: refused before the « yes » — a machine's key, an unknown key, a key in use, unarmed; without « yes », nothing" {
  run --separate-stderr retire_key yes seat
  [ "$status" -eq 3 ]
  [[ $stderr == *"seat is a machine's host key"* ]]
  run --separate-stderr retire_key yes nobody
  [ "$status" -eq 3 ]
  [[ $stderr == *"keys.yaml has no nobody entry"* ]]
  echo '["shared"]' >"$t/in-use.json"
  run --separate-stderr retire_key yes shared
  [ "$status" -eq 3 ]
  [[ $stderr == *"shared is still used by a configuration of this revision"* ]]
  echo '[]' >"$t/in-use.json"
  run --separate-stderr retire_key no shared
  [ "$status" -eq 5 ]
  [ ! -e "$(tree)" ]
  rm -f "$t/delegation"
  run --separate-stderr retire_key yes shared
  [ "$status" -eq 3 ]
  [[ $stderr == *"retire-key is not armed"* ]]
}

@test "mutant: a retire-key that keeps the key in keys.yaml is refused by its postcondition" {
  grep -F -v 'sops unset --input-type yaml --output-type yaml "$keysYaml" "[\"keys\"][\"${key}\"]"' "$BATS_TEST_DIRNAME/../retire.sh" |
    sed 's/^      reconcile::fail "sops unset failed on ${key}" || return 1$/      :/' >"$t/retire.sh"
  [ "$(grep -c -F 'sops unset failed on ${key}"' "$t/retire.sh")" -eq 0 ]
  bash -n "$t/retire.sh"
  sed -i "s|^source .*/retire.sh\$|source $t/retire.sh|" "$t/keys-reconcile"
  run --separate-stderr retire_key yes shared
  [ "$status" -ne 0 ]
  [[ $stderr == *"keys.yaml changed more than the retired keys and their revocations"* ]]
}

@test "mutant: a retire-key that keeps the key's encrypted values in the snapshot is refused by tree::check" {
  : "so the snapshot filter is what lets the key's own private leave, and tree::check still guards the others"
  grep -F -v 'grep -v -F "keys.${key}." "$snapshot" >"$snapshot.kept" || true' "$BATS_TEST_DIRNAME/../retire.sh" |
    grep -F -v 'mv "$snapshot.kept" "$snapshot"' >"$t/retire.sh"
  [ "$(grep -c -F 'snapshot.kept' "$t/retire.sh")" -eq 0 ]
  sed -i "s|^source .*/retire.sh\$|source $t/retire.sh|" "$t/keys-reconcile"
  run --separate-stderr retire_key yes shared
  [ "$status" -ne 0 ]
  [[ $stderr == *"an encrypted value changed"* ]]
}

@test "retire-key: several keys in one window, one commit, each slot revoked" {
  run --separate-stderr retire_key yes shared spare
  [ "$status" -eq 0 ]
  k="$(tree)/modules/home-manager/ssh.d/keys.yaml"
  [ "$(yq -r '.keys | has("shared") or has("spare")' "$k")" = false ]
  [ "$(yq -r '.revoked."shared@26-01-01".public' "$k")" = "$(cut -d' ' -f2 "$t/shared.pub")" ]
  [ "$(yq -r '.revoked."spare@26-02-01".public' "$k")" = "$(cut -d' ' -f2 "$t/spare.pub")" ]
  [ "$(git -C "$(tree)" rev-list --count "${rev}..HEAD")" -eq 1 ]
  [ "$(git -C "$(tree)" log -1 --format=%s)" = "keys-reconcile retire-key: shared spare, at ${rev:0:12}" ]
}

@test "retire-key: one refused key refuses them all before the « yes » — a machine's key among them, a key named twice" {
  run --separate-stderr retire_key yes shared seat
  [ "$status" -eq 3 ]
  [[ $stderr == *"seat is a machine's host key"* ]]
  run --separate-stderr retire_key yes shared shared
  [ "$status" -eq 3 ]
  [[ $stderr == *"shared is named twice"* ]]
  [ ! -e "$(tree)" ]
  run grep -q 'retire and revoke' "$t/prompt"
  [ "$status" -eq 1 ]
}

: "a window of this revision left open: retire and retire-key refuse BEFORE the plan, nothing asked"
open_window() {
  window yes
  : >"$t/prompt"
}

@test "retire-key and retire: a window of this revision still open is refused before the plan, nothing asked" {
  open_window
  run --separate-stderr retire_key yes shared
  [ "$status" -ne 0 ]
  [[ $stderr == *"is still open"* ]]
  [[ $output != *"retire-key at revision"* ]]
  run --separate-stderr retire yes seat
  [ "$status" -ne 0 ]
  [[ $stderr == *"is still open"* ]]
  [[ $output != *"retire at revision"* ]]
  run grep -q 'retire and revoke' "$t/prompt"
  [ "$status" -eq 1 ]
}

@test "mutant: without the guard, retire-key and retire print their plan and ask, though they cannot write" {
  open_window
  grep -v -F 'reconcile::tree::free || return 1' "$BATS_TEST_DIRNAME/../retire.sh" >"$t/retire.sh"
  [ "$(grep -c -F 'reconcile::tree::free' "$t/retire.sh")" -eq 0 ]
  sed -i "s|^source .*/retire.sh\$|source $t/retire.sh|" "$t/keys-reconcile"
  run --separate-stderr retire_key yes shared
  [ "$status" -ne 0 ]
  [[ $output == *"retire-key at revision"* ]]
  run --separate-stderr retire yes seat
  [[ $output == *"retire at revision"* ]]
  [ "$(grep -c 'retire and revoke' "$t/prompt")" -eq 2 ]
}

: "the window's output holds to keys.schema.yaml: a bootstrap slot, declared so, keeps its bootstrap once recorded and"
: "served (the record; the schema refused it before 2026-10-26, and window 1's merge left keys.yaml invalid)"
@test "a bootstrap's window output validates against keys.schema.yaml, its declared bootstrap kept on the served slot" {
  bootstrap_batch console
  run --separate-stderr window yes
  [ "$status" -eq 0 ]
  k="$(tree)/modules/home-manager/ssh.d/keys.yaml"
  [ "$(yq -r '.keys."seat".slots."26-11-01".state' "$k")" = serving ]
  : "the fixture declares no bootstrap on the slot (the batch carries it): put it as declare writes it, then validate"
  yq 'del(.sops) | .keys."seat".slots."26-11-01".bootstrap = "console"' "$k" >"$t/plain.yaml"
  : "the schema names the fleet's machines; this fixture's machine is seat"
  yq '.properties.keys.patternProperties |= with_entries(.key |= sub("^\\^\\(\\(", "^((seat|"))' "$KEYS_SCHEMA" >"$t/schema.yaml"
  check-jsonschema --schemafile "$t/schema.yaml" "$t/plain.yaml"
  : "the control: the schema as it was, a bootstrap only while pending, refuses the same output"
  yq '.["$defs"].machineSlots.additionalProperties.then.properties.state = {"const": "pending"}' "$t/schema.yaml" >"$t/old.yaml"
  run check-jsonschema --schemafile "$t/old.yaml" "$t/plain.yaml"
  [ "$status" -ne 0 ]
  [[ $output == *"'pending' was expected"* ]]
}
