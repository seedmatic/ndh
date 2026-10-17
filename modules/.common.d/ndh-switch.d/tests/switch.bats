#!/usr/bin/env bats
# ndh-switch against a fake GitHub (a local bare with develop and main) and recording stubs for the switch
# commands. Nothing here switches a machine.

setup() {
  D="$BATS_TEST_DIRNAME/.."
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_CACHE_HOME="$T/cache"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME" "$T/bin"
  git config --global user.name tester
  git config --global user.email tester@example.invalid
  git config --global init.defaultBranch develop

  git init -q "$T/work"
  git -C "$T/work" commit -q --allow-empty -m one
  MERGED=$(git -C "$T/work" rev-parse HEAD)
  git -C "$T/work" branch main
  git -C "$T/work" switch -q -c feature/x
  git -C "$T/work" commit -q --allow-empty -m two
  UNMERGED=$(git -C "$T/work" rev-parse HEAD)
  git clone -q --bare "$T/work" "$T/github.git"
  export NDH_SWITCH_REMOTE="$T/github.git"

  # The switch commands record their argv instead of running; their shebang is this bash, since the nix sandbox
  # has no /usr/bin/env.
  for c in nixos-rebuild ssh; do
    printf '#!%s\nprintf "%%s\\n" "%s $*" >>"%s/calls"\n' "$BASH" "$c" "$T" >"$T/bin/$c"
    chmod +x "$T/bin/$c"
  done
  export PATH="$T/bin:$PATH"

  host=$(uname -n)
  { printf 'machines=%q\nseat=%q\n' "$D/machines.json" "${host%%.*}"; cat "$D/ndh-switch.sh"; } >"$T/ndh-switch"
}

sw() { bash "$T/ndh-switch" "$@"; }

@test "a merged revision switches a NixOS guest by --target-host" {
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 0 ]
  grep -qx "nixos-rebuild switch --flake github:seedmatic/ndh/$MERGED#nikopol-nixos --target-host root@nixos.nikopol" "$T/calls"
  grep -q "nikopol-nixos $MERGED switched (develop)" "$T/state/ndh-switch/log"
}
@test "a remote darwin host is switched over ssh, with sudo and the daemon kickstart" {
  run sw nikopol "$MERGED"
  [ "$status" -eq 0 ]
  grep -q "^ssh -o HostName=nikopol.mammoth-skate.ts.net darwin.nikopol /usr/bin/sudo /run/current-system/sw/bin/darwin-rebuild switch --flake 'github:seedmatic/ndh/$MERGED#nikopol' && /usr/bin/sudo launchctl kickstart" "$T/calls"
}
@test "the local darwin host, dry-run: the command, nothing run" {
  run sw --dry-run bioskop "$MERGED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ bash -c /usr/bin/sudo /run/current-system/sw/bin/darwin-rebuild switch --flake 'github:seedmatic/ndh/$MERGED#bioskop'"* ]]
  [ ! -e "$T/calls" ]
  grep -q "bioskop $MERGED dry-run (develop)" "$T/state/ndh-switch/log"
}
@test "a revision merged into main only is accepted" {
  git -C "$T/work" switch -q main
  git -C "$T/work" commit -q --allow-empty -m hotfix
  hot=$(git -C "$T/work" rev-parse HEAD)
  git -C "$T/work" push -q "$T/github.git" main
  run sw --dry-run nikopol-nixos "$hot"
  [ "$status" -eq 0 ] && [[ "$output" == *"(on main)"* ]]
}
@test "refused: a pushed revision that is not merged into develop or main" {
  git -C "$T/work" push -q "$T/github.git" feature/x
  run sw nikopol-nixos "$UNMERGED"
  [ "$status" -eq 3 ] && [[ "$output" == *"not merged into develop or main"* ]]
  [ ! -e "$T/calls" ]
  grep -q "refused: $UNMERGED is not merged" "$T/state/ndh-switch/log"
}
@test "refused: an abbreviated revision" {
  run sw nikopol-nixos "${MERGED:0:8}"
  [ "$status" -eq 3 ] && [[ "$output" == *"not a full revision"* ]]
}
@test "refused: a ref name instead of a revision" {
  run sw nikopol-nixos develop
  [ "$status" -eq 3 ] && [[ "$output" == *"not a full revision"* ]]
}
@test "refused: an unknown machine" {
  run sw rke2lab-node-1 "$MERGED"
  [ "$status" -eq 3 ] && [[ "$output" == *"unknown machine: rke2lab-node-1"* ]]
}
@test "refused: run from another seat" {
  sed -i.bak 's/^seat=.*/seat=elsewhere/' "$T/ndh-switch"
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 3 ] && [[ "$output" == *"runs from darwin.elsewhere only"* ]]
}
@test "refused: the remote cannot be fetched" {
  export NDH_SWITCH_REMOTE="$T/nowhere.git"
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 3 ] && [[ "$output" == *"cannot fetch develop and main"* ]]
}
@test "a failed switch is logged with its exit status, and returned" {
  printf '#!%s\nexit 7\n' "$BASH" >"$T/bin/nixos-rebuild"
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 7 ]
  grep -q "nikopol-nixos $MERGED failed: exit 7" "$T/state/ndh-switch/log"
}
@test "usage: wrong argument count lists the machines" {
  run sw nikopol-nixos
  [ "$status" -eq 2 ] && [[ "$output" == *"bioskop-nixos bioskop nikopol-nixos nikopol"* ]]
}
