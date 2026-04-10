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
    ../.common.d
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
    ./sops.nix
  ];

  # Active le résolveur .lan par défaut (modifiable par hôte)
  networking.lanDnsResolver.enable = true;
  networking.lanDnsResolver.nameserver = "192.168.1.254";

  activation.postActivationLogShowLabel = "macOS unified log (last 2h)";
  activation.postActivationLogShowCmd = "log show --last 2h --style compact --info --debug --predicate 'eventMessage CONTAINS \"darwin.activationScripts\" OR eventMessage CONTAINS \"home-manager.activationScripts\"'";
  activation.postActivationLogStreamLabel = "macOS unified log (stream)";
  activation.postActivationLogStreamCmd = "log stream --style compact --level debug --predicate 'eventMessage CONTAINS \"darwin.activationScripts\" OR eventMessage CONTAINS \"home-manager.activationScripts\"'";

  # Darwin-specific HM post-activation execution wiring.
  system.activationScripts.postActivation.text = lib.mkOrder 2000 ''
    ${config.activation.homeManagerPostActivationScript}
  '';

}
