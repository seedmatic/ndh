#!/usr/bin/env bash
# Shared activation logging wrapper (@codebase)
# Platform layers (darwin/nixos) must provide LOGGER_CMD="<logger> ... %TAG%".

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

_prepare_activation_log_file() {
  # Optional local log sink. If ACTIVATION_LOG_SESSION_ID is provided, truncate
  # the local log only when the session id changes (i.e., once per activation).
  local log_file="${ACTIVATION_LOG_FILE:-}"
  if [ -z "$log_file" ]; then
    return
  fi

  mkdir -p "$(dirname "$log_file")"

  local session_id="${ACTIVATION_LOG_SESSION_ID:-}"
  if [ -n "$session_id" ]; then
    local session_file
    session_file="${ACTIVATION_LOG_SESSION_FILE:-${log_file}.session}"

    local previous=""
    if [ -r "$session_file" ]; then
      previous="$(cat "$session_file" 2>/dev/null || true)"
    fi

    if [ "$previous" != "$session_id" ]; then
      : >"$log_file"
      printf '%s\n' "$session_id" >"$session_file"
    fi
  fi
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

  # Keep a handle to original stderr so we can always emit critical notices to
  # the invoking console, even after output redirection to logger/file sinks.
  exec 3>&2

  local logger_cmd_raw
  logger_cmd_raw=$(_activation_logger_cmd "$tag")

  _prepare_activation_log_file
  local activation_log_file="${ACTIVATION_LOG_FILE:-}"

  # Split LOGGER_CMD into an array so args with spaces become distinct words.
  local -a logger_cmd=()
  if [ -n "$logger_cmd_raw" ]; then
    # shellcheck disable=SC2206
    logger_cmd=($logger_cmd_raw)
  fi

  case "${#logger_cmd[@]}" in
    0)
      if [ -n "$activation_log_file" ]; then
        exec > >(_tag_lines "$tag" | tee -a "$activation_log_file" >&2) \
             2> >(_tag_lines "$tag" | tee -a "$activation_log_file" >&2)
      else
        exec > >(_tag_lines "$tag" >&2) \
             2> >(_tag_lines "$tag" >&2)
      fi
      ;;
    *)
      if [ -n "$activation_log_file" ]; then
        exec > >(_tag_lines "$tag" | tee -a "$activation_log_file" | "${logger_cmd[@]}") \
             2> >(_tag_lines "$tag" | tee -a "$activation_log_file" | "${logger_cmd[@]}")
      else
        exec > >(_tag_lines "$tag" "${logger_cmd[@]}") \
             2> >(_tag_lines "$tag" "${logger_cmd[@]}")
      fi
      ;;
  esac

  set -x
  if "$@"; then
    echo "[$tag] activation_run completed successfully"
  else
    echo "[$tag] activation_run failed"
    if [ -n "$activation_log_file" ]; then
      printf '[%s] activation_run error details: %s\n' "$tag" "$activation_log_file" >&3
    fi
  fi
  set +x
}