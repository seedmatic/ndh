#!/usr/bin/env bash
# Refuses secret material in what a bringup image is made of: a store layer's paths, or the files the
# install writes into the target root. The question is the canonical pre-commit's
# (secret_material_guard): a private-key header followed within two lines by a base64 body line, or
# an age secret key. Its literals are broken here so this file does not match itself.
#
# A match is refused unless its file's sha256 is in the allow-list — PUBLIC test and example keys that
# upstream packages ship (nixpkgs' NixOS tests, pycryptodomex's, Go's testdata…), each reviewed when
# added. What it prints is the PATH and that sha256, never a line of the file: the value is the
# secret.
#
# What it does NOT see, so that "the guard passed" is read as no more than it is: content inside
# compressed or archived files (.gz, .zip, .jar, .whl, a squashfs, a nested image), and a key whose
# body lines end in CRLF (the body rule anchors on a line end). It is a line scan of plain files.
# It never passes on a doubt: a subtree it cannot list, or a file it cannot read, refuses the image.
#
# guard.sh --paths-file FILE         every path listed in FILE, recursively
# guard.sh --root DIR [--prune P]…   DIR, recursively, minus each pruned subtree
set -euo pipefail

allow_list='@allowList@'
grep='@grep@' awk='@awk@' sha256sum='@sha256sum@' find='@find@' xargs='@xargs@' bash='@bash@'

declare -a roots=() prunes=()
case "${1:-}" in
  --paths-file) mapfile -t roots < "$2"; shift 2 ;;
  --root)
    roots=("$2"); shift 2
    while [ "${1:-}" = --prune ]; do prunes+=("$2"); shift 2; done ;;
  *) echo "secret-material-guard: --paths-file FILE | --root DIR [--prune P]..." >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo "secret-material-guard: unexpected argument '$1'" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every file to scan, listed first, so that a subtree find cannot read is a REFUSAL, not a gap.
declare -a prune_args=()
for p in "${prunes[@]}"; do prune_args+=(-path "$p" -prune -o); done
if ! "$find" "${roots[@]}" "${prune_args[@]}" -type f -print0 > "$work/files" 2> "$work/find.err"; then
  echo "secret-material-guard: REFUSED — part of what it must scan cannot be listed:" >&2
  sed 's/^/  /' "$work/find.err" >&2
  exit 1
fi

# The candidates: any file naming either marker anywhere; the exact rule below decides. grep's own
# "no match" (1) is not a failure, an unreadable file (2) is: each batch maps the first to success.
# shellcheck disable=SC2016  # expanded by the batch's bash, not here
if ! "$xargs" -0 -r "$bash" -c '"$0" -laE "PRIVATE[ ]KEY|AGE-SECRET[-]KEY-1" -- "$@"; s=$?; [ "$s" -le 1 ]' "$grep" \
  < "$work/files" > "$work/candidates" 2> "$work/grep.err"; then
  echo "secret-material-guard: REFUSED — a file it must scan cannot be read:" >&2
  sed 's/^/  /' "$work/grep.err" >&2
  exit 1
fi
candidates() { cat "$work/candidates"; }

refused=0
while IFS= read -r f; do
  if "$awk" '
      /BEGIN [A-Z]*[ ]?PRIVATE[ ]KEY/ { hdr = NR }
      hdr && NR > hdr && NR <= hdr + 2 && /^[A-Za-z0-9+\/=]{40,}$/ { found = 1; exit }
      /AGE-SECRET[-]KEY-1[A-Z0-9]{50,}/ { found = 1; exit }
      END { exit(found ? 0 : 1) }' "$f" 2>/dev/null; then
    sum=$("$sha256sum" "$f")
    sum=${sum%% *}
    if ! "$grep" -q "^$sum " "$allow_list"; then
      echo "secret-material-guard: REFUSED $f (sha256 $sum) holds private key material" >&2
      refused=1
    fi
  fi
done < <(candidates)

if [ "$refused" = 1 ]; then
  cat >&2 <<'EOF'
secret-material-guard: the image is NOT built. A file above holds a private key or an age secret
in the clear, and nothing that holds one may be packed into a disk image. If it is a PUBLIC test or
example key of an upstream package, add its sha256 and its path to the allow-list
(modules/nixos/secret-material-guard.d/public-test-keys.sha256), for 🛡️ to review.
EOF
  exit 1
fi
