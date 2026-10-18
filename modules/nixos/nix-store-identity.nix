{
  config,
  lib,
  ndh,
  ...
}:
# NixOS idiom for the nix-store account declared in modules/.common.d/nix-store-identity.nix: a system user, its
# ids allocated by NixOS. The ssh-keys-enrichment unit writes its identity files before sshd starts.
let
  cfg = config.nixStoreIdentity;
in
{
  config = {
    # Enable by default for every NixOS host in this repo — the nix-store
    # identity is part of the fleet's baseline signing/copy infrastructure.
    nixStoreIdentity.enable = lib.mkDefault true;
    # A running guest only receives: no nix-store alias nor client key, so a build it receives is never
    # forwarded. The bring-up system keeps them, for the operator's manual rescue (`nix copy` as root).
    nixStoreIdentity.outbound = ndh.context.generationMode == "bringup";

    users.users = lib.mkIf (cfg.enable && cfg.provisionInboundUser) {
      ${cfg.inboundUserName} = {
        isSystemUser = true;
        group = cfg.inboundUserName;
        # NixOS's users-groups validator needs a package with passthru.shellPath, not a bare string path.
        shell = cfg.inboundUserShellPackage;
        useDefaultShell = false;
      };
    };
  };
}
