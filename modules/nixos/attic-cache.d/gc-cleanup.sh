#!/usr/bin/env bash
# atticd's GC marks chunks as deleted (state D) but never removes their files from disk,
# and never cleans up orphaned NARs or zero-holder chunks. This script does that work.
# Runs periodically via the io-seedmatic-ndh-attic-gc-cleanup timer.
set -eu

state_dir="/var/lib/private/atticd"
db="${state_dir}/server.db"
storage="${state_dir}/storage"

if [ ! -f "$db" ]; then
  echo "attic-gc-cleanup: no database at $db" >&2
  exit 0
fi

sqlite3() { command sqlite3 "$@"; }

# 1. Mark V-state chunks with no holders as deleted (atticd's GC should do this, but doesn't).
sqlite3 "$db" "UPDATE chunk SET state='D' WHERE state='V' AND holders_count=0;"

# 2. Delete D-state chunk files from disk (hashed path: storage/X/XX/name.chunk).
sqlite3 "$db" "SELECT json_extract(remote_file, '$.Local.name') FROM chunk WHERE state='D';" | while IFS= read -r name; do
  [ -z "$name" ] && continue
  first="${name:0:1}"
  second="${name:0:2}"
  rm -f "${storage}/${first}/${second}/${name}"
done

# 3. Delete orphaned chunkrefs and D-state chunk records.
sqlite3 "$db" "DELETE FROM chunkref WHERE chunk_id IN (SELECT id FROM chunk WHERE state='D');"
sqlite3 "$db" "DELETE FROM chunk WHERE state='D';"

# 4. Delete NARs not referenced by any object.
sqlite3 "$db" "DELETE FROM nar WHERE id NOT IN (SELECT DISTINCT nar_id FROM object);"

# 5. Reclaim space.
sqlite3 "$db" "VACUUM;"

echo "attic-gc-cleanup: done"
