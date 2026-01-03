#!/usr/bin/env bash
source @activationLogger@

main() {
  set -euxo pipefail

  # @user@ and @home@ substituted at build time
  auto_user="@user@"
  auto_home="@home@"

  autoconfig_dir="${auto_home}/.config/incus"

  install -d -m 0775 -o "${auto_user}" -g "${auto_user}" "${autoconfig_dir}"

  cat <<'EOF' | install -Dm 600 -o "${auto_user}" -g "${auto_user}" /dev/stdin "${autoconfig_dir}/config.yml"
default-remote: local
remotes:
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
}

activation_run "@activationTag@" main "$@"
