# User management configuration for NixOS systems.
# Configures the profile user and root authorized keys.
{ config, lib, ... }:
let
  ndhContext = config.ndh.context or { };
  generationMode = ndhContext.generationMode or "full";
  runtimeMode = generationMode != "bringup";

  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;

  nixosUserExtraGroups = [
    "keys"
    "wheel"
    "ssh"
  ];

in
{
  # Profile user configuration.
  #
  # The operator (nxmatic) connects via the mammoth-skate-signed cert
  # carrying principal `operator`.  That path works through
  # TrustedUserCAKeys + AuthorizedPrincipalsCommand and does not require
  # an entry in authorized_keys.  However we ALSO install the operator
  # bare public key here so a plain-key connection works — a useful
  # rescue path if the principals command is unreachable, the CA file
  # drifts, or a client strips the cert for any reason.
  users.users.${cfgUserName} = {
    extraGroups = nixosUserExtraGroups;
    linger = true;
    openssh.authorizedKeys.keys = lib.mkIf runtimeMode (
      config.ndh.keysYaml.authorizedLinesFor [ "operator" ]
    );
  };
  users.groups.${cfgUserName} = lib.optionalAttrs (cfgUser.gid != null) { gid = cfgUser.gid; };

  # The remote builds are served by the nix-store account (modules/.common.d/nix-store-identity.nix).

  # root: accepts the linux-builder key (for root-level build operations)
  # and the operator key (interactive operator access).
  users.users.root.openssh.authorizedKeys.keys = lib.mkIf runtimeMode (
    config.ndh.keysYaml.authorizedLinesFor [
      "linux-builder"
      "operator"
    ]
  );
}
