#!/usr/bin/env bash
set -eu

chunks_dir="/var/lib/attic-chunks"
db_dir="/var/lib/attic-db"
db="${db_dir}/server.db"
storage="${chunks_dir}"

if [ ! -f "$db" ]; then
  echo "attic-gc-cleanup: no database at $db" >&2
  exit 0
fi

sqlite3() { command sqlite3 "$@"; }

sqlite3 "$db" "UPDATE chunk SET state='D' WHERE state='V' AND holders_count=0;"

sqlite3 "$db" "SELECT json_extract(remote_file, '$.Local.name') FROM chunk WHERE state='D';" | while IFS= read -r name; do
  [ -z "$name" ] && continue
  first="${name:0:1}"
  second="${name:0:2}"
  rm -f "${storage}/${first}/${second}/${name}"
done

sqlite3 "$db" "DELETE FROM chunkref WHERE chunk_id IN (SELECT id FROM chunk WHERE state='D');"
sqlite3 "$db" "DELETE FROM chunk WHERE state='D';"

sqlite3 "$db" "DELETE FROM nar WHERE id NOT IN (SELECT DISTINCT nar_id FROM object);"

sqlite3 "$db" "VACUUM;"

echo "attic-gc-cleanup: done"