#!/usr/bin/env bats
# keys-reconcile plan (roles × keys K4) on throwaway keys, the seat as the one machine (no ssh) and a local bare as
# the remote: it reads no secret and writes nothing; it verifies each publication against the RECORDED old public
# (F1), refuses a public the fleet already holds (F2), refuses an unpushed revision or any argument (F5), and names
# every machine that is not ready, so the batch never goes to the window partly.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  : "${NDH_TRAMPOLINE:?the ndh bash trampoline}"
  install -d -m 0755 "$t/published"
  ssh-keygen -q -t ed25519 -N "" -C old -f "$t/old"
  ssh-keygen -q -t ed25519 -N "" -C new -f "$t/new"
  old="$(cut -d' ' -f1,2 "$t/old.pub")"
  publish "$t/new.pub" "$t/old"

  : "a remote holding one commit on develop: the revision the closure was 'built from'"
  git init -q --bare "$t/remote.git"
  git -C "$t/remote.git" config user.email t@t && git -C "$t/remote.git" config user.name t
  rev=$(git -C "$t/remote.git" commit-tree "$(git -C "$t/remote.git" mktree </dev/null)" -m base)
  git -C "$t/remote.git" update-ref refs/heads/develop "$rev"
  git -C "$t/remote.git" update-ref refs/heads/main "$rev"

  printf -- '- {name: seat, kind: darwin, ssh: "", ssh_opts: []}\n' >"$t/machines.yaml"
  printf '{"keys": {"host-seat": {"slots": {"26-10-17": {"public": "%s"}}}}, "authorities": {}}\n' "${old#ssh-ed25519 }" >"$t/keys.json"
  batch "$old"
  render "$rev"
}

publish() { # <new public file> <old private>: what K3's generate.sh publishes
  local public statement
  public="$(cut -d' ' -f1,2 "$1")"
  printf '%s\n' "$public" >"$t/published/host-seat@26-11-01.public"
  printf 'seedmatic-rotate v1\nname host-seat\nslot 26-11-01\nkey %s\n' "$public" >"$t/published/host-seat@26-11-01.statement"
  rm -f "$t/published/host-seat@26-11-01.statement.sig"
  ssh-keygen -q -Y sign -f "$2" -n seedmatic-rotate "$t/published/host-seat@26-11-01.statement" </dev/null
}

batch() { # <recorded old public>
  printf '[{"class": "host-key", "machine": "seat", "key": "host-seat", "slot": "26-11-01", "oldPublic": "%s", "files": [".secrets"]}]\n' "$1" >"$t/batch.json"
}

render() { # <revision>
  local -A vars=(
    [nixBashTrampoline]="$NDH_TRAMPOLINE" [toolPath]="$PATH" [verify]="$BATS_TEST_DIRNAME/../verify.sh" [write]="$BATS_TEST_DIRNAME/../write.sh" [classes]="$BATS_TEST_DIRNAME/../classes"
    [revision]="$1" [remote]="$t/remote.git" [batch]="$t/batch.json" [machines]="$t/machines.yaml"
    [keysJson]="$t/keys.json" [publishDir]="$t/published" [delegation]="$t/no-delegation" [keysJsonTool]="$t/no-keys-json" [ttyIn]="/dev/null" [ttyOut]="/dev/null"
  )
  local text k
  text="$(cat "$BATS_TEST_DIRNAME/../keys-reconcile.sh")"
  for k in "${!vars[@]}"; do
    case $k in
      nixBashTrampoline | toolPath | verify | write | classes | machines | batch | keysJson) text="${text//@$k@/${vars[$k]}}" ;;
      *) text="${text//@$k@/$(printf '%q' "${vars[$k]}")}" ;;
    esac
  done
  printf '%s\n' "$text" >"$t/keys-reconcile"
  ! grep -q '@[a-zA-Z]*@' "$t/keys-reconcile"
}

kr() { HOME="$t/home" XDG_CACHE_HOME="$t/cache" bash "$t/keys-reconcile" "$@"; }

