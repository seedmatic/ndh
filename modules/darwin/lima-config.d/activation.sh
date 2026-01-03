#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  echo "[limaConfig] start $(date) host=@effectiveHostName@ user=@profileUser@"

  : "Create Lima configuration directory in profile home"
  mkdir -p "@profileHome@/.lima/nerd-nixos"

  : "Generate lima.yaml with profile user configuration using yq"
  cat << 'EOF' | @yqBin@ -P -p json -o yaml eval . - > "@profileHome@/.lima/nerd-nixos/lima.yaml"
@limaConfigJson@
EOF
  chmod 0600 "@profileHome@/.lima/nerd-nixos/lima.yaml"

  @homeSymlinksBlock@

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
