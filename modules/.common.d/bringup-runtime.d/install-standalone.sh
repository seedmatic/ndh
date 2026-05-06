#!/usr/bin/env bash
set -euo pipefail

# Installer bootstrap mode: profile may not exist yet.
export NDH_BOOTSTRAP_INSTALLER_MODE=1

# shellcheck disable=SC1091
source "@nixBashTrampoline@"

main() {
  local profile_dir="${1:-@defaultProfileDir@}"
  local profile_bin="${profile_dir}/bin"
  local nix_bin="@nix@"
  local nix_cli_args_raw="${NDH_NIX_CLI_ARGS:--L -v -v}"
  local -a nix_cli_args=()
  local runtime_pkg="@runtimePackage@"
  local runtime_name="nerd-bringup-runtime"
  local required="@requiredCommands@"
  local cmd
  local -a missing=()
  local -a missing_profile_bin=()

  install_profile_from_runtime_path() {
    if [[ -d "${runtime_pkg}/bin" ]]; then
      ln -sfn "${runtime_pkg}" "${profile_dir}"
      return 0
    fi

    return 1
  }

  install -d -m 0755 "$(dirname "$profile_dir")"

  if [[ -n "${nix_cli_args_raw}" ]]; then
    read -r -a nix_cli_args <<< "${nix_cli_args_raw}"
  fi

  if ! "$nix_bin" "${nix_cli_args[@]}" profile add --profile "$profile_dir" "$runtime_pkg"; then
    if ! install_profile_from_runtime_path; then
      "$nix_bin" "${nix_cli_args[@]}" profile remove --profile "$profile_dir" "$runtime_name" >/dev/null 2>&1 || true
      if ! "$nix_bin" "${nix_cli_args[@]}" profile add --profile "$profile_dir" "$runtime_pkg"; then
        install_profile_from_runtime_path
      fi
    fi
  fi

  export PATH="${profile_dir}/bin:${PATH}"

  if [[ ! -d "$profile_bin" ]]; then
    echo "[nerd-bringup-runtime][WARN] missing profile bin directory after install: ${profile_bin}" >&2
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
    echo "[nerd-bringup-runtime][WARN] profile bin is missing commands after install: ${missing_profile_bin[*]}" >&2
    return 1
  fi

  if ((${#missing[@]} > 0)); then
    echo "[nerd-bringup-runtime][WARN] missing commands after install: ${missing[*]}" >&2
    return 1
  fi

  echo "[nerd-bringup-runtime] installed runtime profile at ${profile_dir}"
}

ndh::logger:command:run "@loggerTag@" main "$@"
