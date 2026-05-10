{
  config,
  pkgs,
  ndhSystemd,
  ...
}:
# Order the shared nix-store identity deploy script (defined in
# modules/.common.d/nix-store-identity.nix) after the extract pipeline so the
# source files at ${sshPaths.systemKeysDir}/nix-store{,-cert.pub} exist when
# it runs. Mirrors the Darwin activation wiring at
# modules/darwin/linux-builder.nix for the same identity.
let
  sshKeysEnrichmentServiceName = ndhSystemd.mkServiceName "ssh-keys-enrichment";
in
{
  config = {
    nixStoreIdentity.enable = true;

    # Anchor the deploy to nix-daemon.service — the actual consumer of
    # /etc/nix/nix-store_ed25519. `wantedBy` pulls the deploy into boot
    # whenever nix-daemon is enabled (always, on any NixOS host in this
    # repo); `before` guarantees the identity is in place before
    # nix-daemon starts processing remote-store ssh-ng requests. This
    # works on bringup (which doesn't import modules/nixos/systemd's
    # contributed target) and on the full runtime alike — no conditional
    # fallback needed.
    systemd.services.${ndhSystemd.mkUnitName "nix-store-identity"} = {
      description = "Deploy cert-signed nix-store identity to ${config.nixStoreIdentity.keyPath} (@codebase)";
      wantedBy = [ "nix-daemon.service" ];
      before = [ "nix-daemon.service" ];
      requires = [ sshKeysEnrichmentServiceName ];
      after = [ sshKeysEnrichmentServiceName ];
      path = with pkgs; [ coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        ExecStart = "${config.nixStoreIdentity.deployScript}/bin/nix-store-identity-deploy";
      };
    };
  };
}
