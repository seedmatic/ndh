{ config, pkgs, ... }:
let
  script = pkgs.writeShellScript "lima-nixos-config" ''
    set -euo pipefail

    [[ -r /etc/nixos/flake.nix ]] && {
      echo "NixOS configuration already exists, skipping clone."
      exit 0
    }

    echo "Cloning NixOS configuration for ${config.limaHost.hostName}"
    mkdir -p /var/lib/nixos
    git clone --single-branch --branch develop \
      https://github.com/nxmatic/nix-darwin-home.git /var/lib/nixos/config

    echo "Creating symlink to NixOS configuration"
    mkdir -p /etc/nixos
    ln -fs /var/lib/nixos/config/hosts/${config.limaHost.hostName}/flake.nix /etc/nixos/
  '';

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

    path = with pkgs; [ coreutils git ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true; # Keep the service active after execution
      ExecStart = "${script}";
    };

    unitConfig = { X-StopOnRemoval = false; };
  };

}
