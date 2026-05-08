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

  # Login shell restricted to the nix-daemon stdio protocol. Replaces the
  # authorized_keys `command="..."` pattern which does not compose with
  # cert-signed principals (TrustedUserCAKeys + AuthorizedPrincipalsCommand).
  # Materialized at a stable /etc path so it is a plain file rather than a
  # derivation (users.users.*.shell types are shellPackage | passwdEntry path).
  nixStoreShellPath = "/etc/ssh/nix-store-shell";
  nixStoreShellText = ''
    #!/bin/sh
    exec /run/current-system/sw/bin/nix-daemon --stdio
  '';
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

  # builder user: accepts the linux-builder key from the committed Darwin profile for remote builds.
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
          "ssh-ed25519 ${builderKeys.linux-builder.public} committed-linux-builder"
        else
          ""
      )
    ];
  };
  users.groups.builder = lib.mkIf runtimeMode { };

  # nix-store user: dedicated inbound identity for `nix copy` / `nix-daemon
  # --stdio` traffic between hosts, distinct from `builder` which is authorized
  # to drive builds. Authentication is via cert-signed principals
  # (TrustedUserCAKeys + AuthorizedPrincipalsCommand); the login shell
  # restricts any accepted session to the daemon protocol.
  users.users.nix-store = lib.mkIf runtimeMode {
    isSystemUser = true;
    group = "nixbld";
    description = "Inbound nix-daemon --stdio endpoint";
    shell = nixStoreShellPath;
    useDefaultShell = false;
  };

  environment.etc."ssh/nix-store-shell" = lib.mkIf runtimeMode {
    text = nixStoreShellText;
    mode = "0755";
  };

  environment.shells = lib.mkIf runtimeMode [ nixStoreShellPath ];

  nix.settings.trusted-users = lib.mkIf runtimeMode [ "nix-store" ];

  # root: also accepts linux-builder key for builds that require root-level operations.
  users.users.root.openssh.authorizedKeys.keys = lib.mkIf runtimeMode (
    lib.filter (k: k != "") [
      (
        if builderKeys ? linux-builder && builderKeys.linux-builder ? public then
          "ssh-ed25519 ${builderKeys.linux-builder.public} committed-linux-builder"
        else
          ""
      )
    ]
  );
}
