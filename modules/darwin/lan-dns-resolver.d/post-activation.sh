#!/usr/bin/env -S bash -euo pipefail
source @activationLogger@

main() {
  echo "[lanDns] Validating LAN resolver"

  if ping -c 1 -W 1 @nameserver@ >/dev/null 2>&1; then
    echo "[lanDns] Gateway @nameserver@ reachable; verifying resolver file"
    if [ -f /etc/resolver/lan ]; then
      echo "[lanDns] /etc/resolver/lan present"
    else
      echo "[lanDns][WARN] /etc/resolver/lan missing"
    fi
    dscacheutil -flushcache
    killall -HUP mDNSResponder 2>/dev/null || true
  else
    echo "[lanDns] Gateway @nameserver@ unreachable; skipping resolver refresh"
  fi
}

activation_run darwin.activationScripts.networking.lan-dns-resolver main "$@"
