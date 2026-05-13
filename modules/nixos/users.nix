# User management configuration for NixOS systems.
# Configures the profile user, builder user, and root authorized keys.
{ config, lib, ... }:
let
  ndhContext = config.ndh.context or { };
  generationMode = ndhContext.generationMode or "full";
  runtimeMode = generationMode != "bringup";

  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  cfgUserIsNormal = cfgUser.isNormalUser or true;
  cfgUidLow = cfgUser.uid != null && cfgUser.uid < 1000;
  cfgGidLow = cfgUser.gid != null && cfgUser.gid < 1000;
  nixosUserUid = if cfgUserIsNormal && cfgUidLow then null else cfgUser.uid;
  nixosUserGid = if cfgUserIsNormal && cfgGidLow then null else cfgUser.gid;

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
  # carrying principal `rdp-host`.  That path works through
  # TrustedUserCAKeys + AuthorizedPrincipalsCommand and does not require
  # an entry in authorized_keys.  However we ALSO install the rdp-host
  # bare public key here so a plain-key connection works — a useful
  # rescue path if the principals command is unreachable, the CA file
  # drifts, or a client strips the cert for any reason.
  users.users.${cfgUserName} = {
    group = cfgUserName;
    extraGroups = nixosUserExtraGroups;
    uid = lib.mkIf (nixosUserUid != null) nixosUserUid;
    linger = true;
    openssh.authorizedKeys.keys = lib.mkIf runtimeMode (
      config.ndh.keysYaml.authorizedLinesFor [ "rdp-host" ]
    );
  };
  users.groups.${cfgUserName} = if nixosUserGid != null then { gid = nixosUserGid; } else { };

  # builder user: accepts the linux-builder key from the Darwin host for remote builds.
  users.users.builder = lib.mkIf runtimeMode {
    isNormalUser = true;
    group = "builder";
    extraGroups = [
      "wheel"
      "nixbld"
    ];
    description = "Nix remote builder";
    openssh.authorizedKeys.keys = config.ndh.keysYaml.authorizedLinesFor [ "linux-builder" ];
  };
  users.groups.builder = lib.mkIf runtimeMode { };

  # nix-store user provisioning moved to modules/.common.d/nix-store-identity.nix
  # so Darwin gets the same treatment via a single source of truth.

  # root: accepts the linux-builder key (for root-level build operations)
  # and the rdp-host key (interactive operator access).
  users.users.root.openssh.authorizedKeys.keys = lib.mkIf runtimeMode (
    config.ndh.keysYaml.authorizedLinesFor [
      "linux-builder"
      "rdp-host"
    ]
  );
}
