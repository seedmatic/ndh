# User management configuration for NixOS systems.
# Configures the profile user, builder user, and root authorized keys.
{ config, lib, pkgs, self, ... }:
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

  # Builder SSH keys from keys.yaml (not SOPS-encrypted)
  # Must use pkgs.runCommand to convert YAML to JSON (matches default.nix pattern)
  builderKeys = builtins.fromJSON (
    builtins.readFile (
      pkgs.runCommand "ndh-linux-builder-keys.json" { buildInputs = [ pkgs.yq-go ]; } ''
        yq -o=json '.' "${self}/modules/home-manager/ssh.d/keys.yaml" > "$out"
      ''
    )
  );

in
{
  # Profile user configuration
  users.users.${cfgUserName} = {
    group = cfgUserName;
    extraGroups = nixosUserExtraGroups;
    uid = lib.mkIf (nixosUserUid != null) nixosUserUid;
    linger = true;
  };
  users.groups.${cfgUserName} = if nixosUserGid != null then { gid = nixosUserGid; } else { };

  # builder user: accepts the linux-builder key from the Darwin host for remote builds.
  # The public key is baked in at build time from keys.yaml (not SOPS-encrypted).
  users.users.builder = lib.mkIf runtimeMode {
    isNormalUser = true;
    group = "builder";
    extraGroups = [
      "wheel"
      "nixbld"
    ];
    description = "Nix remote builder";
    openssh.authorizedKeys.keys = lib.filter (k: k != "") [
      (
        if builderKeys ? linux-builder && builderKeys.linux-builder ? public then
          "ssh-ed25519 ${builderKeys.linux-builder.public} ndh-linux-builder"
        else
          ""
      )
    ];
  };
  users.groups.builder = lib.mkIf runtimeMode { };

  # nix-store user provisioning moved to modules/.common.d/nix-store-identity.nix
  # so Darwin gets the same treatment via a single source of truth.

  # root: also accepts linux-builder key for builds that require root-level operations.
  users.users.root.openssh.authorizedKeys.keys = lib.mkIf runtimeMode (
    lib.filter (k: k != "") [
      (
        if builderKeys ? linux-builder && builderKeys.linux-builder ? public then
          "ssh-ed25519 ${builderKeys.linux-builder.public} ndh-linux-builder"
        else
          ""
      )
    ]
  );
}
