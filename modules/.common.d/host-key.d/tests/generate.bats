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

render() { # <recorded old public>
  # Rendered as replaceVars does (each value shell-quoted, as ndh.hostKey.generateVars holds them), through the real
  # ndh trampoline and logger, and run whole: its last line is the dispatch the activation runs. NDH_TRAMPOLINE comes
  # from the flake check (the sandbox cannot search the store).
  : "${NDH_TRAMPOLINE:?the ndh bash trampoline}"
  local -A vars=(
    [nixBashTrampoline]="$NDH_TRAMPOLINE"
    [machine]=m [slot]=26-11-01 [base]="$t/var" [slotDir]="$t/var/slots" [owner]="$(id -u)"
    [keyFile]="$t/var/slots/26-11-01/ssh_host_ed25519_key" [publishDir]="$t/var/published"
    [oldKey]="$t/old" [oldPublic]="$1"
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
key() { echo "$t/var/slots/26-11-01/ssh_host_ed25519_key"; }
pub() { echo "$t/var/published/host-m@26-11-01.$1"; }

verify() { # the statement against the OLD key's public, as the seat will
  printf 'host-m %s\n' "$(cut -d' ' -f1,2 "$t/old.pub")" >"$t/allowed"
  ssh-keygen -q -Y verify -f "$t/allowed" -I host-m -n seedmatic-rotate -s "$(pub statement.sig)" <"$(pub statement)"
}

@test "the key is born 0600 in a 0700 directory, and its public and F1 statement are published" {
  run --separate-stderr bash "$t/generate"
  [ "$status" -eq 0 ]
  [ "$(mode "$t/var/slots")" = 700 ]
  [ "$(mode "$(dirname "$(key)")")" = 700 ]
  [ "$(mode "$t/var/published")" = 755 ]
  [ "$(mode "$(key)")" = 600 ]
  [ "$(cat "$(pub public)")" = "$(ssh-keygen -y -f "$(key)" | cut -d' ' -f1,2)" ]
  grep -qxF "key $(cat "$(pub public)")" "$(pub statement)"
  grep -qxF "slot 26-11-01" "$(pub statement)"
  verify
  [ -z "$(find "$t/var" -name '.generate.*' -o -name '.publish.*')" ]
}

@test "the statement does not verify under another namespace, nor against another key" {
  bash "$t/generate"
  printf 'host-m %s\n' "$(cut -d' ' -f1,2 "$t/old.pub")" >"$t/allowed"
  run ssh-keygen -q -Y verify -f "$t/allowed" -I host-m -n seedmatic-attest -s "$(pub statement.sig)" <"$(pub statement)"
  [ "$status" -ne 0 ]
  ssh-keygen -q -t ed25519 -N "" -C other -f "$t/other"
  printf 'host-m %s\n' "$(cut -d' ' -f1,2 "$t/other.pub")" >"$t/allowed"
  run ssh-keygen -q -Y verify -f "$t/allowed" -I host-m -n seedmatic-rotate -s "$(pub statement.sig)" <"$(pub statement)"
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
  rm -f "$t/var/published/"*
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
  mkdir -p "$t/elsewhere" "$t/var/slots"
  chmod 0700 "$t/var/slots"
  ln -s "$t/elsewhere" "$t/var/slots/26-11-01"
  run --separate-stderr bash "$t/generate"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not a directory (a symlink?)"* ]]
  [ -z "$(ls -A "$t/elsewhere")" ]
  [ ! -e "$t/var/published" ]
}

@test "a group- or world-writable directory on the way is refused" {
  mkdir -p "$t/var/slots"
  chmod 0777 "$t/var/slots"
  run --separate-stderr bash "$t/generate"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is group- or world-writable"* ]]
  [ ! -e "$(key)" ]
}

@test "a published directory that is a symlink is refused" {
  mkdir -p "$t/elsewhere"
  ln -s "$t/elsewhere" "$t/var/published"
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
