{
  config,
  pkgs,
  lib,
  ...
}:
let
  # Build helper binary from repository script (no inline bash to avoid interpolation issues)
  limaNixosConfigPkg = pkgs.writeShellScriptBin "lima-nixos-config" (
    builtins.readFile ./lima-nixos-config.sh
  );

  # Whether we might need network (only if cloning is allowed at runtime). We can't know env at build
  # so we keep network dependency minimal; remove strict requires.
  needsNetwork = false; # linking is primary path; cloning optional & user-triggered

  baseAfter = [ "io-nxmatic-nix-darwin-home-lima-cloud-init.service" ];
  afterList = baseAfter ++ lib.optional needsNetwork "network-online.target";

in
{
  systemd.services.io-nxmatic-nix-darwin-home-lima-nixos-config = {
    description = "Link (preferred) or optionally clone NixOS darwin home repo for Lima host";

    # Only need cloud-init first (mounts, user home). Network not strictly required for linking.
    after = afterList;
    wants = [ "io-nxmatic-nix-darwin-home-lima-cloud-init.service" ];

    # Don't hard require network or resolvconf anymore; cloning is fallback and user-controlled.
    wantedBy = [ "io-nxmatic-nix-darwin-home-contributed.target" ];

    path = with pkgs; [
      coreutils
      git
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${limaNixosConfigPkg}/bin/lima-nixos-config ${config.limaHost.hostName}";
      TimeoutStartSec = 60;
    };

    # Skip running if flake already linked (negative condition prevents re-run each boot)
    unitConfig = {
      X-StopOnRemoval = false;
      ConditionPathExists = "!/etc/nixos/flake.nix"; # run only if missing
    };
  };
}
