{ lib, pkgs, ... }:
# Remove any UseKeychain directive from ~/.ssh/config (@codebase)
# Always run using GNU sed from Nix store; no pre-checks required. Idempotent.
# Pattern: a line consisting solely of optional leading whitespace, 'UseKeychain'
# one or more spaces, 'yes', optional trailing whitespace or inline comment.
{
  home.activation.removeUseKeychain = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    CFG="$HOME/.ssh/config"
    BACKUP="$CFG.nix-backup"
    [ -f "$CFG" ] || exit 0
    # Make file writable, remove old backup if exists
    chmod u+w "$CFG" 2>/dev/null || true
    [ -f "$BACKUP" ] && rm -f "$BACKUP"
    # Single extended regex: allow optional trailing spaces and optional inline comment
    "${pkgs.gnused}/bin/sed" -E -i.nix-backup '/^[[:space:]]*UseKeychain[[:space:]]+yes([[:space:]]+#[^!]*)?$/d' "$CFG" || true
    # Restore read-only and clean up backup if no changes were made
    chmod u-w "$CFG" 2>/dev/null || true
    if [ -f "$BACKUP" ] && cmp -s "$CFG" "$BACKUP"; then
      rm -f "$BACKUP"
    fi
  '';
}
