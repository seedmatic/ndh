{
  config,
  pkgs,
  lib,
  ...
}:
let
  # Resolve hostName: prefer config.limaHost.hostName if defined; fallback to networking.hostName
  hostName =
    if
      (
        config ? limaHost
        && config.limaHost ? hostName
        && config.limaHost.hostName != null
        && config.limaHost.hostName != ""
      )
    then
      config.limaHost.hostName
    else
      config.networking.hostName;
  flakeRef = "/etc/nixos"; # canonical flake symlink
  systemAttr = "nixosConfigurations.${hostName}.config.system.build.toplevel";

  # Helper to build a script by replacing @var@ placeholders with pkgs.replaceVars (modern substituteAll)
  makeScript =
    name: srcFile:
    pkgs.runCommand name { } ''
      install -Dm755 ${
        pkgs.replaceVars srcFile { inherit hostName systemAttr flakeRef; }
      } $out/bin/${name}
    '';

  manualSwitch = makeScript "system-manual-switch" ./system-manual-switch.sh;
  manualBoot = makeScript "system-manual-boot" ./system-manual-boot.sh;
  nixosRebuildGuest = makeScript "nixos-rebuild-guest" ./nixos-rebuild-guest.sh;

in
{
  environment.systemPackages = [
    manualSwitch
    manualBoot
    nixosRebuildGuest
  ];

  environment.etc."manual-switch.README".text = ''
    Manual system switch helpers installed:

      system-manual-switch [<flake>]
        Build & activate new system generation (no transient unit).

      system-manual-boot [<flake>]
        Build & set next boot generation (no live activation).

      nixos-rebuild-guest [switch|boot|test|build|dry-build] [<flake>]
        Wrapper avoiding systemd-run transient units.

    Defaults:
      Flake path: ${flakeRef}
      System attr: ${systemAttr}
  '';
}
