#!/usr/bin/env -S bash -euo pipefail
# Generate Incus user configuration file
# Activation scripts run under the systemd manager's minimal PATH.
# NDH_BOOTSTRAP_INSTALLER_MODE skips the bootstrap runtime presence check.
export NDH_BOOTSTRAP_INSTALLER_MODE=1
export NDH_BOOTSTRAP_STRICT=0
# shellcheck disable=SC1091
source @nixBashTrampoline@

main() {
  # @user@ and @home@ substituted at build time
  auto_user="@user@"
  auto_home="@home@"
  remote_name="@incusRemoteName@"
  remote_address="@incusRemoteAddress@"

  autoconfig_dir="${auto_home}/.config/incus"

  install -d -m 0775 -o "${auto_user}" -g "${auto_user}" "${autoconfig_dir}"

  cat <<'EOF' | install -Dm 600 -o "${auto_user}" -g "${auto_user}" /dev/stdin "${autoconfig_dir}/config.yml"
default-remote: local
remotes:
  @incusRemoteName@:
    addr: @incusRemoteAddress@
    protocol: incus
    public: false
  docker:
    addr: https://docker.io
    protocol: oci
    public: true
  images:
    addr: https://images.linuxcontainers.org
    protocol: simplestreams
    public: true
  ctreg:
    addr: https://ctreg.@tailnetDomain@
    protocol: oci
    public: true
aliases: {}
EOF

  # Ensure the configured remote is actually authenticated for this user.
  # This is idempotent and only performs bootstrap when remote auth is missing.
  if runuser -u "${auto_user}" -- env HOME="${auto_home}" XDG_CONFIG_HOME="${auto_home}/.config" \
    @incusBin@ info "${remote_name}:" >/dev/null 2>&1; then
    return 0
  fi

  token="$(@incusBin@ --force-local config trust add "${auto_user}-bootstrap-$(date +%s)" | sed -n '2p')"
  if [[ -z "${token}" ]]; then
    echo "failed to obtain Incus trust token for remote bootstrap" >&2
    return 1
  fi

  runuser -u "${auto_user}" -- env HOME="${auto_home}" XDG_CONFIG_HOME="${auto_home}/.config" \
    @incusBin@ remote remove "${remote_name}" >/dev/null 2>&1 || true

  runuser -u "${auto_user}" -- env HOME="${auto_home}" XDG_CONFIG_HOME="${auto_home}/.config" \
    @incusBin@ remote add "${remote_name}" "${token}"
}

ndh::logger:command:run "@loggerTag@" main "$@"
