{ profile, config, lib, pkgs, self, ... }:
let common = import ../common { inherit config lib pkgs self; };
in {
  imports = [
    ../common

    ./preferences.nix
    ./security.nix
    ./core.nix

    ./dnsmasq.nix
    ./linux-builder.nix
    ./raycast.nix
    ./ssh.nix

  ];

  hm = common.hm // {
    # Add or override Home Manager options here
    services.gpg-agent.pinentry.package = pkgs.pinentry_mac;
  };

}
