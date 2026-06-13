#!/usr/bin/env bash
# Regression suite for the generalized wip-guard. Runs the ACTUAL source hooks
# (not the deployed copies) against scratch git repos under a temp dir.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# --- detection unit checks (regex only) ---------------------------------
WIP_RE='(^|/)\.?wip/'
check_match() { # path, expect(yes|no), label
  if printf '%s\n' "$1" | grep -Eq "$WIP_RE"; then got=yes; else got=no; fi
  [ "$got" = "$2" ] && ok "detect: $3" || bad "detect: $3 (got $got want $2)"
}
echo "detection:"
check_match "wip/spec.md"                          yes "root wip"
check_match "docs/diagrams/.wip/c4-preview.adoc"   yes "nested .wip"
check_match "seed-master/wip/notes.md"             yes "nested wip"
check_match "swipe/x"                              no  "swipe is not wip"
check_match "wiping.md"                            no  "wiping file"
check_match "wip"                                  no  "bare file named wip"

# --- behavioural checks (real repos, real hooks) ------------------------
scratch() { # creates a repo, echoes its path
  local d; d="$(mktemp -d)"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf '%s' "$d"
}

echo "behaviour:"

# (A) on main, a staged nested .wip path is blocked by pre-commit
d="$(scratch)"
mkdir -p "$d/docs/x/.wip"; echo hi > "$d/docs/x/.wip/y.md"
git -C "$d" add -A
if ( cd "$d" && "$HOOKS_DIR/pre-commit" ) >/dev/null 2>&1; then
  bad "block: pre-commit should reject nested .wip on main"
else
  ok "block: pre-commit rejects nested .wip on main"
fi
rm -rf "$d"

# (A2) on develop, the same staged path is also blocked (develop is protected too)
d="$(scratch)"
git -C "$d" checkout -q -b develop
mkdir -p "$d/docs/x/.wip"; echo hi > "$d/docs/x/.wip/y.md"
git -C "$d" add -A
if ( cd "$d" && "$HOOKS_DIR/pre-commit" ) >/dev/null 2>&1; then
  bad "block: pre-commit should reject nested .wip on develop"
else
  ok "block: pre-commit rejects nested .wip on develop"
fi
rm -rf "$d"

# (B) on a feature branch, the same staged path is allowed
d="$(scratch)"
git -C "$d" checkout -q -b feature/x
mkdir -p "$d/docs/x/.wip"; echo hi > "$d/docs/x/.wip/y.md"
git -C "$d" add -A
if ( cd "$d" && "$HOOKS_DIR/pre-commit" ) >/dev/null 2>&1; then
  ok "allow: pre-commit allows .wip on a feature branch"
else
  bad "allow: pre-commit wrongly blocked .wip on a feature branch"
fi
rm -rf "$d"

# (C) chain: guard passes -> repo-local .git/hooks/pre-commit runs
d="$(scratch)"
git -C "$d" checkout -q -b feature/y
cat > "$d/.git/hooks/pre-commit" <<EOS
#!/usr/bin/env bash
touch "$d/SENTINEL"
EOS
chmod +x "$d/.git/hooks/pre-commit"
( cd "$d" && "$HOOKS_DIR/pre-commit" ) >/dev/null 2>&1
[ -f "$d/SENTINEL" ] && ok "chain: repo-local pre-commit ran after guard passed" \
                      || bad "chain: repo-local pre-commit did not run"
rm -rf "$d"

# (D) chain skipped: guard blocks on main -> repo-local hook must NOT run
d="$(scratch)"
cat > "$d/.git/hooks/pre-commit" <<EOS
#!/usr/bin/env bash
touch "$d/SENTINEL"
EOS
chmod +x "$d/.git/hooks/pre-commit"
mkdir -p "$d/.wip"; echo x > "$d/.wip/z"; git -C "$d" add -A
( cd "$d" && "$HOOKS_DIR/pre-commit" ) >/dev/null 2>&1
[ -f "$d/SENTINEL" ] && bad "chain: repo-local hook ran despite guard block" \
                     || ok "chain: repo-local hook correctly skipped on block"
rm -rf "$d"

# (E) pre-push: pushing main with a wip path in the tree is rejected
d="$(scratch)"
mkdir -p "$d/a/.wip"; echo x > "$d/a/.wip/f"; git -C "$d" add -A
git -C "$d" commit -q -m wip --no-verify
sha="$(git -C "$d" rev-parse HEAD)"
line="refs/heads/main $sha refs/heads/main 0000000000000000000000000000000000000000"
if ( cd "$d" && printf '%s\n' "$line" | "$HOOKS_DIR/pre-push" origin file://"$d" ) >/dev/null 2>&1; then
  bad "push: pre-push should reject main carrying a wip path"
else
  ok "push: pre-push rejects main carrying a wip path"
fi
rm -rf "$d"

# (E2) pre-push: pushing develop with a wip path in the tree is also rejected
d="$(scratch)"
mkdir -p "$d/a/.wip"; echo x > "$d/a/.wip/f"; git -C "$d" add -A
git -C "$d" commit -q -m wip --no-verify
sha="$(git -C "$d" rev-parse HEAD)"
line="refs/heads/develop $sha refs/heads/develop 0000000000000000000000000000000000000000"
if ( cd "$d" && printf '%s\n' "$line" | "$HOOKS_DIR/pre-push" origin file://"$d" ) >/dev/null 2>&1; then
  bad "push: pre-push should reject develop carrying a wip path"
else
  ok "push: pre-push rejects develop carrying a wip path"
fi
rm -rf "$d"

# (E3) pre-push: pushing a feature branch carrying a wip path is allowed
d="$(scratch)"
mkdir -p "$d/a/.wip"; echo x > "$d/a/.wip/f"; git -C "$d" add -A
git -C "$d" commit -q -m wip --no-verify
sha="$(git -C "$d" rev-parse HEAD)"
line="refs/heads/feature/x $sha refs/heads/feature/x 0000000000000000000000000000000000000000"
if ( cd "$d" && printf '%s\n' "$line" | "$HOOKS_DIR/pre-push" origin file://"$d" ) >/dev/null 2>&1; then
  ok "push: pre-push allows a feature branch carrying a wip path"
else
  bad "push: pre-push wrongly blocked a feature branch"
fi
rm -rf "$d"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
