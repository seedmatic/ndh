#!/usr/bin/env bash
set -euo pipefail

main() {
  local profile_dir="${1:-@defaultProfileDir@}"
  local profile_bin="${profile_dir}/bin"
  local runtime_pkg="@runtimePackage@"
  local runtime_name="io.nxmatic.nix-darwin-home-bringup-runtime-profile-holder"
  local required="@requiredCommands@"
  local cmd
  local -a missing=()
  local -a missing_profile_bin=()

  install -d -m 0755 "$(dirname "$profile_dir")"

  if ! nix profile add --profile "$profile_dir" "$runtime_pkg"; then
    nix profile remove --profile "$profile_dir" "$runtime_name" >/dev/null 2>&1 || true
    nix profile add --profile "$profile_dir" "$runtime_pkg"
  fi

  export PATH="${profile_dir}/bin:${PATH}"

  if [[ ! -d "$profile_bin" ]]; then
    echo "[io-nxmatic-nix-darwin-home-bootstrap-profile][WARN] missing profile bin directory after install: ${profile_bin}" >&2
    return 1
  fi

  for cmd in $required; do
    [[ -n "$cmd" ]] || continue
    if [[ ! -e "${profile_bin}/${cmd}" && ! -L "${profile_bin}/${cmd}" ]]; then
      missing_profile_bin+=("$cmd")
    fi
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing_profile_bin[@]} > 0)); then
    echo "[io-nxmatic-nix-darwin-home-bootstrap-profile][WARN] profile bin is missing commands after install: ${missing_profile_bin[*]}" >&2
    return 1
  fi

  if ((${#missing[@]} > 0)); then
    echo "[io-nxmatic-nix-darwin-home-bootstrap-profile][WARN] missing commands after install: ${missing[*]}" >&2
    return 1
  fi

  echo "[io-nxmatic-nix-darwin-home-bootstrap-profile] installed runtime profile at ${profile_dir}"
}

main "$@"
