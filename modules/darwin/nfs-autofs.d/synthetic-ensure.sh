#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  if [ ! -e /etc/synthetic.conf ]; then
    cat > /etc/synthetic.conf <<'EOF'
@syntheticText@
EOF
  else
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if ! grep -Fxq "$line" /etc/synthetic.conf; then
        printf '%s\n' "$line" >> /etc/synthetic.conf
      fi
    done <<'EOF'
@syntheticText@
EOF
  fi
}

activation_run darwin.activationScripts.etc.nfs-synthetic-ensure main "$@"