@test "a verified publication: ready, with its fingerprint, its age and the files it joins" {
  run --separate-stderr kr plan
  [ "$status" -eq 0 ]
  [[ $output == *"✓ seat — host-seat@26-11-01 $(ssh-keygen -lf "$t/new.pub" | cut -d' ' -f2)"* ]]
  [[ $output == *"destinataire $(ssh-to-age <"$t/new.pub") ajouté à : .secrets"* ]]
  [[ $output == *"prêt : la fenêtre (ops next) les enregistrera"* ]]
}

@test "mutant: a statement signed by another key is refused (F1 against the RECORDED public)" {
  ssh-keygen -q -t ed25519 -N "" -C forger -f "$t/forger"
  publish "$t/new.pub" "$t/forger"
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"✗ seat — host-seat@26-11-01 : host-seat@26-11-01: its statement is not signed by the old public keys.yaml records"* ]]
  [[ $output == *"rien ne sera écrit"* ]]
}

@test "mutant: a .public replaced after signing is refused (the statement names another public)" {
  ssh-keygen -q -t ed25519 -N "" -C other -f "$t/other"
  cut -d' ' -f1,2 "$t/other.pub" >"$t/published/host-seat@26-11-01.public"
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"its statement does not name this key, slot and public"* ]]
}

@test "mutant: a publication missing its signature is refused, not read as present" {
  rm -f "$t/published/host-seat@26-11-01.statement.sig"
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"statement.sig was not published"* ]]
}

@test "mutant: a public the fleet already holds is refused (F2, no reuse)" {
  publish "$t/old.pub" "$t/old"
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"its public is already in keys.yaml"* ]]
}

@test "a partial batch: two machines measured, while the others keep serving their key" {
  : "a second machine in the batch, its own old and new key; a third machine listed but in no batch"
  ssh-keygen -q -t ed25519 -N "" -C old2 -f "$t/old2"
  ssh-keygen -q -t ed25519 -N "" -C new2 -f "$t/new2"
  public="$(cut -d' ' -f1,2 "$t/new2.pub")"
  printf '%s\n' "$public" >"$t/published/host-mate@26-11-01.public"
  printf 'seedmatic-rotate v1\nname host-mate\nslot 26-11-01\nkey %s\n' "$public" >"$t/published/host-mate@26-11-01.statement"
  ssh-keygen -q -Y sign -f "$t/old2" -n seedmatic-rotate "$t/published/host-mate@26-11-01.statement" </dev/null
  printf -- '- {name: seat, kind: darwin, ssh: "", ssh_opts: []}\n- {name: mate, kind: darwin, ssh: "", ssh_opts: []}\n- {name: other, kind: nixos, ssh: "", ssh_opts: []}\n' >"$t/machines.yaml"
  printf '[{"class": "host-key", "machine": "seat", "key": "host-seat", "slot": "26-11-01", "oldPublic": "%s", "files": [".secrets"]}, {"class": "host-key", "machine": "mate", "key": "host-mate", "slot": "26-11-01", "oldPublic": "%s", "files": [".secrets"]}]\n' \
    "$old" "$(cut -d' ' -f1,2 "$t/old2.pub")" >"$t/batch.json"
  run --separate-stderr kr plan
  [ "$status" -eq 0 ]
  [[ $output == *"2 clé(s)"* ]]
  [[ $output == *"✓ seat — host-seat@26-11-01"* ]]
  [[ $output == *"✓ mate — host-mate@26-11-01"* ]]
  [[ $output != *"other"* ]]
}

@test "an unpushed revision is refused, before anything is collected" {
  render "$(printf '%040d' 0 | tr 0 a)"
  run --separate-stderr kr plan
  [ "$status" -eq 3 ]
  [[ $stderr == *"is not pushed to"* ]]
}

@test "a closure built from no revision is refused" {
  render ""
  run --separate-stderr kr plan
  [ "$status" -eq 3 ]
  [[ $stderr == *"built from no revision"* ]]
}

@test "any argument but the verb is refused (F5)" {
  run --separate-stderr kr plan --rev x
  [ "$status" -eq 3 ]
  [[ $stderr == *"no other argument"* ]]
}

