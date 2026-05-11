{
  config,
  lib,
  ...
}:
# Darwin wiring for the nix-store identity.
#
# Options live at modules/.common.d/nix-store-identity.nix. This module
# fills in the Darwin-specific pieces only: the inbound `nix-store`
# system user in the nix-darwin idiom (knownUsers + users.users.<name>
# with explicit uid + gid). No deploy step — the ssh alias binds the
# identity files directly at their enrichment-source path under
# sshPaths.systemKeysDir.
let
  cfg = config.nixStoreIdentity;
in
{
  config = {
    # Enable by default for every Darwin host in this repo. linux-builder
    # and nix copy flows both rely on the identity being in place.
    nixStoreIdentity.enable = lib.mkDefault true;

    # nix-darwin user provisioning idiom: both users.knownUsers and
    # users.users.<name> (with explicit uid + gid) are required.
    users = lib.mkIf (cfg.enable && cfg.provisionInboundUser) {
      knownUsers = [ cfg.inboundUserName ];
      users.${cfg.inboundUserName} = {
        uid = cfg.inboundUserUid;
        # Use the nixbld group family created by the Nix installer (gid 30000).
        gid = 30000;
        description = "Inbound nix-daemon --stdio endpoint";
        shell = cfg.inboundUserShellPath;
        home = "/var/empty";
      };
    };
  };
}
