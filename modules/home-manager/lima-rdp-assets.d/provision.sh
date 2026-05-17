#!/usr/bin/env -S bash -euo pipefail

source @nixBashTrampoline@

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

  # TODO: this lima-instance ssh.config still uses the legacy
  # `nikopol-vz.lan` hostname which doesn't resolve any more (the
  # bare metal is on a corp network the bbox can't reach).  The
  # alias name is updated to `vz`/`vz.nikopol` here for naming
  # consistency, but the HostName needs migrating to the resolver-
  # ProxyCommand shape used by hosts/nikopol/modules/darwin/
  # vz-host-resolver.nix.  Lima provisioning runs in a context
  # without the trampoline, so the migration is non-trivial; leaving
  # the broken alias name updated for now.
  cat >"${lima_instance_dir}/ssh.config" <<'EOF'
Host vz vz.nikopol
  HostName nikopol-vz.lan
  User stephane.lacoin
  IdentityFile ~/.lima/_config/user
  IdentitiesOnly yes
  ForwardAgent yes
EOF

  chmod 0600 "${lima_instance_dir}/ssh.config"

  # In HM-only flows (without a full darwin postActivation pass), best-effort
  # materialize managed Lima configs when the helper is available.
  if command -v nerd-lima-vm-materialize >/dev/null 2>&1; then
    nerd-lima-vm-materialize || {
      echo "[lima-rdp-assets][WARN] nerd-lima-vm-materialize failed; keep existing ~/.lima state" >&2
    }
  else
    echo "[lima-rdp-assets][INFO] nerd-lima-vm-materialize not found in PATH; skipping full lima config materialization" >&2
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
