# ndh-canary-proven record: prove the in-guest secret-material canary at this checkout's revision, and only then record
# its derivation, so the record a bringup image is gated on (modules/nixos/secret-material-guard.d/canary-proven) is the
# output of a run, never a claim (🛡️, 2026-10-25). Run from the root of an ndh checkout, on a seat with a linux builder.
#
# It builds the revision of the checkout's HEAD, by `git+file://…?rev=` (never the working tree, which may hold
# decrypted files), and writes into that same checkout, so it refuses a checkout whose tree is not exactly that
# revision: one with changes (staged, unstaged or untracked), and one whose HEAD moves while the build runs. The
# derivation recorded is the one of the revision built, read before the build. Written only when the build succeeded
# AND its log carries the guard's REFUSED line for the planted key: an image ships only on a guard that refused.
#
# Usage: ndh-canary-proven record     prints the commit-message line to use; commits nothing
set -euo pipefail

record_rel=modules/nixos/secret-material-guard.d/canary-proven
attr=onDemandChecks.bringup-in-guest-secret-guard
refused_line='secret-material-guard: REFUSED /mnt/zfs-root/root/.secret-canary/id '

die() {
  echo "ndh-canary-proven: refused: $*" >&2
  exit 2
}

[ "${1:-}" = record ] && [ $# -eq 1 ] || {
  echo "usage: ndh-canary-proven record" >&2
  exit 2
}

top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout"
[ -f "$top/$record_rel" ] || die "$top is not an ndh checkout (no $record_rel)"
cd "$top"
[ -z "$(git status --porcelain --untracked-files=all)" ] ||
  die "the checkout has changes: the record would claim a proof for a tree that is not the revision built; commit or drop them first"
rev=$(git rev-parse --verify "HEAD^{commit}") || die "the checkout has no HEAD commit"
flake="git+file://$top?rev=$rev"

drv=$(nix eval --raw "$flake#$attr.drvPath") || die "cannot evaluate $attr at ${rev:0:12}"
[[ $drv == /nix/store/*-bringup-in-guest-secret-guard.drv ]] || die "unexpected derivation: $drv"
if [ "$(tr -d '[:space:]' <"$record_rel")" = "$drv" ]; then
  echo "ndh-canary-proven: already recorded: $drv (revision ${rev:0:12}); nothing to do"
  exit 0
fi

log=$(mktemp)
trap 'rm -f "$log"' EXIT
echo "ndh-canary-proven: proving $attr at ${rev:0:12} (a full VM install, ~13 min)…" >&2
rc=0
nix build --no-link -L "$flake#$attr" >"$log" 2>&1 || rc=$?
((rc == 0)) || { tail -n 20 "$log" >&2; die "the canary's build failed (exit $rc): nothing recorded"; }
line=$(grep -m1 -F -- "$refused_line" "$log") ||
  die "the build succeeded but its log carries no « ${refused_line% } »: nothing recorded"

[ "$(git rev-parse HEAD)" = "$rev" ] || die "HEAD moved during the build (was ${rev:0:12}): nothing recorded"
[ -z "$(git status --porcelain --untracked-files=all)" ] || die "the checkout changed during the build: nothing recorded"

printf '%s\n' "$drv" >"$record_rel"
cat <<EOF
ndh-canary-proven: recorded $drv
  commit it with a line like:
    canary proven at ${rev:0:12}: $drv
    ${line#*> }
EOF
