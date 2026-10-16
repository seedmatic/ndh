{
  config,
  lib,
  pkgs,
  catalog,
  ...
}:
# ndh-identity-push on the operator seat's PATH: the operator seat gives its guest its identities, a gesture of the
# operator with the keyring open (docs/ssh-keys-architecture.adoc). Never run by the activation.
let
  cfg = config.ndh.identityPush;
in
{
  options.ndh.identityPush.enable = lib.mkEnableOption "ndh-identity-push on this operator seat (the one holding the keyring)";

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      ((import ../.common.d/identity-push.d/package.nix { inherit pkgs lib; }).push {
        seat = config.networking.hostName;
        netplan = catalog.netplan;
        operatorIdentity = {
          user = config.profile.user.name;
          keyFile = config.sshPaths.privKeyFile;
          certFile = config.sshPaths.userCertPublic;
        };
      })
    ];
  };
}
