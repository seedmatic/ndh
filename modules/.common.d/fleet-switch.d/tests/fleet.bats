#!/usr/bin/env bats
# fleet-switch on its real script, against a fake GitHub (a local bare whose develop carries the signers' fixes) and
# recording stubs for ndh-switch and nix. Nothing here switches a machine, evaluates a flake or runs a signer.

setup() {
  D="$BATS_TEST_DIRNAME/.."
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" XDG_CACHE_HOME="$T/cache"
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME" "$T/bin"
  git config --global user.name tester
  git config --global user.email tester@example.invalid
  git config --global init.defaultBranch develop

  git init -q "$T/work"
  git -C "$T/work" commit -q --allow-empty -m old
  OLD=$(git -C "$T/work" rev-parse HEAD)
  git -C "$T/work" commit -q --allow-empty -m "incus no-decrypt"
  FIX_INCUS=$(git -C "$T/work" rev-parse HEAD)
  git -C "$T/work" commit -q --allow-empty -m head
  MERGED=$(git -C "$T/work" rev-parse HEAD)
  git clone -q --bare "$T/work" "$T/github.git"
  PREV=$(printf '%040d' 1)

  i=$FIX_INCUS yq '(.[] | select(.name == "incus-cluster-cert-renew") | .noDecryptFix) = strenv(i)' "$D/signers.yaml" >"$T/signers.yaml"

  # ndh-switch: records its argv; $T/behave.<machine> scripts it (ok, fail N, unreachable, noreach, refused).
  cat >"$T/bin/ndh-switch" <<STUB
#!$BASH
printf '%s\n' "ndh-switch \$*" >>"$T/calls"
if [ "\$1" = --dry-run ]; then echo "+ switch \$2"; exit 0; fi
b=\$(cat "$T/behave.\$1" 2>/dev/null || echo ok)
case \$b in
  refused) echo "ndh-switch: refused: no" >&2; exit 3 ;;
esac
echo "previous: /nix/store/gen-1-system (revision $PREV)"
case \$b in
  ok) echo "reachable: /nix/store/gen-2-system" ;;
  fail*) exit \${b#fail } ;;
  unreachable) echo "UNREACHABLE: recover now" >&2; exit 6 ;;
  noreach) ;;
esac
exit 0
STUB
  # nix: `eval --json <flake>#darwinConfigurations.<m>.config.ndh.<option>.atActivation` answers
  # $T/signer.<m>.<option> (false when absent); `run <flake>#<signer> -- --check` exits $T/check.<signer>.
  cat >"$T/bin/nix" <<STUB
#!$BASH
printf '%s\n' "nix \$*" >>"$T/calls"
case \$1 in
  eval)
    [ -e "$T/evalfail" ] && exit 1
    a=\${3#*#darwinConfigurations.}; m=\${a%%.config.*}; o=\${a#*.config.ndh.}; o=\${o%.atActivation}
    cat "$T/signer.\$m.\$o" 2>/dev/null || echo false ;;
  run)
    n=\${2#*#}
    exit \$(cat "$T/check.\$n" 2>/dev/null || echo 0) ;;
esac
STUB
  chmod +x "$T/bin/ndh-switch" "$T/bin/nix"
  export PATH="$T/bin:$PATH"

  { printf 'ndh_switch=%q\nmachines=%q\nsigners=%q\nremote=%q\nflake_base=%q\n' \
      "$T/bin/ndh-switch" "$MACHINES" "$T/signers.yaml" "$T/github.git" github:seedmatic/ndh
    cat "$D/fleet-switch.sh"; } >"$T/fleet-switch"
}

fs() { bash "$T/fleet-switch" "$@"; }
# A negative assertion passes only on a NO (exit 1): grep's 2 on a missing file is no answer.
refute() {
  local rc=0
  "$@" || rc=$?
  case $rc in
    1) return 0 ;;
    0) echo "refuted, but it held: $*" >&2; return 1 ;;
    *) echo "refute got no answer (rc=$rc): $*" >&2; return 1 ;;
  esac
}
switched() { grep '^ndh-switch ' "$T/calls" | grep -v -- --dry-run | awk '{print $2}' | tr '\n' ' '; }

