source @nixBashTrampoline@

# Empty the Flox VS Code extension's activation snapshots. The extension keeps, per workspace, the WHOLE process
# environment of its last activation (`flox.previousActivatedEnv` in the `flox.flox` item of the workspace's
# state.vscdb), in clear, and copies it back into the extension host at every start. Measured 2026-10-21 on bioskop:
# 49 of 53 snapshots held CLAUDE_CODE_USE_BEDROCK and AWS_* from the Bedrock days, which every `claude` the Claude
# extension spawned inherited, and 43 held a GH_TOKEN. The extension is disabled (the operator, 2026-10-21), so a
# snapshot has no use left: it is emptied whole, and the rest of the item (its preferences) is kept.
#
# VS Code holds open the database of each workspace it has open, and writes it back at exit: such a database is
# skipped, said in the log, and purged at the next activation. The others (measured: all but one, with VS Code
# running) are purged now. A database whose snapshot is already empty is never written.
main() {
  set -euo pipefail
  local root db value purged n=0 held=0
  for root in "$HOME/Library/Application Support/"*/User/workspaceStorage; do
    [ -d "$root" ] || continue
    for db in "$root"/*/state.vscdb; do
      [ -f "$db" ] || continue
      value="$(sqlite3 -readonly "$db" "select value from ItemTable where key = 'flox.flox'" 2>/dev/null || true)"
      [ -n "$value" ] || continue
      purged="$(printf '%s' "$value" | jq -c \
        'if (."flox.previousActivatedEnv" // {} | length) > 0 then ."flox.previousActivatedEnv" = {} else empty end' \
        2>/dev/null || true)"
      [ -n "$purged" ] || continue
      if lsof -t -- "$db" >/dev/null 2>&1; then
        held=$((held + 1))
        echo "purge-flox-snapshot: $db is open in VS Code; purged at the next activation" >&2
        continue
      fi
      python3 -I -c '
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update ItemTable set value = ? where key = ?", (sys.argv[2], "flox.flox"))
c.commit()
' "$db" "$purged"
      n=$((n + 1))
    done
  done
  if [ "$n" -gt 0 ] || [ "$held" -gt 0 ]; then
    echo "purge-flox-snapshot: $n snapshot(s) emptied, $held left for the next activation" >&2
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
