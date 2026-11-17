{
  profile,
  config,
  lib,
  pkgs,
  worktreePath,
  ndh,
  ...
}:
{
  imports = [
    (worktreePath.of "modules/.common.d")
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./darwin-rebuild-gh.nix
    ./etc-backup.nix
    ./disable-spotlight.nix
    ./disable-google-updaters.nix
    ./disable-unwanted-agents.nix
    ./nfsd-off.nix
    ./nfs-autofs.nix
    ./corp-egress-guard.nix
    ./tailnet-client.nix
    ./headscale-daemon.nix
    ./headscale-client-kind.nix
    ./tailnet-client-tools.nix
    ./ddns.nix
    ./lan-dns-resolver.nix
    ./baremetal-resolvers.nix
    ./baremetal-link.nix
    ./tart-config.nix
    ./linux-builder.nix
    ./host-builder.nix
    ./network-bond.nix
    ./static-routes.nix
    ./raycast.nix
    ./openssh.nix
    ./github-mcp-proxy.nix
    ./shell-keychain.nix
    ./activation-order.nix
    ./restart-on-secret-change.nix
    ./omo-ps-setuid-check.nix
    ./incus-cluster-cert.nix
    ./attic-client.nix
    ./ssh-keys-enrichment.nix
    ./user-secret-mirror.nix
    ./ssh-client.nix
    ./cache-trust.nix
    ./nix-signing.nix
    ./nix-store-identity.nix
    ./build-users-group.nix
    ./nfs-remote-identity.nix
    ./incus-remote-trust.nix
    ./sops.nix
    ./keyring.nix
    ./bringup-observe.nix
    ./tailscale-vnc-forward.nix
    ./tls-authority-keychain.nix
    ./launchd-orphan-cleanup.nix
    ./tmpdir-tmpfs.nix
    ./llm-gateway.nix
    ./ndh-switch.nix
  ];

  # NFS: export only the git stores; disable /net autofs browsing.
  # Scope exports to this metalspace's fabric slice (172.16.x.0/20) instead of the
  # whole LAN/tailnet — peer isolation: only the metalspace's own hypervisor +
  # instances may mount.  Localhost and the socket_vmnet subnet keep their access.
  services.nfsDarwin = {
    exports = [
      "/Volumes/git-worktree-store"
      "/Volumes/git-bare-store"
    ];
    allowedNetworks = [ ];
    clientScopes =
      let
        ndhContext = ndh.context or { };
        catalog = ndhContext.catalog or { };
        netplan = catalog.netplan or { };
        hostProfile = config.profile.host or { };
        effectiveHostName =
          if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
            hostProfile.hostAlias
          else
            (hostProfile.hostName or "");
        bm = (netplan.baremetal or { }).${effectiveHostName} or null;
        fabricCidr = if bm != null then (bm.advertiseCidr or null) else null;
      in
      (
        if fabricCidr != null then
          [
            {
              clients = fabricCidr;
              options = "";
            }
          ]
        else
          [ ]
      )
      ++ [
        {
          clients = "127.0.0.1/8";
          options = "";
        }
        {
          clients = "10.80.16.0/24";
          options = "";
        }
      ];
    autofs.enable = false;
  };

  # Active le résolveur .lan par défaut (modifiable par hôte).  Le nameserver et le
  # domaine de recherche viennent du catalogue (defaults de l'option) — pas de
  # littéral ici.
  networking.lanDnsResolver.enable = true;

  activation.postActivationLogShowLabel = "macOS unified log (last 2h)";
  activation.postActivationLogShowCmd = "log show --last 2h --style compact --info --debug --predicate 'eventMessage CONTAINS \"darwin.activationScripts\" OR eventMessage CONTAINS \"home-manager.activationScripts\"'";
  activation.postActivationLogStreamLabel = "macOS unified log (stream)";
  activation.postActivationLogStreamCmd = "log stream --style compact --level debug --predicate 'eventMessage CONTAINS \"darwin.activationScripts\" OR eventMessage CONTAINS \"home-manager.activationScripts\"'";

  # Darwin-specific HM post-activation execution wiring.
  system.activationScripts.postActivation.text = lib.mkOrder config.ndh.darwin.postActivationOrder.homeManager ''
    ${config.activation.homeManagerPostActivationScript}
  '';

}
