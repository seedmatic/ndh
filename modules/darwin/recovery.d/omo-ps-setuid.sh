#!/bin/sh
# omo-ps-setuid.sh — Fix /bin/ps setuid issue on macOS (Recovery OS)
#
# Problem: /bin/ps is setuid root (mode 4755) and SIP-protected.
# omo's hardened runtime cannot posix_spawn it → EPERM.
# Solution: remove setuid bit (chmod 0755) or replace with adv_cmds ps.
#
# Usage (in Recovery OS, Terminal):
#   sh /etc/recovery.d/omo-ps-setuid.sh              # chmod mode (default)
#   MODE=replace sh /etc/recovery.d/omo-ps-setuid.sh  # replace with adv_cmds ps
#
# The script handles SIP + authenticated-root disabling automatically.
# If it disables either, it will ask you to reboot and re-run.
#
# IMPORTANT: authenticated-root must stay DISABLED for changes to persist.
# Re-enabling it re-seals the volume and reverts all modifications.
#
# Xtrace is ALWAYS enabled → /tmp/omo-ps-setuid.xtrace

set -u

SYSTEM_VOLUME="${SYSTEM_VOLUME:-/Volumes/Macintosh HD}"
MODE="${MODE:-chmod}"
MOUNTED_BY_US=""

XTRACE_FILE="/tmp/omo-ps-setuid.xtrace"
if [ -n "${XTRACE_FILE_OVERRIDE:-}" ]; then
  XTRACE_FILE="$XTRACE_FILE_OVERRIDE"
fi

echo "=== omo-ps-setuid fix ==="
echo "Xtrace → $XTRACE_FILE"

set -exuo pipefail
exec 2>"$XTRACE_FILE"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*" >&2; }

cleanup() {
  set +e
  rc=$?
  if [ -n "${MOUNTED_BY_US:-}" ]; then
    info "Remounting system volume read-only..."
    mount -ur "$SYSTEM_VOLUME" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT

# === Step 1: Ensure SIP is disabled ===
info "Checking SIP status..."
SIP_STATUS="$(csrutil status 2>&1 || true)"
info "SIP: $SIP_STATUS"
NEED_REBOOT=0
if ! echo "$SIP_STATUS" | grep -qi "disabled"; then
  info "SIP is enabled — disabling now..."
  csrutil disable 2>&1 || die "Failed to disable SIP."
  info "SIP disabled OK (takes effect after reboot)"
  NEED_REBOOT=1
else
  info "SIP is already disabled"
fi

# === Step 2: Ensure authenticated-root is disabled ===
info "Checking authenticated-root status..."
AUTH_STATUS="$(csrutil authenticated-root status 2>&1 || true)"
info "Authenticated-root: $AUTH_STATUS"
if ! echo "$AUTH_STATUS" | grep -qi "disabled"; then
  info "Authenticated-root is enabled — disabling now..."
  csrutil authenticated-root disable 2>&1 || die "Failed to disable authenticated-root."
  info "Authenticated-root disabled OK (takes effect after reboot)"
  NEED_REBOOT=1
else
  info "Authenticated-root is already disabled"
fi

if [ "$NEED_REBOOT" -eq 1 ]; then
  echo ""
  echo "=== REBOOT REQUIRED ==="
  echo "SIP and/or authenticated-root were just disabled."
  echo "Reboot into Recovery (restart + Cmd+R) and re-run this script."
  echo ""
  info "Done (reboot required)."
  exit 0
fi

# === Step 3: Pre-flight boot volume ===
info "Boot volume BEFORE:"
bless --info --getBoot 2>&1 || true

# === Step 4: Mount system volume read-write ===
info "Mounting: $SYSTEM_VOLUME"
mount -uw "$SYSTEM_VOLUME" 2>&1 || die "Failed to mount '$SYSTEM_VOLUME' read-write."
MOUNTED_BY_US=1
if ! touch "$SYSTEM_VOLUME/.omo-write-test" 2>/dev/null; then
  die "System volume not writable after mount -uw."
fi
rm -f "$SYSTEM_VOLUME/.omo-write-test"
info "Write test passed"

# === Step 5: Script dir ===
_SCRIPT_PATH="$0"
case "$_SCRIPT_PATH" in
  /*) ;;
  *) _SCRIPT_PATH="$(pwd)/$_SCRIPT_PATH" ;;
esac
_SCRIPT_DIR="$(dirname "$_SCRIPT_PATH")"
_SCRIPT_BASE="$(basename "$_SCRIPT_PATH" .sh)"

# === Step 6: Backup ---
BACKUP_DIR="$SYSTEM_VOLUME/bin/ps-backup-$(date +%Y%m%d-%H%M%S)"
ORIGINAL_PS="$SYSTEM_VOLUME/bin/ps"
mkdir -p "$BACKUP_DIR" || die "Cannot create backup dir"
cp -p "$ORIGINAL_PS" "$BACKUP_DIR/ps" || die "Cannot backup /bin/ps"
stat -f '%Lp %u %g' "$ORIGINAL_PS" > "$BACKUP_DIR/metadata.txt" 2>/dev/null || true
info "Backup: $BACKUP_DIR/ps"

# === Step 7: Apply fix (if needed) ---
ALREADY_FIXED=0
if [ ! -u "$ORIGINAL_PS" ]; then
  info "/bin/ps is already non-setuid (mode $(stat -f '%Lp' "$ORIGINAL_PS" 2>/dev/null || echo '?'))"
  ALREADY_FIXED=1
else
  info "/bin/ps is setuid (mode $(stat -f '%Lp' "$ORIGINAL_PS" 2>/dev/null || echo '?'))"

  case "$MODE" in
    chmod)
      info "Removing setuid bit: chmod 0755 /bin/ps"
      chmod 0755 "$ORIGINAL_PS" || die "chmod failed"
      info "chmod OK"
      ;;
    replace)
      find_nix_ps() {
        candidates=$(find /nix/store -path '*/bin/ps' -perm /111 2>/dev/null) || true
        for p in $candidates; do
          if [ -x "$p" ] && [ ! -u "$p" ]; then
            if file "$p" 2>/dev/null | grep -qi "mach-o"; then
              echo "$p"; return 0
            fi
          fi
        done
        for p in /usr/bin/ps /opt/homebrew/bin/ps; do
          if [ -x "$p" ] && [ ! -u "$p" ]; then
            echo "$p"; return 0
          fi
        done
        return 1
      }
      info "Replacing /bin/ps with adv_cmds version..."
      NIX_PS="$(find_nix_ps)" || die "Cannot find a non-setuid Mach-O 'ps' binary."
      info "Found: $NIX_PS"
      TMP_PS="$SYSTEM_VOLUME/bin/.ps.new.$$"
      cp "$NIX_PS" "$TMP_PS" || die "Cannot copy replacement"
      chmod 0755 "$TMP_PS" || die "Cannot chmod replacement"
      chown root:wheel "$TMP_PS" 2>/dev/null || chown 0:0 "$TMP_PS" 2>/dev/null || true
      mv "$TMP_PS" "$ORIGINAL_PS" || die "Cannot replace /bin/ps"
      info "Replacement OK"
      ;;
    *)
      die "Unknown MODE='$MODE'. Use 'chmod' or 'replace'."
      ;;
  esac
