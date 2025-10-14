#!/usr/bin/env bash
# @codebase
# Append latest commit info to the active session notes file (YYYY-MM-DDb if exists else YYYY-MM-DD)
# Usage: ./auto-session-note.sh [optional-session-date]
# Detects session file, inserts entry after // SESSION_LOG marker if present.
set -euo pipefail

date_ref="${1:-$(date +%F)}"
session_dir="$(git rev-parse --show-toplevel)/docs/sessions"
file_primary="$session_dir/${date_ref}.adoc"
file_secondary="$session_dir/${date_ref}b.adoc"

if [[ -f "$file_secondary" ]]; then
  session_file="$file_secondary"
elif [[ -f "$file_primary" ]]; then
  session_file="$file_primary"
else
  echo "No session file for $date_ref found (expected $file_primary or $file_secondary)" >&2
  exit 1
fi

commit_line=$(git log -1 --pretty=format:'%h %ad %an %s' --date=iso)
commit_hash=${commit_line%% *}

# Prepare log entry
entry="* commit $commit_line"

# Only append if hash not already logged
if ! grep -q "$commit_hash" "$session_file"; then
  tmp=$(mktemp)
  awk -v entry="$entry" 'BEGIN{added=0} {print $0; if(!added && $0 ~ /\/\/ SESSION_LOG/){print entry; added=1}} END{if(!added) print entry}' "$session_file" > "$tmp"
  mv "$tmp" "$session_file"
  echo "Session notes updated with commit $commit_hash"
else
  echo "Commit $commit_hash already present in session log"
fi