@test "the order comes from the machine list: NixOS guests, the remote darwin host; the seat skipped without --with-seat" {
  run fs --rev "$MERGED"
  [ "$status" -eq 0 ]
  [ "$(switched)" = "bioskop-nixos nikopol-nixos nikopol " ]
  [[ "$output" == *"bioskop: skipped (not named in the go)"* ]]
  [[ "$output" == *"nikopol-nixos: switched /nix/store/gen-1-system -> /nix/store/gen-2-system (rev ${MERGED:0:12})"* ]]
}
@test "with --with-seat the seat runs LAST, after its signer said nothing is due" {
  echo true >"$T/signer.bioskop.incusClusterCert"
  run fs --with-seat --rev "$MERGED"
  [ "$status" -eq 0 ]
  [ "$(switched)" = "bioskop-nixos nikopol-nixos nikopol bioskop " ]
  grep -qx "nix run github:seedmatic/ndh/$MERGED#incus-cluster-cert-renew -- --check" "$T/calls"
  [ "$(grep -n 'incus-cluster-cert-renew -- --check' "$T/calls" | cut -d: -f1)" -lt "$(grep -n '^ndh-switch bioskop ' "$T/calls" | cut -d: -f1)" ]
}
@test "the revision defaults to develop's head on the remote" {
  run fs --only nikopol-nixos
  [ "$status" -eq 0 ]
  grep -qx "ndh-switch nikopol-nixos $MERGED" "$T/calls"
}
@test "--only runs the named machines in the fleet's order, and skips the rest" {
  run fs --only nikopol,bioskop-nixos --rev "$MERGED"
  [ "$status" -eq 0 ]
  [ "$(switched)" = "bioskop-nixos nikopol " ]
  [[ "$output" == *"nikopol-nixos: skipped (not in --only)"* ]]
}
@test "refused before anything runs: an unknown machine in --only" {
  run fs --only rke2lab-node-1 --rev "$MERGED"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown machine: rke2lab-node-1"* ]]
  [ ! -e "$T/calls" ]
}
@test "refused before anything runs: an abbreviated revision" {
  run fs --rev "${MERGED:0:8}"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a full revision"* ]]
  [ ! -e "$T/calls" ]
}
@test "the first failure stops the loop, with the copy-exact recovery, and the rest is not run" {
  echo "fail 7" >"$T/behave.nikopol-nixos"
  run fs --rev "$MERGED"
  [ "$status" -eq 7 ]
  [[ "$output" == *"nikopol-nixos: FAILED (exit 7); recover: ndh-switch nikopol-nixos $PREV"* ]]
  [[ "$output" == *"nikopol: not run (stopped at nikopol-nixos)"* ]]
  [ "$(switched)" = "bioskop-nixos nikopol-nixos " ]
}
@test "an UNREACHABLE machine stops the loop with ndh-switch's status 6" {
  echo unreachable >"$T/behave.bioskop-nixos"
  run fs --rev "$MERGED"
  [ "$status" -eq 6 ]
  [[ "$output" == *"bioskop-nixos: FAILED (exit 6); recover: ndh-switch bioskop-nixos $PREV"* ]]
  [ "$(switched)" = "bioskop-nixos " ]
}
@test "a switch that exits 0 but never reports reachable is a failure" {
  echo noreach >"$T/behave.bioskop-nixos"
  run fs --rev "$MERGED"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bioskop-nixos: FAILED (exit 1)"* ]]
  [ "$(switched)" = "bioskop-nixos " ]
}
@test "a machine ndh-switch refused has nothing to recover" {
  echo refused >"$T/behave.bioskop-nixos"
  run fs --rev "$MERGED"
  [ "$status" -eq 3 ]
  [[ "$output" == *"bioskop-nixos: FAILED (exit 3); recover: nothing to recover: ndh-switch stopped before switching"* ]]
}
@test "a signature due on the seat stops BEFORE its switch: the operator's gesture" {
  echo true >"$T/signer.bioskop.incusClusterCert"
  echo 10 >"$T/check.incus-cluster-cert-renew"
  run fs --with-seat --rev "$MERGED"
  [ "$status" -eq 4 ]
  [[ "$output" == *"bioskop: STOPPED: a signature is due (incus-cluster-cert-renew), the operator's gesture"* ]]
  [ "$(switched)" = "bioskop-nixos nikopol-nixos nikopol " ]
}
@test "a signer --check that cannot classify stops the seat too (fail closed)" {
  echo true >"$T/signer.bioskop.incusClusterCert"
  echo 2 >"$T/check.incus-cluster-cert-renew"
  run fs --with-seat --only bioskop --rev "$MERGED"
  [ "$status" -eq 4 ]
  [[ "$output" == *"bioskop: STOPPED: incus-cluster-cert-renew --check could not classify (exit 2): not activating"* ]]
  refute grep -q '^ndh-switch bioskop ' "$T/calls"
}
@test "a target revision older than a signer's no-decrypt fix never runs that signer" {
  echo true >"$T/signer.bioskop.incusClusterCert"
  run fs --with-seat --only bioskop --rev "$OLD"
  [ "$status" -eq 4 ]
  [[ "$output" == *"bioskop: STOPPED: target rev predates incus-cluster-cert-renew's no-decrypt fix; the operator's gesture"* ]]
  refute grep -q '^nix run' "$T/calls"
  refute grep -q '^ndh-switch bioskop ' "$T/calls"
}
@test "no signer enabled: the seat switches without running any" {
  run fs --with-seat --only bioskop --rev "$MERGED"
  [ "$status" -eq 0 ]
  refute grep -q '^nix run' "$T/calls"
  [[ "$output" == *"bioskop: switched"* ]]
}
@test "the seat's signers cannot be evaluated: it is not switched" {
  touch "$T/evalfail"
  run fs --with-seat --only bioskop --rev "$MERGED"
  [ "$status" -eq 4 ]
  [[ "$output" == *"bioskop: STOPPED: cannot evaluate bioskop's activation signers"* ]]
  refute grep -q '^ndh-switch bioskop ' "$T/calls"
}
@test "a remote darwin host whose activation would sign is refused" {
  echo true >"$T/signer.nikopol.incusClusterCert"
  run fs --rev "$MERGED"
  [ "$status" -eq 4 ]
  [[ "$output" == *"nikopol: STOPPED: a remote darwin host whose activation signs (incus-cluster-cert-renew)"* ]]
  [ "$(switched)" = "bioskop-nixos nikopol-nixos " ]
}
@test "--dry-run switches nothing: ndh-switch --dry-run per machine, and the seat guard still runs" {
  echo true >"$T/signer.bioskop.incusClusterCert"
  run fs --dry-run --with-seat --rev "$MERGED"
  [ "$status" -eq 0 ]
  [ -z "$(switched)" ]
  [ "$(grep -c '^ndh-switch --dry-run ' "$T/calls")" -eq 4 ]
  grep -qx "nix run github:seedmatic/ndh/$MERGED#incus-cluster-cert-renew -- --check" "$T/calls"
  [[ "$output" == *"bioskop: would switch (dry-run)"* ]]
  [[ "$output" == *"(dry-run)"* ]]
}
