#!/usr/bin/env bash
# Shared activation logging wrapper (@codebase)
set -euo pipefail

activation_run() {
  if [ "$#" -lt 2 ]; then
    echo "[activation_run] usage: activation_run <tag> <command> [args...]" >&2
    exit 1
  fi
  local tag="$1"
  shift
  exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$tag" "$line"; done | /usr/bin/logger -p notice -t "$tag") \
       2> >(while IFS= read -r line; do printf '[%s] %s\n' "$tag" "$line"; done | /usr/bin/logger -p notice -t "$tag")
  set -x
  "$@"
}
