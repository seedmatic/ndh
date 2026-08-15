# NetFlow probe for the bare-metal vz host (nikopol-vz).
#
# The traffic the operator wants to see — the MacBook's own uplink to the
# Android hotspot — only exists on the bare metal's physical Wi-Fi (en0): a Tart
# guest bridged to that Wi-Fi never sees the host's own unicast (switched L2),
# so the probe MUST run on the bare metal, not in a VM.  softflowd captures en0
# and exports NetFlow to the Akvorado inlet on the NixOS VM.
#
# nikopol-vz is outside the ndh nix-darwin fleet (it has a nix store + flox but
# no darwin-rebuild activation), so this bundle carries softflowd plus a root
# LaunchDaemon installer that renders the plist at deploy time — mirroring how
# nerd-tart lands a per-VM YAML on the vz host rather than baking it into a
# system module.  It is copied over via the same `nix copy` rail as the Tart
# artifacts (see the `netflow-probe-deploy` helper in flake.nix).
{
  lib,
  softflowd,
  coreutils,
  replaceVars,
  writeShellApplication,
  symlinkJoin,
}:
let
  label = "io.nxmatic.netflow-probe";
  plistPath = "/Library/LaunchDaemons/${label}.plist";
  logPath = "/var/log/netflow-probe.log";

  install = writeShellApplication {
    name = "netflow-probe-install";
    runtimeInputs = [ coreutils ];
    text = builtins.readFile (
      replaceVars ./netflow-probe.d/install.sh {
        softflowd = "${softflowd}";
        label = label;
        plist = plistPath;
        log = logPath;
      }
    );
  };

  uninstall = writeShellApplication {
    name = "netflow-probe-uninstall";
    runtimeInputs = [ coreutils ];
    text = builtins.readFile (
      replaceVars ./netflow-probe.d/uninstall.sh {
        label = label;
        plist = plistPath;
      }
    );
  };
in
symlinkJoin {
  name = "netflow-probe";
  paths = [
    install
    uninstall
    softflowd
  ];
  meta = {
    description = "softflowd NetFlow probe + root LaunchDaemon installer for the bare-metal vz host";
    platforms = lib.platforms.darwin;
    mainProgram = "netflow-probe-install";
  };
}
