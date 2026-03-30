# Shared sops-nix defaults for Darwin and NixOS hosts (@codebase)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  userHome =
    if config ? profile && config.profile ? user && config.profile.user ? home then
      toString config.profile.user.home
    else
      "/var/empty";
in
{
  config = {
    sops = {
      # Canonical encrypted secrets source tracked in this repository.
      defaultSopsFile = lib.mkDefault ../../.secrets;

      age.keyFile = lib.mkDefault (
        if pkgs.stdenv.isDarwin then
          "${userHome}/.config/sops/age/keys.txt"
        else
          "/etc/sops/age/keys.txt"
      );

      # Canonical runtime path for SSH key material used by home-manager activation.
      # Keep decrypted content out of derivation outputs; consume via .path at activation.
      secrets.nxmatic-ssh-keys-yaml = {
        format = "binary";
        sopsFile = ../../modules/home-manager/ssh.d/keys.yaml;
        mode = "0400";
        owner = lib.mkDefault (if config ? profile && config.profile ? user then config.profile.user.name else "root");
      };
    };
  };
}
