#!/usr/bin/env -S bash -xeuo pipefail
LOG="/var/log/darwin-internet-sharing-activation.log"
{
  echo "[internetSharing] configuring Internet Sharing NAT"
  @configurePlist@

  @verifyAnchorsBlock@
} >>"$LOG" 2>&1
