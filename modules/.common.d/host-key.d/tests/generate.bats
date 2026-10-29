#!/usr/bin/env bats
# ndh-host-key-generate on throwaway keys (roles × keys K3): the pending slot's key is born 0600 in a 0700 directory by
# a rename, never regenerated; its public and the F1 statement are published, and the statement verifies against
# the OLD key's recorded public in namespace seedmatic-rotate; a run that stopped is completed by the next; an old key
# that is not the recorded one publishes nothing; no private is ever printed.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  install -d -m 0755 "$t/var"
  ssh-keygen -q -t ed25519 -N "" -C old -f "$t/old"
  render "$(cut -d' ' -f1,2 "$t/old.pub")"
}

render() { # <recorded old public> [bootstrap]
  # Rendered as replaceVars does (each value shell-quoted, as ndh.hostKey.generateVars holds them), through the real
  # ndh trampoline and logger, and run whole: its last line is the dispatch the activation runs. NDH_TRAMPOLINE comes
  # from the flake check (the sandbox cannot search the store).
  : "${NDH_TRAMPOLINE:?the ndh bash trampoline}"
  local -A vars=(
    [nixBashTrampoline]="$NDH_TRAMPOLINE"
    [machine]=m [slot]=26-11-01 [base]="$t/var" [slotDir]="$t/var/host-key/slots" [owner]="$(id -u)"
    [keyFile]="$t/var/host-key/slots/26-11-01/ssh_host_ed25519_key" [publishDir]="$t/var/host-key/published"
    [oldKey]="$t/old" [oldPublic]="$1" [bootstrap]="${2:-}" [console]="$t/console"
  )
  local text k
  text="$(cat "$BATS_TEST_DIRNAME/../generate.sh")"
  for k in "${!vars[@]}"; do
    if [[ $k == nixBashTrampoline ]]; then text="${text//@$k@/${vars[$k]}}"; else text="${text//@$k@/$(printf '%q' "${vars[$k]}")}"; fi
  done
  printf '%s\n' "$text" >"$t/generate"
  ! grep -q '@[a-zA-Z]*@' "$t/generate"
  chmod +x "$t/generate"
}

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
key() { echo "$t/var/host-key/slots/26-11-01/ssh_host_ed25519_key"; }
pub() { echo "$t/var/host-key/published/m@26-11-01.$1"; }

verify() { # the statement against the OLD key's public, as the seat will
  printf 'm %s\n' "$(cut -d' ' -f1,2 "$t/old.pub")" >"$t/allowed"
  ssh-keygen -q -Y verify -f "$t/allowed" -I m -n seedmatic-rotate -s "$(pub statement.sig)" <"$(pub statement)"
}

@test "the key is born 0600 in a 0700 directory, and its public and F1 statement are published" {
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [ "$(mode "$t/var/host-key/slots")" = 700 ]
  [ "$(mode "$(dirname "$(key)")")" = 700 ]
  [ "$(mode "$t/var/host-key/published")" = 755 ]
  [ "$(mode "$(key)")" = 600 ]
  [ "$(cat "$(pub public)")" = "$(ssh-keygen -y -f "$(key)" | cut -d' ' -f1,2)" ]
  grep -qxF "key $(cat "$(pub public)")" "$(pub statement)"
  grep -qxF "slot 26-11-01" "$(pub statement)"
  verify
  [ -z "$(find "$t/var" -name '.generate.*' -o -name '.publish.*')" ]
}

@test "the statement does not verify under another namespace, nor against another key" {
  bash "$t/generate"
  printf 'm %s\n' "$(cut -d' ' -f1,2 "$t/old.pub")" >"$t/allowed"
  run ssh-keygen -q -Y verify -f "$t/allowed" -I m -n seedmatic-attest -s "$(pub statement.sig)" <"$(pub statement)"
  [ "$status" -ne 0 ]
  ssh-keygen -q -t ed25519 -N "" -C other -f "$t/other"
  printf 'm %s\n' "$(cut -d' ' -f1,2 "$t/other.pub")" >"$t/allowed"
  run ssh-keygen -q -Y verify -f "$t/allowed" -I m -n seedmatic-rotate -s "$(pub statement.sig)" <"$(pub statement)"
  [ "$status" -ne 0 ]
}

@test "a second run regenerates nothing, and publishes the same public" {
  bash "$t/generate"
  before="$(sha256sum "$(key)")"
  first="$(cat "$(pub public)")"
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$(key)")" = "$before" ]
  [ "$(cat "$(pub public)")" = "$first" ]
  [[ $stderr != *generated* ]]
  verify
}

@test "a run that stopped after the key, before the publication, is completed by the next" {
  bash "$t/generate"
  rm -f "$t/var/host-key/published/"*
  before="$(sha256sum "$(key)")"
  bash "$t/generate"
  [ "$(sha256sum "$(key)")" = "$before" ]
  [ "$(cat "$(pub public)")" = "$(ssh-keygen -y -f "$(key)" | cut -d' ' -f1,2)" ]
  verify
}

