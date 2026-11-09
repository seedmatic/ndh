{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Warns at activation time if /bin/ps has regained its setuid bit
  # (typically after a macOS system update restores the original binary).
  # The setuid bit causes EPERM when omo's hardened runtime spawns /bin/ps.
  # Fix: sh /etc/recovery.d/omo-ps-setuid.sh (run in Recovery OS).
  system.activationScripts.check-ps-setuid.text = lib.mkOrder 1500 ''
    if [ -u /bin/ps ]; then
      echo "" >&2
      echo "WARNING: /bin/ps is setuid again (likely restored by a macOS update)." >&2
      echo "         This causes EPERM in omo (memory reflection paused)." >&2
      echo "         Fix: sh /etc/recovery.d/omo-ps-setuid.sh in Recovery OS." >&2
      echo "" >&2
    fi
  '';

  # Install recovery helper scripts to /etc/recovery.d/ so they are available
  # in Recovery OS at /Volumes/<SystemVolume>/etc/recovery.d/.
  environment.etc."recovery.d/omo-ps-setuid.sh" = {
    source = ./recovery.d/omo-ps-setuid.sh;
  };
}
