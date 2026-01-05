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

  local caller_src
  caller_src=${BASH_SOURCE[1]:-$0}

  echo "[$1] activation_run starting command: ${*:2} (from ${caller_src})"

  local tag="$1"
  shift

  local logger_cmd_raw
  logger_cmd_raw=$(_activation_logger_cmd "$tag")

  # Split LOGGER_CMD into an array so args with spaces become distinct words.
  local -a logger_cmd=()
  if [ -n "$logger_cmd_raw" ]; then
    # shellcheck disable=SC2206
    logger_cmd=($logger_cmd_raw)
  fi

  case "${#logger_cmd[@]}" in
    0)
      exec > >(_tag_lines "$tag" >&2) \
           2> >(_tag_lines "$tag" >&2)
      ;;
    *)
      exec > >(_tag_lines "$tag" "${logger_cmd[@]}") \
           2> >(_tag_lines "$tag" "${logger_cmd[@]}")
      ;;
  esac

  set -x
  if "$@"; then
    echo "[$tag] activation_run completed successfully"
  else
    echo "[$tag] activation_run failed"
  fi
  set +x
}