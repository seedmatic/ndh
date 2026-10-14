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
# guard.sh --paths-file FILE         every path listed in FILE, recursively
# guard.sh --root DIR [--prune P]…   DIR, recursively, minus each pruned subtree
set -euo pipefail

allow_list='@allowList@'
grep='@grep@' awk='@awk@' sha256sum='@sha256sum@' find='@find@'

declare -a roots=() prunes=()
case "${1:-}" in
  --paths-file) mapfile -t roots < "$2"; shift 2 ;;
  --root)
    roots=("$2"); shift 2
    while [ "${1:-}" = --prune ]; do prunes+=("$2"); shift 2; done ;;
  *) echo "secret-material-guard: --paths-file FILE | --root DIR [--prune P]..." >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo "secret-material-guard: unexpected argument '$1'" >&2; exit 2; }

# The candidates: any file naming either marker anywhere. The exact rule below decides.
candidates() {
  local -a prune_args=()
  local p
  for p in "${prunes[@]}"; do prune_args+=(-path "$p" -prune -o); done
  "$find" "${roots[@]}" "${prune_args[@]}" -type f \
    -exec "$grep" -laE 'PRIVATE[ ]KEY|AGE-SECRET[-]KEY-1' -- {} + 2>/dev/null || true
}

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
