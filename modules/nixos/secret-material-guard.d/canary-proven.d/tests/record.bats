#!/usr/bin/env bats
# ndh-canary-proven record on its real script, in a throwaway git checkout, against a recording stub for nix: the record
# is written only by a green build whose log carries the REFUSED line, for the revision of a clean HEAD that did not move.
# Nothing here builds the canary nor evaluates a flake.

setup() {
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME" "$T/bin"
  git config --global user.name tester
  git config --global user.email tester@example.invalid
  git init -q "$T/co"
  mkdir -p "$T/co/modules/nixos/secret-material-guard.d"
  printf '\n' >"$T/co/modules/nixos/secret-material-guard.d/canary-proven"
  git -C "$T/co" add -A
  git -C "$T/co" commit -q -m base
  REC="$T/co/modules/nixos/secret-material-guard.d/canary-proven"
  DRV=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bringup-in-guest-secret-guard.drv
  # nix: `eval` prints $DRV; `build` writes $T/build.log's content (the REFUSED line by default), exits $T/build.rc,
  # and runs $T/during (a hook to move HEAD or touch the tree while the build "runs").
  cat >"$T/bin/nix" <<STUB
#!$BASH
printf '%s\n' "nix \$*" >>"$T/calls"
case \$1 in
  eval) echo "$DRV" ;;
  build)
    [ -x "$T/during" ] && "$T/during"
    cat "$T/build.log" 2>/dev/null ||
      echo "nerd-bringup-zfs-disk-images-raw-secret-canary> original builder: secret-material-guard: REFUSED /mnt/zfs-root/root/.secret-canary/id (sha256 0123)"
    exit \$(cat "$T/build.rc" 2>/dev/null || echo 0) ;;
esac
STUB
  chmod +x "$T/bin/nix"
  run_record() { (cd "$T/co" && PATH="$T/bin:$PATH" bash "$BATS_TEST_DIRNAME/../record.sh" "$@"); }
}

@test "a green build whose log carries the REFUSED line records the revision's derivation, built by ?rev=" {
  run run_record record
  [ "$status" -eq 0 ]
  [ "$(cat "$REC")" = "$DRV" ]
  rev=$(git -C "$T/co" rev-parse HEAD)
  grep -qF "nix eval --raw git+file://$T/co?rev=$rev#onDemandChecks.bringup-in-guest-secret-guard.drvPath" "$T/calls"
  grep -qF "nix build --no-link -L git+file://$T/co?rev=$rev#onDemandChecks.bringup-in-guest-secret-guard" "$T/calls"
  [[ $output == *"canary proven at ${rev:0:12}: $DRV"* ]]
  [[ $output == *"secret-material-guard: REFUSED /mnt/zfs-root/root/.secret-canary/id"* ]]
}

@test "a failed build records nothing" {
  echo 1 >"$T/build.rc"
  run run_record record
  [ "$status" -eq 2 ]
  [[ $output == *"the canary's build failed (exit 1): nothing recorded"* ]]
  [ "$(cat "$REC")" = "" ]
}

@test "a green build without the REFUSED line records nothing" {
  echo "built, refused nothing" >"$T/build.log"
  run run_record record
  [ "$status" -eq 2 ]
  [[ $output == *"its log carries no"* ]]
  [ "$(cat "$REC")" = "" ]
}

@test "a checkout with changes is refused before anything is built: staged, unstaged, untracked" {
  for change in staged unstaged untracked; do
    git -C "$T/co" reset -q --hard
    git -C "$T/co" clean -qfd
    case $change in
      staged) echo x >"$T/co/f" && git -C "$T/co" add f ;;
      unstaged) echo x >>"$REC" ;;
      untracked) echo x >"$T/co/new" ;;
    esac
    rm -f "$T/calls"
    run run_record record
    [ "$status" -eq 2 ]
    [[ $output == *"the checkout has changes"* ]]
    [ ! -e "$T/calls" ]
  done
}

@test "a HEAD that moves during the build records nothing" {
  cat >"$T/during" <<EOF
#!$BASH
git -C "$T/co" commit -q --allow-empty -m moved
EOF
  chmod +x "$T/during"
  run run_record record
  [ "$status" -eq 2 ]
  [[ $output == *"HEAD moved during the build"* ]]
  [ "$(cat "$REC")" = "" ]
}

@test "a tree that changes during the build records nothing" {
  cat >"$T/during" <<EOF
#!$BASH
echo x >"$T/co/late"
EOF
  chmod +x "$T/during"
  run run_record record
  [ "$status" -eq 2 ]
  [[ $output == *"the checkout changed during the build"* ]]
  [ "$(cat "$REC")" = "" ]
}

@test "an already-recorded derivation builds nothing" {
  printf '%s\n' "$DRV" >"$REC"
  git -C "$T/co" commit -q -am recorded
  run run_record record
  [ "$status" -eq 0 ]
  [[ $output == *"already recorded"* ]]
  ! grep -q '^nix build' "$T/calls"
}

@test "outside an ndh checkout, and with an argument other than record, it refuses" {
  run bash -c "cd '$T/home' && PATH='$T/bin:$PATH' bash '$BATS_TEST_DIRNAME/../record.sh' record"
  [ "$status" -eq 2 ]
  run run_record
  [ "$status" -eq 2 ]
  [[ $output == *"usage: ndh-canary-proven record"* ]]
  run run_record record extra
  [ "$status" -eq 2 ]
}
