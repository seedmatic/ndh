source @logger@

main() {
  set -euo pipefail
  CFG="$HOME/.ssh/config"
  BACKUP="$CFG.nix-backup"
  [ -f "$CFG" ] || exit 0
  chmod u+w "$CFG" 2>/dev/null || true
  [ -f "$BACKUP" ] && rm -f "$BACKUP"
  "@sed@" -E -i.nix-backup '/^[[:space:]]*UseKeychain[[:space:]]+yes([[:space:]]+#[^!]*)?$/d' "$CFG" || true
  chmod u-w "$CFG" 2>/dev/null || true
  if [ -f "$BACKUP" ] && cmp -s "$CFG" "$BACKUP"; then
    rm -f "$BACKUP"
  fi
}

ndh::logger:command:run "@activationTag@" main "$@"
