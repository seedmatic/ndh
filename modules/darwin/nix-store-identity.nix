{
  config,
  lib,
  ...
}:
# Darwin wiring for the nix-store identity.
#
# Options + deploy script live at modules/.common.d/nix-store-identity.nix
# (platform-agnostic). This module fills in the Darwin-specific details:
#
#   - installGroup = "wheel" (default Mac admin group; NixOS uses "root")
#   - users.knownUsers + users.users.<name> declaration in the
#     nix-darwin idiom (requires explicit UID + gid)
#   - activation-time invocation of the deploy script in postActivation
let
  cfg = config.nixStoreIdentity;
in
{
  config = {
    # Enable by default for every Darwin host in this repo. linux-builder
    # and nix copy flows both rely on the identity being in place.
    nixStoreIdentity.enable = lib.mkDefault true;
    # Darwin uses `wheel` as the canonical admin group for root-owned files.
    nixStoreIdentity.installGroup = lib.mkIf cfg.enable "wheel";

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

    # Deploy the identity at activation time. Ordered after
    # ssh-keys-enrichment's postActivation block (lib.mkOrder 1400) by
    # landing at a higher mkOrder so the source files at
    # sshPaths.systemKeysDir exist when the script runs.
    system.activationScripts.postActivation.text = lib.mkIf cfg.enable (
      lib.mkOrder 1500 ''
        ${cfg.deployScript}/bin/nix-store-identity-deploy
      ''
    );
  };
}
