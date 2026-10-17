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

  # The switch commands record their argv instead of running; their shebang is this bash, since the nix sandbox
  # has no /usr/bin/env. The guest answers readlink with its generation, which a switch moves on; a `down` file
  # makes it unreachable, and `break` makes the next switch take it down.
  echo 1 >"$T/gen"
  cat >"$T/bin/ssh" <<STUB
#!$BASH
printf '%s\n' "ssh \$*" >>"$T/calls"
case "\$*" in
  *readlink*) [ -e "$T/down" ] && exit 255; echo "/nix/store/gen-\$(cat "$T/gen")-system" ;;
  *configuration-revision*) [ -e "$T/down" ] && exit 255; [ -e "$T/norev" ] || printf '%040d\n' "\$(cat "$T/gen")" ;;
esac
STUB
  cat >"$T/bin/nixos-rebuild" <<STUB
#!$BASH
printf '%s\n' "nixos-rebuild \$*" >>"$T/calls"
echo \$((\$(cat "$T/gen") + 1)) >"$T/gen"
[ -e "$T/break" ] && touch "$T/down"
exit \${STUB_EXIT:-0}
STUB
  chmod +x "$T/bin/ssh" "$T/bin/nixos-rebuild"
  export PATH="$T/bin:$PATH"

  host=$(uname -n)
  # The package fixes the remote to GitHub; here it is the fake one, set the same way.
  { printf 'machines=%q\nseat=%q\nremote=%q\nprobe_every=1\nprobe_until=2\n' "$MACHINES" "${host%%.*}" "$T/github.git"
    cat "$D/ndh-switch.sh"; } >"$T/ndh-switch"
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
  [ "$status" -eq 3 ]
  [[ "$output" == *"not merged into develop or main"* ]]
  [ ! -e "$T/calls" ]
  grep -q "refused: $UNMERGED is not merged" "$T/state/ndh-switch/log"
}
@test "refused: an abbreviated revision" {
  run sw nikopol-nixos "${MERGED:0:8}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a full revision"* ]]
}
@test "refused: a ref name instead of a revision" {
  run sw nikopol-nixos develop
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a full revision"* ]]
}
@test "refused: an unknown machine" {
  run sw rke2lab-node-1 "$MERGED"
  [ "$status" -eq 3 ]
  [[ "$output" == *"unknown machine: rke2lab-node-1"* ]]
}
@test "refused: run from another seat" {
  sed -i.bak 's/^seat=.*/seat=elsewhere/' "$T/ndh-switch"
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 3 ]
  [[ "$output" == *"runs from darwin.elsewhere only"* ]]
}
@test "refused: the remote cannot be fetched" {
  sed -i.bak "s|^remote=.*|remote=$T/nowhere.git|" "$T/ndh-switch"
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot fetch develop and main"* ]]
}
@test "a failed switch is logged with its exit status, and returned" {
  STUB_EXIT=7 run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 7 ]
  grep -q "nikopol-nixos $MERGED failed: exit 7" "$T/state/ndh-switch/log"
}
@test "watch: the generation left is printed and logged before the switch" {
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"previous: /nix/store/gen-1-system (revision 0000000000000000000000000000000000000001)"* ]]
  grep -q "started (develop), previous: /nix/store/gen-1-system (revision 0000000000000000000000000000000000000001)" "$T/state/ndh-switch/log"
}
@test "watch: a machine that answers after the switch is reported reachable, on its new generation" {
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reachable: /nix/store/gen-2-system"* ]]
}
@test "watch: a machine lost after the switch ends UNREACHABLE: recover now, exit 6, with the way back" {
  touch "$T/break"
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 6 ]
  [[ "$output" == *"UNREACHABLE: recover now (previous: /nix/store/gen-1-system)"* ]]
  [[ "$output" == *"recover: ndh-switch nikopol-nixos 0000000000000000000000000000000000000001"* ]]
  grep -q "UNREACHABLE after 2s: recover now (previous: /nix/store/gen-1-system; ndh-switch nikopol-nixos 0000000000000000000000000000000000000001)" "$T/state/ndh-switch/log"
}
@test "watch: with no readable revision, the recovery says so instead of guessing" {
  touch "$T/norev" "$T/break"
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 6 ]
  [[ "$output" == *"previous: /nix/store/gen-1-system (revision unknown)"* ]]
  [[ "$output" == *"recover: revision unknown: by generation only"* ]]
}
@test "watch: a darwin host's revision is read with its darwin-version" {
  run sw nikopol "$MERGED"
  grep -q "darwin.nikopol /run/current-system/sw/bin/darwin-version --configuration-revision" "$T/calls"
}
@test "watch: a remote darwin host is probed over ssh with its own options" {
  run sw nikopol "$MERGED"
  [ "$status" -eq 0 ]
  grep -q "^ssh -o BatchMode=yes -o ConnectTimeout=10 -o HostName=nikopol.mammoth-skate.ts.net darwin.nikopol readlink -f /run/current-system" "$T/calls"
}
@test "watch: a machine unreachable BEFORE the switch is not switched (no way back known)" {
  touch "$T/down"
  run sw nikopol-nixos "$MERGED"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot read the running generation of nikopol-nixos"* ]]
  ! grep -q '^nixos-rebuild' "$T/calls"
}
@test "the remote is not taken from the environment" {
  NDH_SWITCH_REMOTE="$T/nowhere.git" run sw --dry-run nikopol-nixos "$MERGED"
  [ "$status" -eq 0 ]
  ! grep -q NDH_SWITCH_REMOTE "$D/ndh-switch.sh"
}
@test "usage: wrong argument count lists the machines" {
  run sw nikopol-nixos
  [ "$status" -eq 2 ] && [[ "$output" == *"bioskop-nixos bioskop nikopol-nixos nikopol"* ]]
}
