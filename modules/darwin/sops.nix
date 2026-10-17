{ config, lib, ... }:
{
  config = {
    # Darwin policy: keep activation-script path for sops and use system sudo path. A host serving its own
    # host key decrypts with it alone (openssh.nix's sops.age.sshKeyPaths): no age key file, which could
    # hold identities nothing records.
    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = lib.mkDefault (
        if config.ndh.hostKey.own then null else config.ndh.sopsAgeKeyBootstrap.darwinUserKeyFile
      );
      sudoCommand = lib.mkDefault "/usr/bin/sudo";
    };

    assertions = [
      {
        assertion = config.ndh.hostKey.own -> config.sops.age.keyFile == null;
        message = ''
          ${config.networking.hostName} serves its own host key, so its sops identity is that key alone
          (sops.age.sshKeyPaths), but sops.age.keyFile is set to ${toString config.sops.age.keyFile}.
        '';
      }
    ];
  };
}
