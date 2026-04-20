#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

main() {
  local synthetic_conf="/etc/synthetic.conf"

  if [ ! -e "$synthetic_conf" ]; then
    return 0
  fi

  local run_count
  run_count="$(grep -Ec '^run([[:space:]]|$)' "$synthetic_conf" || true)"
  if [ "${run_count:-0}" -le 1 ]; then
    return 0
  fi

  echo "pre-activation: deduplicating run entries in /etc/synthetic.conf..." >&2
  local tmp_synthetic
  tmp_synthetic="$(mktemp /tmp/synthetic.conf.pre.XXXXXX)"

  awk '
    BEGIN { seen_run = 0 }
    /^run([[:space:]]|$)/ {
      if (seen_run) {
        next
      }
      seen_run = 1
    }
    { print }
  ' "$synthetic_conf" > "$tmp_synthetic"

  cat "$tmp_synthetic" > "$synthetic_conf"
  rm -f "$tmp_synthetic"
}

ndh::logger:command:run darwin.activationScripts.preActivation.nfs-synthetic-dedupe main "$@"
