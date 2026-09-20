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

  # Incus daemon may not be started yet during activation (e.g. first boot).
  # Skip the trust bootstrap here — the socket-activated incus.service will
  # start on first use; re-running switch-to-configuration or the dedicated
  # systemd service will complete auth once the daemon is up.
  if [[ ! -S /var/lib/incus/unix.socket ]]; then
    echo "incus socket not available yet; skipping trust bootstrap (will retry at runtime)" >&2
    return 0
  fi

  # --quiet outputs only the raw token (no TTY masking / ┅ characters)
  token="$(@incusBin@ --force-local config trust add "${auto_user}-bootstrap-$(date +%s)" --quiet)"
  if [[ -z "${token}" ]]; then
    echo "failed to obtain Incus trust token for remote bootstrap" >&2
    return 1
  fi

  # Checked, not swallowed: if the removal fails the `remote add` below fails too
  # ("already exists"), and a `|| true` here would hide the cause.  errexit does
  # not help — the logger invokes main from an `if` condition, which makes it
  # inert for the whole body (shell.d/logger.sh:326).  The config.yml written
  # above keeps `default-remote: local`, so unlike the Darwin operator script
  # this one is never removing the default remote.
  if runuser -u "${auto_user}" -- env HOME="${auto_home}" XDG_CONFIG_HOME="${auto_home}/.config" \
    @incusBin@ remote list --format json 2>/dev/null \
    | remote="${remote_name}" yq -p json -e 'has(strenv(remote))' >/dev/null 2>&1; then
    if ! runuser -u "${auto_user}" -- env HOME="${auto_home}" XDG_CONFIG_HOME="${auto_home}/.config" \
      @incusBin@ remote remove "${remote_name}"; then
      echo "failed to drop the stale ${remote_name} remote before re-adding it" >&2
      return 1
    fi
  fi

  runuser -u "${auto_user}" -- env HOME="${auto_home}" XDG_CONFIG_HOME="${auto_home}/.config" \
    @incusBin@ remote add "${remote_name}" "${token}"
}

ndh::logger:command:run "@loggerTag@" main "$@"
