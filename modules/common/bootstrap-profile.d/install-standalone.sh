#!/usr/bin/env bash
set -euo pipefail

main() {
  local profile_dir="${1:-@defaultProfileDir@}"
  local runtime_pkg="@runtimePackage@"
  local required="@requiredCommands@"
  local cmd
  local -a missing=()

  install -d -m 0755 "$(dirname "$profile_dir")"

  nix profile add --profile "$profile_dir" "$runtime_pkg"

  export PATH="${profile_dir}/bin:${PATH}"

  for cmd in $required; do
    [[ -n "$cmd" ]] || continue
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    echo "[ndh-bootstrap-profile][WARN] missing commands after install: ${missing[*]}" >&2
    return 1
  fi

  echo "[ndh-bootstrap-profile] installed runtime profile at ${profile_dir}"
}

main "$@"
