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

  : "Stage NixOS disk image to stable path"
  img_src="@imageSourcePath@"
  img_dst="@imageTargetPath@"
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

  : "Install managed lima.yaml as symlink to store path"
  ln -sfn "@limaConfigYaml@" "@profileHome@/.lima/nerd-nixos/lima.yaml"
  : "Verify output file"
  if [ -e "@profileHome@/.lima/nerd-nixos/lima.yaml" ]; then
    echo "[limaConfig] linked @profileHome@/.lima/nerd-nixos/lima.yaml -> $(readlink "@profileHome@/.lima/nerd-nixos/lima.yaml" || echo '<not-a-symlink>')"
    echo "[limaConfig] generated size=$(wc -c < "@limaConfigYaml@")"
    grep -E 'gateway|clusterId' "@limaConfigYaml@" || true
    touch /var/db/lima-config-generated
  else
    echo "[limaConfig][ERROR] lima.yaml missing after generation attempt"
  fi
  echo "[limaConfig] end $(date)"
}

activation_run darwin.activationScripts.postActivation.lima-config main "$@"
