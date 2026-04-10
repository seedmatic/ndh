#!/usr/bin/env -S bash -euo pipefail

source @bashTrampoline@
source @logger@

main() {
  local home_dir="@homeDir@"
  local lima_dir="${home_dir}/.lima"
  local lima_config_dir="${lima_dir}/_config"
  local lima_instance_dir="${lima_dir}/nerd-nixos"
  local host_priv="@privateKey@"
  local host_pub="@publicKey@"

  mkdir -p "${lima_config_dir}" "${lima_instance_dir}"

  ln -sfn "${host_priv}" "${lima_config_dir}/user"
  ln -sfn "${host_pub}" "${lima_config_dir}/user.pub"

  cat >"${lima_instance_dir}/ssh.config" <<'EOF'
Host vz-host vz-host.nikopol
  HostName nikopol-vz.lan
  User stephane.lacoin
  IdentityFile ~/.lima/_config/user
  IdentitiesOnly yes
  ForwardAgent yes
EOF

  chmod 0600 "${lima_instance_dir}/ssh.config"

  # In HM-only flows (without a full darwin postActivation pass), best-effort
  # materialize managed Lima configs when the helper is available.
  if command -v lima-config-materialize >/dev/null 2>&1; then
    lima-config-materialize || {
      echo "[lima-rdp-assets][WARN] lima-config-materialize failed; keep existing ~/.lima state" >&2
    }
  else
    echo "[lima-rdp-assets][INFO] lima-config-materialize not found in PATH; skipping full lima config materialization" >&2
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
