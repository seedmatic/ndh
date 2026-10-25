#!/usr/bin/env bats
# ndh-canary-proven record on its real script, in a throwaway git checkout, against recording stubs for nix and nix-store:
# the record is written only by a green build whose canary install's log carries the REFUSED line, for the revision of a
# clean HEAD that did not move, and no copy of that log lands on disk. Nothing here builds the canary nor evaluates a
# flake.

setup() {
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  export TMPDIR="$T/tmp"
  mkdir -p "$HOME" "$T/bin" "$TMPDIR"
  git config --global user.name tester
  git config --global user.email tester@example.invalid
  git init -q "$T/co"
  mkdir -p "$T/co/modules/nixos/secret-material-guard.d"
  printf '\n' >"$T/co/modules/nixos/secret-material-guard.d/canary-proven"
  git -C "$T/co" add -A
  git -C "$T/co" commit -q -m base
  REC="$T/co/modules/nixos/secret-material-guard.d/canary-proven"
  DRV=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bringup-in-guest-secret-guard.drv
  INSTALL=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nerd-bringup-zfs-disk-images-raw-secret-canary.drv
  # nix: `eval` prints $DRV; `build` runs $T/during (a hook to move HEAD or touch the tree while the build "runs") and
  # exits $T/build.rc, printing nothing of the install; `log <drv>` prints $T/install.log (the REFUSED line by
  # default) for $INSTALL only. nix-store: --references of $DRV names $INSTALL (or $T/refs).
  cat >"$T/bin/nix" <<STUB
#!$BASH
printf '%s\n' "nix \$*" >>"$T/calls"
case \$1 in
  eval) echo "$DRV" ;;
  build)
    [ -x "$T/during" ] && "$T/during"
    exit \$(cat "$T/build.rc" 2>/dev/null || echo 0) ;;
  log)
    [ "\$2" = "$INSTALL" ] || exit 1
    cat "$T/install.log" 2>/dev/null ||
      echo "original builder: secret-material-guard: REFUSED /mnt/zfs-root/root/.secret-canary/id (sha256 0123)" ;;
esac
STUB
  cat >"$T/bin/nix-store" <<STUB
#!$BASH
printf '%s\n' "nix-store \$*" >>"$T/calls"
[ "\$1 \$2 \$3" = "--query --references $DRV" ] || exit 1
cat "$T/refs" 2>/dev/null || printf '%s\n' /nix/store/cccc-bash.drv "$INSTALL" /nix/store/dddd-stdenv.drv
STUB
  chmod +x "$T/bin/nix" "$T/bin/nix-store"
  run_record() { (cd "$T/co" && PATH="$T/bin:$PATH" bash "$BATS_TEST_DIRNAME/../record.sh" "$@"); }
  calls_has() { grep -qxF -- "$1" "$T/calls"; } # one exact line of $T/calls
}

@test "a green build whose canary install's log carries the REFUSED line records the revision's derivation, built by ?rev=" {
  run run_record record
  [ "$status" -eq 0 ]
  [ "$(cat "$REC")" = "$DRV" ]
  rev=$(git -C "$T/co" rev-parse HEAD)
  calls_has "nix eval --raw git+file://$T/co?rev=$rev#onDemandChecks.bringup-in-guest-secret-guard.drvPath"
  calls_has "nix build --no-link git+file://$T/co?rev=$rev#onDemandChecks.bringup-in-guest-secret-guard"
  calls_has "nix log $INSTALL"
  [[ $output == *"canary proven at ${rev:0:12}: $DRV"* ]]
  [[ $output == *"secret-material-guard: REFUSED /mnt/zfs-root/root/.secret-canary/id"* ]]
}

@test "no copy of the build's log lands on disk: no -L, no temporary file" {
  run run_record record
  [ "$status" -eq 0 ]
  run ! grep -qE '^nix build .*(-L|--print-build-logs)' "$T/calls"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "a failed build records nothing, and names the install's log" {
  echo 1 >"$T/build.rc"
  run run_record record
  [ "$status" -eq 2 ]
  [[ $output == *"the canary's build failed (exit 1): nothing recorded; its log: nix log $INSTALL"* ]]
  [ "$(cat "$REC")" = "" ]
}

@test "a green build without the REFUSED line in the canary install's log records nothing" {
  echo "built, refused nothing" >"$T/install.log"
  run run_record record
  [ "$status" -eq 2 ]
  [[ $output == *"the canary's install log carries no"* ]]
  [ "$(cat "$REC")" = "" ]
}

@test "a canary whose install is not, or not uniquely, among its inputs is refused before anything is built" {
  for refs in none two; do
    case $refs in
      none) printf '%s\n' /nix/store/cccc-bash.drv >"$T/refs" ;;
      two) printf '%s\n' "$INSTALL" /nix/store/eeee-other-secret-canary.drv >"$T/refs" ;;
    esac
    rm -f "$T/calls"
    run run_record record
    [ "$status" -eq 2 ]
    [[ $output == *"canary's install"* || $output == *"canary install among"* ]]
    run ! grep -q '^nix build' "$T/calls"
    [ "$(cat "$REC")" = "" ]
  done
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
  run ! grep -q '^nix build' "$T/calls"
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
