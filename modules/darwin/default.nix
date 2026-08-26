{
  profile,
  config,
  lib,
  pkgs,
  worktreePath,
  ...
}:
{
  imports = [
    (worktreePath.of "modules/.common.d")
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./etc-backup.nix
    ./cachix-watch-store.nix
    ./disable-spotlight.nix
    ./disable-google-updaters.nix
    ./disable-unwanted-agents.nix
    ./headscale.nix
    ./headscale-daemon.nix
    ./headscale-client-kind.nix
    ./headscale-tools.nix
    ./ddns.nix
    ./bird-daemon.nix
    ./lan-dns-resolver.nix
    ./baremetal-resolvers.nix
    ./tart-config.nix
    ./linux-builder.nix
    ./host-builder.nix
    ./network-bond.nix
    ./static-routes.nix
    ./podman-remote-client.nix
    ./raycast.nix
    # ./socket_vmnet.nix
    ./openssh.nix
    ./github-mcp-proxy.nix
    ./shell-keychain.nix
    ./ssh-keys-enrichment.nix
    ./user-secret-mirror.nix
    ./ssh-client.nix
    ./cache-trust.nix
    ./nix-store-identity.nix
    ./nfs-remote-identity.nix
    ./incus-remote-trust.nix
    ./sops.nix
    ./bringup-observe.nix
    ./tailscale-vnc-forward.nix
    ./tls-authority-keychain.nix
    ./launchd-orphan-cleanup.nix
    ./tmpdir-tmpfs.nix
  ];

  # Active le résolveur .lan par défaut (modifiable par hôte).  Le nameserver et le
  # domaine de recherche viennent du catalogue (defaults de l'option) — pas de
  # littéral ici.
  networking.lanDnsResolver.enable = true;

  activation.postActivationLogShowLabel = "macOS unified log (last 2h)";
  activation.postActivationLogShowCmd = "log show --last 2h --style compact --info --debug --predicate 'eventMessage CONTAINS \"darwin.activationScripts\" OR eventMessage CONTAINS \"home-manager.activationScripts\"'";
  activation.postActivationLogStreamLabel = "macOS unified log (stream)";
  activation.postActivationLogStreamCmd = "log stream --style compact --level debug --predicate 'eventMessage CONTAINS \"darwin.activationScripts\" OR eventMessage CONTAINS \"home-manager.activationScripts\"'";

  # Darwin-specific HM post-activation execution wiring.
  system.activationScripts.postActivation.text = lib.mkOrder 2000 ''
    ${config.activation.homeManagerPostActivationScript}
  '';

}
