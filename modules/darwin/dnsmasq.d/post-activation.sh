#!/usr/bin/env -S bash -xeuo pipefail
LOG="/var/log/darwin-dnsmasq-activation.log"
{
  echo "[dnsmasq] Ensuring log path @logFile@"
  mkdir -p "$(dirname @logFile@)"
  touch "@logFile@"
  chmod 644 "@logFile@"
  chown @userName@:staff "@logFile@"
} >>"$LOG" 2>&1
