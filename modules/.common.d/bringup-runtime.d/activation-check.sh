set -euo pipefail

profile_bin="@profileBin@"
nix_bin="@nixBin@"
auto_install="@autoInstall@"
required_commands="@requiredCommands@"
install_hint="@installHint@"
runtime_package="@runtimePackage@"
bootstrap_installer="@bootstrapInstaller@"
profile_dir="@profileDir@"
image_build_context="${NIXOS_INSTALL_BOOTLOADER:-0}"

install_profile_from_runtime_path() {
  if [ -d "${runtime_package}/bin" ]; then
    mkdir -p "$(dirname "${profile_dir}")"
    ln -sfn "${runtime_package}" "${profile_dir}"
    return 0
  fi

  return 1
}

install_profile() {
  echo "[io-nxmatic-nix-darwin-home-bringup-runtime] installing/refreshing profile ${profile_dir}" >&2

  # In early image-build activation, prefer direct store-path seeding to avoid
  # relying on nix profile plumbing before the runtime is fully initialized.
  if [ "$image_build_context" = "1" ] && install_profile_from_runtime_path; then
    return 0
  fi

  if [ -x "$bootstrap_installer" ]; then
    "$bootstrap_installer" "$profile_dir" >&2 || install_profile_from_runtime_path
  else
    "$nix_bin" profile add --profile "${profile_dir}" "${runtime_package}" >&2 || install_profile_from_runtime_path
  fi
}

if [ "$image_build_context" = "1" ] && [ "$auto_install" = "1" ]; then
  echo "[io-nxmatic-nix-darwin-home-bringup-runtime] image-build activation context detected; seeding profile ${profile_dir}" >&2
  install_profile
fi

check_commands() {
  missing=""
  wrong_source=""
  for cmd in ${required_commands}; do
    if ! resolved="$(command -v "$cmd" 2>/dev/null)"; then
      missing="$missing $cmd"
      continue
    fi

    case "$resolved" in
      "$profile_bin"/*) ;;
      *)
        wrong_source="$wrong_source $cmd:$resolved"
        ;;
    esac
  done
}

if [ ! -d "$profile_bin" ]; then
  if [ "$auto_install" = "1" ]; then
    install_profile
  else
    echo "[io-nxmatic-nix-darwin-home-bringup-runtime][ERROR] required profile bin directory is missing: $profile_bin" >&2
    echo "[io-nxmatic-nix-darwin-home-bringup-runtime][ERROR] install it first: ${install_hint}" >&2
    exit 1
  fi
fi

export PATH="$profile_bin:$PATH"

check_commands

if { [ -n "$missing" ] || [ -n "$wrong_source" ]; } && [ "$auto_install" = "1" ]; then
  install_profile
  export PATH="$profile_bin:$PATH"
  check_commands
fi

if [ -n "$missing" ]; then
  echo "[io-nxmatic-nix-darwin-home-bringup-runtime][ERROR] missing required commands:$missing" >&2
  echo "[io-nxmatic-nix-darwin-home-bringup-runtime][ERROR] reinstall profile: ${install_hint}" >&2
  exit 1
fi

if [ -n "$wrong_source" ]; then
  echo "[io-nxmatic-nix-darwin-home-bringup-runtime][ERROR] required commands not sourced from profile:$wrong_source" >&2
  echo "[io-nxmatic-nix-darwin-home-bringup-runtime][ERROR] reinstall/repair profile: ${install_hint}" >&2
  exit 1
fi
