{
  config,
  lib,
  ...
}:
# NixOS wiring for the nix-store identity.
#
# Options live at modules/.common.d/nix-store-identity.nix. This module
# fills in the NixOS-specific pieces only: the inbound `nix-store`
# system user. No deploy step — the ssh alias binds the identity files
# directly at their enrichment-source path under sshPaths.systemKeysDir,
# which the ssh-keys-enrichment unit writes before sshd starts.
let
  cfg = config.nixStoreIdentity;
in
{
  config = {
    # Enable by default for every NixOS host in this repo — the nix-store
    # identity is part of the fleet's baseline signing/copy infrastructure.
    nixStoreIdentity.enable = lib.mkDefault true;

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
  };
}
