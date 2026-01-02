#!/usr/bin/env -S bash -xeuo pipefail
LOG="/var/log/darwin-disable-google-updaters.log"
{
  echo "[google-updaters] Disabling Google update services"
  @disableGoogleUpdatersScript@/bin/disable-google-updaters
} >>"$LOG" 2>&1
