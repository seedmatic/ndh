#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  echo "[limaConfig] start $(date) host=@effectiveHostName@ user=@profileUser@"

  : "Create Lima configuration directory in profile home"
  mkdir -p "@profileHome@/.lima/nerd-nixos"
  mkdir -p "@profileHome@/.lima/_config"

  host_pub="@profileHome@/.ssh/keys.d/host.pub"
  host_priv="@profileHome@/.ssh/keys.d/host"

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

  : "Generate lima.yaml with profile user configuration using yq"
  cat << 'EOF' | @yqBin@ -P -p json -o yaml eval . - > "@profileHome@/.lima/nerd-nixos/lima.yaml"
@limaConfigJson@
EOF
  chmod 0600 "@profileHome@/.lima/nerd-nixos/lima.yaml"
  : "Verify output file"
  if [ -f "@profileHome@/.lima/nerd-nixos/lima.yaml" ]; then
    echo "[limaConfig] generated size=$(wc -c < "@profileHome@/.lima/nerd-nixos/lima.yaml")"
    grep -E 'gateway|clusterId' "@profileHome@/.lima/nerd-nixos/lima.yaml" || true
    touch /var/db/lima-config-generated
  else
    echo "[limaConfig][ERROR] lima.yaml missing after generation attempt"
  fi
  echo "[limaConfig] end $(date)"
}

activation_run darwin.activationScripts.postActivation.lima-config main "$@"
