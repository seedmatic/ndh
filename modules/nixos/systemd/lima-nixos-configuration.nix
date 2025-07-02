{ config, pkgs, ... }:
let

  dollar = "$";

in {

  systemd.services.lima-nixos-configuration = {

    description = "Clone Git Repository if not already cloned";

    after = [
      "network.target"
      "resolvconf.service"
      "lima-cloud-init.service"
    ]; # Ensure network is available before cloning

    requires = [
      "network.target"
      "resolvconf.service"
      "lima-cloud-init.service"
    ]; # Ensure these services are available

    wantedBy =
      [ "multi-user.target" ]; # Specify when this service should be started

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true; # Keep the service active after execution
      Environment = [
        "PATH=/run/current-system/sw/bin"
        "PATH=${pkgs.lib.makeBinPath [ pkgs.git pkgs.bash pkgs.stdenv ]}"
      ];
    };

    unitConfig = { X-StopOnRemoval = false; };

    script = ''
      #!/usr/bin/env -S bash -e -x -o pipefail

      [[ -r /etc/nixos/flake.nix ]] && {
        : NixOS configuration already exists, skipping clone.
        exit 0
      }

      : Setting up environment variables
      PATH=/run/current-system/sw/bin:$PATH

      : Cloning NixOS configuration for ${config.limaHost.hostName}
      mkdir -p /var/run/nixos
      git clone --single-branch --branch develop \
        https://github.com/nxmatic/nix-darwin-home.git /var/run/nixos/config

      : Creating symlink to NixOS configuration
      mkdir -p /etc/nixos
      ln -fs /var/run/nixos/config/hosts/${config.limaHost.hostName}/flake.nix /etc/nixos/
    '';
  };

}
