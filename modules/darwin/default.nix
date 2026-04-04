{
  profile,
  config,
  lib,
  pkgs,
  self,
  ...
}:
{
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./cachix-watch-store.nix
    ./disable-spotlight.nix
    ./disable-google-updaters.nix
    ./disable-unwanted-agents.nix
    ./dnsmasq.nix
    ./headscale.nix
    ./bird-daemon.nix
    ./lan-dns-resolver.nix
    ./nfs-autofs.nix
    ./lima-config.nix
    ./linux-builder.nix
    ./distributed-builds.nix
    ./network-bond.nix
    ./static-routes.nix
    ./vlan.nix
    ./podman-remote-client.nix
    ./raycast.nix
    # ./socket_vmnet.nix
    ./openssh.nix
    ./github-mcp-proxy.nix
    ./shell-keychain.nix
    ./ssh-client.nix
    ./incus-remote-trust.nix
  ];

  # Active le résolveur .lan par défaut (modifiable par hôte)
  networking.lanDnsResolver.enable = true;
  networking.lanDnsResolver.nameserver = "192.168.1.254";

  # Darwin-specific HM post-activation execution wiring.
  system.activationScripts.postActivation.text = lib.mkOrder 2000 ''
    ${config.activation.homeManagerPostActivationScript}
  '';

  # Darwin policy: keep activation-script path for sops and use system sudo path.
  sops.useSystemdActivation = lib.mkDefault false;
  nxmatic.sopsAgeKeyBootstrap = {
    defaultAgeKeyFile = lib.mkDefault (
      if config.nxmatic.sopsAgeKeyBootstrap.darwinSystemWideKey then
        config.nxmatic.sopsAgeKeyBootstrap.systemWideKeyFile
      else
        config.nxmatic.sopsAgeKeyBootstrap.darwinUserKeyFile
    );
    sudoCommand = lib.mkDefault "/usr/bin/sudo";
  };

  activation.loggerCmd = lib.mkDefault "/usr/bin/logger -p notice -t %TAG%";
}
