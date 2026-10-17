{
  config,
  lib,
  pkgs,
  catalog,
  ...
}:
# ndh-identity-receive on every darwin host, and ndh-identity-push on the seat holding the keyring, which gives the
# inventory's machines their identities and itself its host key: a gesture of the operator with the keyring open
# (docs/ssh-keys-architecture.adoc). Never run by the activation.
let
  cfg = config.ndh.identityPush;
  identityPush = import ../.common.d/identity-push.d/package.nix { inherit pkgs lib; };
  # No keyFile: the seat's sops keyFile still holds the retired identities that roles × keys S4/S8 replace once
  # every file is re-keyed, so the seat's frame carries its host key only.
  receive = identityPush.receive {
    machine = config.networking.hostName;
    keyFile = "";
    sshfs = false;
    served = lib.head config.opensshPolicy.hostKeyPaths;
    owner = "root:wheel";
  };
in
{
  options.ndh.identityPush.enable = lib.mkEnableOption "ndh-identity-push on this operator seat (the one holding the keyring)";

  config = lib.mkMerge [
    {
      # The keyring seat reaches this host's receive over ssh (roles × keys ④): sudo -n, by its fixed path, for that
      # one command and nothing else.
      environment.systemPackages = [ receive ];
      security.sudo.extraConfig = ''
        ${config.profile.user.name} ALL=(root) NOPASSWD: /run/current-system/sw/bin/ndh-identity-receive --accept
      '';
    }
    (lib.mkIf cfg.enable {
      environment.systemPackages = [
        (identityPush.push {
          seat = config.networking.hostName;
          netplan = catalog.netplan;
          operatorIdentity = {
            user = config.profile.user.name;
            keyFile = config.sshPaths.privKeyFile;
            certFile = config.sshPaths.userCertPublic;
          };
          inherit receive;
        })
      ];
    })
  ];
}