fi

# === Step 8: Verify ---
NEW_MODE="$(stat -f '%Lp' "$ORIGINAL_PS" 2>/dev/null || echo 'unknown')"
info "New mode: $NEW_MODE"
if [ "$NEW_MODE" = "4755" ]; then
  die "Mode is still 4755 — fix did not apply!"
fi
if "$ORIGINAL_PS" -o pid= >/dev/null 2>&1; then
  info "Verification: /bin/ps executes OK"
else
  warn "/bin/ps did not execute cleanly"
fi

# === Step 9: Create snapshot + bless (CRITICAL for persistence) ===
info "Creating APFS snapshot + blessing..."
SNAPSHOT_OK=0

info "Method 1: bless --folder --bootefi --create-snapshot"
if bless --folder "$SYSTEM_VOLUME/System/Library/CoreServices" --bootefi --create-snapshot 2>&1; then
  info "OK (method 1)"; SNAPSHOT_OK=1
else
  warn "Method 1 failed"
  info "Method 2: bless --mount --create-snapshot + --setBoot"
  if bless --mount "$SYSTEM_VOLUME" --create-snapshot 2>&1; then
    info "Snapshot created (method 2)"
    if bless --mount "$SYSTEM_VOLUME" --setBoot 2>&1; then
      info "Boot set OK (method 2)"; SNAPSHOT_OK=1
    else
      warn "setBoot failed (method 2)"
    fi
  else
    warn "Method 2 also failed"
  fi
fi

if [ "$SNAPSHOT_OK" -ne 1 ]; then
  die "No snapshot created — cannot persist changes without snapshot."
fi

info "Boot volume AFTER:"
bless --info --getBoot 2>&1 || true

# === Step 10: Copy xtrace ---
cp "$XTRACE_FILE" "$_SCRIPT_DIR/${_SCRIPT_BASE}.xtrace" 2>/dev/null || true

# === Summary ===
echo ""
echo "=== SUMMARY ==="
echo "Already fixed:    $ALREADY_FIXED"
echo "Mode applied:     $MODE"
echo "New /bin/ps mode: $NEW_MODE"
echo "Backup location:  $BACKUP_DIR"
echo "Snapshot created: yes"
echo "Xtrace file:     $XTRACE_FILE"
echo ""
echo "Next steps:"
echo "  1. Re-enable SIP ONLY: csrutil enable"
echo "     !! DO NOT re-enable authenticated-root !!"
echo "     (re-enabling it re-seals the volume and reverts all changes)"
echo "  2. Reboot normally"
echo "  3. Verify: ls -l /bin/ps  (should show 0755, no 's')"
echo "  4. Test omo memory reflection"
echo ""
echo "Security note:"
echo "  authenticated-root stays DISABLED. This means the system"
echo "  volume is not verified at boot. This is required for any"
echo "  modification to /bin/ps to persist."
echo ""
echo "To revert (in Recovery):"
echo "  cp '$BACKUP_DIR/ps' '$ORIGINAL_PS'"
echo "  bless --folder '$SYSTEM_VOLUME/System/Library/CoreServices' --bootefi --create-snapshot"
echo "  csrutil enable"
echo "  csrutil authenticated-root enable"
echo ""

info "Done."
exit 0