#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
  if [ ! -e /etc/synthetic.conf ]; then
    cat > /etc/synthetic.conf <<'EOF'
@syntheticText@
EOF
  else
    local run_count
    run_count="$(grep -Ec '^run([[:space:]]|$)' /etc/synthetic.conf || true)"
    if [ "${run_count:-0}" -gt 1 ]; then
      echo "found duplicate run entries in /etc/synthetic.conf, removing..." >&2
      local tmp_synthetic
      tmp_synthetic="$(mktemp /tmp/synthetic.conf.XXXXXX)"
      awk '
        BEGIN { seen_run = 0 }
        /^run([[:space:]]|$)/ {
          if (seen_run) {
            next
          }
          seen_run = 1
        }
        { print }
      ' /etc/synthetic.conf > "$tmp_synthetic"
      cat "$tmp_synthetic" > /etc/synthetic.conf
      rm -f "$tmp_synthetic"
    fi

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

ndh::logger:command:run darwin.activationScripts.etc.nfs-synthetic-ensure main "$@"
