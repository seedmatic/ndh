{ lib, pkgs, ... }:
# Remove any UseKeychain directive from ~/.ssh/config (@codebase)
# Always run using GNU sed from Nix store; no pre-checks required. Idempotent.
# Pattern: a line consisting solely of optional leading whitespace, 'UseKeychain'
# one or more spaces, 'yes', optional trailing whitespace or inline comment.
{
  home.activation.removeUseKeychain = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    CFG="$HOME/.ssh/config"
    [ -f "$CFG" ] || exit 0
    # Single extended regex: allow optional trailing spaces and optional inline comment
    "${pkgs.gnused}/bin/sed" -E -i '/^[[:space:]]*UseKeychain[[:space:]]+yes([[:space:]]+#[^!]*)?$/d' "$CFG" || true
  '';
}