@test "an empty batch: « rien à faire », nothing fetched" {
  echo '[]' >"$t/batch.json"
  run --separate-stderr kr plan
  [ "$status" -eq 0 ]
  [[ $output == *"rien à faire"* ]]
  [ ! -e "$t/cache/keys-reconcile" ]
}

@test "plan writes nothing but its fetch cache: the publication and the inputs are untouched" {
  before="$(find "$t/published" "$t/keys.json" "$t/batch.json" -type f -exec sha256sum {} + | sort)"
  kr plan
  [ "$(find "$t/published" "$t/keys.json" "$t/batch.json" -type f -exec sha256sum {} + | sort)" = "$before" ]
  [ -z "$(find "$t/published" -newer "$t/keys-reconcile" -type f)" ]
}

@test "a batch entry of a class keys-reconcile does not define is refused, nothing collected" {
  for class in attic-nothing 'host-key;id' '' '../host-key'; do
    C="$class" yq -i -p json -o json '.[0].class = strenv(C)' "$t/batch.json"
    run --separate-stderr kr plan
    [ "$status" -eq 3 ]
    [[ $stderr == *"batch entry 0: no artifact class"* ]]
    [[ $output != *"✓"* ]]
  done
}

attic() { # <signing private> [public]: the guest's attic publication (publish.sh's shape), and a batch of that class only
  local public="${2:-seedmatic-m1-attic-1:$(printf 'A%.0s' {1..43})=}" sum
  install -d -m 0755 "$t/attic"
  printf '%s\n' "$public" >"$t/attic/attic-m1.cache-key.public"
  sum="$(sha256sum "$t/attic/attic-m1.cache-key.public" | cut -d' ' -f1)"
  printf 'seedmatic-attic v1\nclass attic-cache-key\ncache m1\nmachine seat\nsha256 %s\n' "$sum" >"$t/attic/attic-m1.cache-key.statement"
  rm -f "$t/attic/attic-m1.cache-key.statement.sig"
  ssh-keygen -q -Y sign -f "$1" -n seedmatic-attic "$t/attic/attic-m1.cache-key.statement" </dev/null
  printf '[{"class": "attic-cache-key", "machine": "seat", "cache": "m1", "fqdn": "attic.m1", "dir": "%s", "keyNameRegex": "seedmatic-m1-attic-[0-9]+", "servingPublic": "%s"}]\n' \
    "$t/attic" "$old" >"$t/batch.json"
}

@test "attic-cache-key: a guest's publication verified against its RECORDED serving key" {
  attic "$t/old"
  run --separate-stderr kr plan
  [ "$status" -eq 0 ]
  [[ $output == *"✓ seat — cache m1 : seedmatic-m1-attic-1:"* ]]
  [[ $output == *"entrée privateCaches.m1 à enregistrer"* ]]
}

@test "attic-cache-key mutant: a statement signed by another key than the recorded serving one is refused" {
  ssh-keygen -q -t ed25519 -N "" -C forger -f "$t/forger"
  attic "$t/forger"
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"not signed by the host key keys.yaml records as seat's serving one"* ]]
}

@test "attic-cache-key mutant: a public of another metalspace, or replaced after signing, is refused" {
  attic "$t/old" "seedmatic-m2-attic-1:$(printf 'A%.0s' {1..43})="
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"not one m1 cache key named as the catalog accepts it"* ]]
  attic "$t/old"
  printf 'seedmatic-m1-attic-2:%s=\n' "$(printf 'B%.0s' {1..43})" >"$t/attic/attic-m1.cache-key.public"
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"its statement does not name this class, cache, guest and public"* ]]
}

@test "attic-cache-key mutant: a publication missing its signature is refused" {
  attic "$t/old"
  rm -f "$t/attic/attic-m1.cache-key.statement.sig"
  run --separate-stderr kr plan
  [ "$status" -eq 4 ]
  [[ $output == *"statement.sig was not published"* ]]
}

@test "no private is ever printed" {
  run --separate-stderr kr plan
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [[ $output$stderr != *"$(sed -n 2p "$t/old")"* ]]
}
