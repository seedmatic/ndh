#!/usr/bin/env bash
# Shared activation logging wrapper (@codebase)
# Platform layers (darwin/nixos) must provide LOGGER_CMD="<logger> ... %TAG%".
set -euo pipefail

_activation_logger_cmd() {
  # Expects LOGGER_CMD from caller with %TAG% placeholder; otherwise no logger.
  local tag="$1"
  if [ -n "${LOGGER_CMD:-}" ]; then
    local rendered
    rendered=${LOGGER_CMD//%TAG%/$tag}
    echo "$rendered"
    return
  fi

  echo ""
}

_tag_lines() {
  # _tag_lines <tag> [cmd...]
  local tag="$1"
  shift

  if [ "$#" -eq 0 ]; then
    while IFS= read -r line; do
      printf '[%s] %s\n' "$tag" "$line"
    done
  else
    while IFS= read -r line; do
      printf '[%s] %s\n' "$tag" "$line"
    done | "$@"
  fi
}

activation_run() {
  if [ "$#" -lt 2 ]; then
    echo "[activation_run] usage: activation_run <tag> <command> [args...]" >&2
    exit 1
  fi

  local tag="$1"
  shift

  local logger_cmd
  logger_cmd=$(_activation_logger_cmd "$tag")

  case "$logger_cmd" in
    "")
      exec > >(_tag_lines "$tag" >&2) \
           2> >(_tag_lines "$tag" >&2)
      ;;
    *)
      exec > >(_tag_lines "$tag" $logger_cmd) \
           2> >(_tag_lines "$tag" $logger_cmd)
      ;;
  esac

  set -x
  "$@"
}