@test "an old key that is not the recorded one publishes nothing" {
  ssh-keygen -q -t ed25519 -N "" -C other -f "$t/other"
  render "$(cut -d' ' -f1,2 "$t/other.pub")"
  run --separate-stderr bash "$t/generate"
  [ "$status" -ne 0 ]
  [[ $stderr == *"not the host key keys.yaml records"* ]]
  [ ! -e "$(pub public)" ]
  [ ! -e "$(pub statement.sig)" ]
}

@test "a slot directory that is a symlink is refused before anything is written" {
  mkdir -p "$t/elsewhere" "$t/var/host-key/slots"
  chmod 0700 "$t/var/host-key/slots"
  ln -s "$t/elsewhere" "$t/var/host-key/slots/26-11-01"
  run --separate-stderr bash "$t/generate"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not a directory (a symlink?)"* ]]
  [ -z "$(ls -A "$t/elsewhere")" ]
  [ ! -e "$t/var/host-key/published" ]
}

@test "a group- or world-writable directory on the way is refused" {
  mkdir -p "$t/var/host-key/slots"
  chmod 0777 "$t/var/host-key/slots"
  run --separate-stderr bash "$t/generate"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is group- or world-writable"* ]]
  [ ! -e "$(key)" ]
}

@test "a published directory that is a symlink is refused" {
  mkdir -p "$t/elsewhere"
  install -d -m 0711 "$t/var/host-key"
  ln -s "$t/elsewhere" "$t/var/host-key/published"
  run --separate-stderr bash "$t/generate"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not a directory (a symlink?)"* ]]
  [ ! -e "$(key)" ]
  [ -z "$(ls -A "$t/elsewhere")" ]
}

@test "a key path that is a symlink is refused" {
  install -d -m 0700 "$(dirname "$(key)")"
  ln -s "$t/old" "$(key)"
  run --separate-stderr bash "$t/generate"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not a regular file"* ]]
  [ ! -e "$(pub public)" ]
}

@test "it runs under ndh's trampoline and logger, traced on request, and the trace never holds the private" {
  run --separate-stderr env NDH_LOGGER_XTRACE=1 bash "$t/generate"
  [ "$status" -eq 0 ]
  [[ $stderr == *"ndh::logger:command:run completed successfully"* ]]
  [[ $stderr == *"+ owned_dirs"* ]]
  [[ $stderr == *"+ born"* ]]
  [[ $stderr != *"PRIVATE KEY"* ]]
  [[ $stderr != *"$(sed -n 2p "$(key)")"* ]]
}

@test "no private is ever printed" {
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [[ $output$stderr != *"$(sed -n 2p "$(key)")"* ]]
}

@test "a console bootstrap publishes its public alone, reads no old key, and shows its fingerprint at the console" {
  render "" console
  rm -f "$t/old"
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [ "$(cat "$(pub public)")" = "$(ssh-keygen -y -f "$(key)" | cut -d' ' -f1,2)" ]
  [ ! -e "$(pub statement)" ]
  [ ! -e "$(pub statement.sig)" ]
  fp="$(ssh-keygen -lf "$(pub public)" | cut -d' ' -f2)"
  grep -qF "type it at keys-reconcile window: $fp" "$t/console"
  [[ $output$stderr != *"PRIVATE KEY"* ]]
}

@test "a console bootstrap's second run regenerates nothing and shows the same fingerprint" {
  render "" console
  bash "$t/generate"
  before="$(sha256sum "$(key)")"
  bash "$t/generate"
  [ "$(sha256sum "$(key)")" = "$before" ]
  [ "$(grep -c "type it at keys-reconcile window" "$t/console")" = 2 ]
  [ "$(sort -u <(grep -o 'SHA256:[^ ]*' "$t/console") | wc -l)" = 1 ]
}

@test "a console that cannot be written changes nothing" {
  render "" console
  mkdir "$t/console"
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [ -s "$(pub public)" ]
}

# The key root (publishDir's parent, /var/lib/ndh/host-key) is traversable, never listable: the seat collects a
# publication over ssh as the operator's user, while the privates below stay root's (🛡️, 2026-10-26).
@test "the key root is 0711: created so, and an existing 0700 one (a pre-K5 machine's) is brought to it" {
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [ "$(mode "$t/var/host-key")" = 711 ]
  rm -rf "$t/var/host-key"
  install -d -m 0700 "$t/var/host-key"
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [ "$(mode "$t/var/host-key")" = 711 ]
  [ "$(mode "$t/var/host-key/slots")" = 700 ]
}

@test "mutant: a key root left listable (0755) fails the case above" {
  sed -i '/^ *#/!s/0711/0755/g' "$t/generate"
  run grep -c '^[^#]*0711' "$t/generate"
  [ "$output" = 0 ]
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [ "$(mode "$t/var/host-key")" = 755 ]
}
