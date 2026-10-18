{ config, lib, ... }:
{
  config = {
    # Darwin policy: keep activation-script path for sops and use system sudo path. Every darwin host decrypts
    # with its own ssh host key alone (sops.age.sshKeyPaths, a recipient of the files it reads): no age key
    # file, so neither the operator's personal key nor identities nothing records are a machine's identity.
    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = lib.mkDefault null;
      sudoCommand = lib.mkDefault "/usr/bin/sudo";
    };

    assertions = [
      {
        assertion = config.sops.age.keyFile == null && config.sops.age.sshKeyPaths != [ ];
        message = ''
          ${config.networking.hostName}'s sops identity must be its ssh host key alone (sops.age.sshKeyPaths =
          ${toString config.sops.age.sshKeyPaths}), with no sops.age.keyFile (${toString config.sops.age.keyFile}).
        '';
      }
    ];
  };
}
