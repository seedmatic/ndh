#!/usr/bin/env bash
set -euo pipefail

main() {
  local profile_dir="${1:-@defaultProfileDir@}"
  local runtime_pkg="@runtimePackage@"
  local runtime_name="io.nxmatic.nix-darwin-home-bootstrap-runtime-activation"
  local required="@requiredCommands@"
  local cmd
  local -a missing=()

  install -d -m 0755 "$(dirname "$profile_dir")"

  if ! nix profile add --profile "$profile_dir" "$runtime_pkg"; then
    nix profile remove --profile "$profile_dir" "$runtime_name" >/dev/null 2>&1 || true
    nix profile add --profile "$profile_dir" "$runtime_pkg"
  fi

  export PATH="${profile_dir}/bin:${PATH}"

  for cmd in $required; do
    [[ -n "$cmd" ]] || continue
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    echo "[io-nxmatic-nix-darwin-home-bootstrap-profile][WARN] missing commands after install: ${missing[*]}" >&2
    return 1
  fi

  echo "[io-nxmatic-nix-darwin-home-bootstrap-profile] installed runtime profile at ${profile_dir}"
}

main "$@"
