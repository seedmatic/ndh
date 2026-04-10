#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  echo "[limaConfig] start $(date) host=@effectiveHostName@ user=@profileUser@"

  : "Create Lima configuration directory in profile home"
  mkdir -p "@profileHome@/.lima/nerd-nixos"
  mkdir -p "@profileHome@/.lima/_config"

  : "Install managed host-side Lima wrapper as symlink to store path"
  ln -sfn "@limaRunScript@" "@profileHome@/.lima/run.sh"
  rm -f "@profileHome@/.lima/run.sh~"

  host_pub="@hostPublicKeyPath@"
  host_priv="@hostPrivateKeyPath@"

  : "Symlink Lima user key material from host-managed keys.d"
  if [ -f "$host_pub" ]; then
    ln -sf "$host_pub" "@profileHome@/.lima/_config/user.pub"
    chmod 0644 "@profileHome@/.lima/_config/user.pub"
  else
    echo "[limaConfig][WARN] missing $host_pub; not linking @profileHome@/.lima/_config/user.pub"
  fi

  if [ -f "$host_priv" ]; then
    ln -sf "$host_priv" "@profileHome@/.lima/_config/user"
    chmod 0600 "@profileHome@/.lima/_config/user"
  else
    echo "[limaConfig][WARN] missing $host_priv; not linking @profileHome@/.lima/_config/user"
  fi

  if { [ ! -f "$host_pub" ] || [ ! -f "$host_priv" ]; } && [ -f "/run/secrets/nix-darwin-home/nxmatic-ssh-keys.yaml" ]; then
    per_user_keys_dir="$(dirname "$host_priv")"
    system_keys_dir="$(dirname "$host_pub")"
    per_user_has_files="$(find "$per_user_keys_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    system_has_files="$(find "$system_keys_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)"
    if [ -z "$per_user_has_files" ] && [ -z "$system_has_files" ]; then
      echo "[limaConfig][HINT] found /run/secrets/nix-darwin-home/nxmatic-ssh-keys.yaml but ${per_user_keys_dir} and ${system_keys_dir} are empty"
      echo "[limaConfig][HINT] this usually means the Home Manager ssh-keys activation pipeline did not run"
    fi
  fi

  : "Stage NixOS disk image to stable path"
  img_src="@imageSourcePath@"
  img_dst="@imageTargetPath@"

  if [[ "$img_src" == /net/* || "$img_dst" == /net/* ]]; then
    if [ ! -d /net ]; then
      echo "[limaConfig][WARN] /net is missing but image paths use /net (autofs prerequisite not met)"
      echo "[limaConfig][HINT] enable services.nfsDarwin.autofs for mountPoint=/net, then rerun lima-config-materialize"
    fi
  fi

  mkdir -p "$(dirname "$img_dst")"
  if [ -f "$img_src" ]; then
    if [ "$img_src" = "$img_dst" ]; then
      echo "[limaConfig] using image in-place at $img_src"
    else
      echo "[limaConfig] staging image from $img_src to $img_dst"
      cp --reflink=auto "$img_src" "$img_dst" 2>/dev/null || cp "$img_src" "$img_dst"
    fi
  else
    echo "[limaConfig][WARN] source image missing: $img_src"
  fi

  : "Install managed Lima config variants (headless + gui)"
  ln -sfn "@limaConfigYamlHeadless@" "@profileHome@/.lima/nerd-nixos/lima.headless.yaml"
  ln -sfn "@limaConfigYamlGui@" "@profileHome@/.lima/nerd-nixos/lima.gui.yaml"

  : "Keep active lima.yaml on headless profile by default"
  ln -sfn "@profileHome@/.lima/nerd-nixos/lima.headless.yaml" "@profileHome@/.lima/nerd-nixos/lima.yaml"
  : "Verify output file"
  if [ -e "@profileHome@/.lima/nerd-nixos/lima.yaml" ]; then
    echo "[limaConfig] linked @profileHome@/.lima/nerd-nixos/lima.yaml -> $(readlink "@profileHome@/.lima/nerd-nixos/lima.yaml" || echo '<not-a-symlink>')"
    echo "[limaConfig] headless size=$(wc -c < "@limaConfigYamlHeadless@")"
    echo "[limaConfig] gui size=$(wc -c < "@limaConfigYamlGui@")"
    grep -E 'gateway|clusterId|display' "@limaConfigYamlHeadless@" || true
    if [ -w /var/db ]; then
      touch /var/db/lima-config-generated
    else
      echo "[limaConfig][INFO] skipping /var/db/lima-config-generated marker (insufficient privileges)"
    fi
  else
    echo "[limaConfig][ERROR] lima.yaml missing after generation attempt"
  fi
  echo "[limaConfig] end $(date)"
}

activation_run darwin.activationScripts.postActivation.lima-config main "$@"
