{
  config,
  lib,
  ...
}:
# Darwin idiom for the nix-store account declared in modules/.common.d/nix-store-identity.nix: nix-darwin manages
# only known users and groups, by explicit numeric ids, and macOS's directory services must be healed before
# nix-darwin checks the record.
let
  cfg = config.nixStoreIdentity;
  homeDir = cfg.inboundUserHome;
in
{
  config = {
    # Enable by default for every Darwin host in this repo. linux-builder
    # and nix copy flows both rely on the identity being in place.
    nixStoreIdentity.enable = lib.mkDefault true;

    # 30000 is the gid the user already had, which named no group: it now names this one, so nothing is re-owned.
    # Darwin only: on NixOS 30000 is nixbld, the build-users-group the daemon refuses.
    users = lib.mkIf (cfg.enable && cfg.provisionInboundUser) {
      knownUsers = [ cfg.inboundUserName ];
      knownGroups = [ cfg.inboundUserName ];
      groups.${cfg.inboundUserName}.gid = 30000;
      users.${cfg.inboundUserName} = {
        uid = cfg.inboundUserUid;
        gid = config.users.groups.${cfg.inboundUserName}.gid;
        shell = cfg.inboundUserShellPath;
      };
    };

    # macOS 26.5 (25F71) ran a directory-services consistency pass that
    # promoted /Users/nix-store to a full interactive user record:
    # rewrote NFSHomeDirectory to /private/var/empty_1 (spurious
    # collision-rename), and added jpegphoto, picture, KerberosKeys,
    # ShadowHashData, accountPolicyData, unlockOptions, etc. The home
    # rewrite trips nix-darwin's "config contains the wrong home
    # directory" check and aborts activation. Heal idempotently before
    # the check runs — ORDER MATTERS: the interactive-user attributes
    # (ShadowHashData, authentication_authority, …) PROTECT the record,
    # so a NFSHomeDirectory rewrite while they are present fails with
    # eDSPermissionError. De-promote the record FIRST, then reset the
    # home with -create (which overwrites unconditionally, unlike -change
    # whose old-value match adds nothing but a failure mode here).
    system.activationScripts.preActivation.text = lib.mkIf (cfg.enable && cfg.provisionInboundUser) (
      lib.mkBefore ''
        if dscl . -read /Users/${cfg.inboundUserName} RecordName &>/dev/null; then
          for attr in jpegphoto picture AvatarRepresentation KerberosKeys ShadowHashData accountPolicyData unlockOptions inputSources authentication_authority hint \
                      _writers_jpegphoto _writers_picture _writers_AvatarRepresentation _writers_hint _writers_inputSources _writers_unlockOptions _writers_UserCertificate _writers_passwd; do
            if dscl . -read /Users/${cfg.inboundUserName} "$attr" &>/dev/null; then
              dscl . -delete /Users/${cfg.inboundUserName} "$attr" || true
            fi
          done
          currentHome=$(dscl . -read /Users/${cfg.inboundUserName} NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')
          if [[ "$currentHome" != ${lib.escapeShellArg homeDir} ]]; then
            printf '[nix-store-identity] resetting NFSHomeDirectory: %s -> %s\n' "$currentHome" ${lib.escapeShellArg homeDir} >&2
            dscl . -create /Users/${cfg.inboundUserName} NFSHomeDirectory ${lib.escapeShellArg homeDir} || true
          fi
        fi
      ''
    );
  };
}
