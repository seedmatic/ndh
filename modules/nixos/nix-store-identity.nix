{
  config,
  lib,
  pkgs,
  ...
}:
# NixOS wiring for the nix-store identity.
#
# Options + deploy script live at modules/.common.d/nix-store-identity.nix
# (platform-agnostic). This module fills in the NixOS-specific details:
#
#   - installGroup = "root"
#   - users.users.<name> declaration in the NixOS idiom
#     (isSystemUser + explicit nixbld group; no knownUsers)
#   - systemd oneshot that runs the deploy script, anchored to
#     nix-daemon.service so the identity is present before any remote-
#     store ssh-ng consumer triggers the daemon.
let
  cfg = config.nixStoreIdentity;
in
{
  config = {
    # Enable by default for every NixOS host in this repo — the nix-store
    # identity is part of the fleet's baseline signing/copy infrastructure.
    nixStoreIdentity.enable = lib.mkDefault true;
    nixStoreIdentity.installGroup = lib.mkIf cfg.enable "root";

    users.users = lib.mkIf (cfg.enable && cfg.provisionInboundUser) {
      ${cfg.inboundUserName} = {
        isSystemUser = true;
        group = "nixbld";
        description = "Inbound nix-daemon --stdio endpoint";
        # NixOS's users-groups validator needs a package with
        # passthru.shellPath, not a bare string path.
        shell = cfg.inboundUserShellPackage;
        useDefaultShell = false;
      };
    };

    # Anchor the deploy to nix-daemon.service — the actual consumer of
    # /etc/nix/nix-store_ed25519. `wantedBy` pulls the unit into boot on
    # any NixOS host in this repo; `before` guarantees the identity is
    # written before nix-daemon handles its first remote-store request.
    systemd.services.nix-store-identity-deploy = lib.mkIf cfg.enable {
      description = "Deploy cert-signed nix-store identity to ${cfg.keyPath} (@codebase)";
      wantedBy = [ "nix-daemon.service" ];
      before = [ "nix-daemon.service" ];
      # The source files live at sshPaths.systemKeysDir and are written
      # by the ssh-keys-enrichment systemd unit; wait for it before
      # running the deploy.
      requires = [ "io-nxmatic-nix-darwin-home-ssh-keys-enrichment.service" ];
      after = [ "io-nxmatic-nix-darwin-home-ssh-keys-enrichment.service" ];
      path = with pkgs; [ coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        ExecStart = "${cfg.deployScript}/bin/nix-store-identity-deploy";
      };
    };
  };
}
