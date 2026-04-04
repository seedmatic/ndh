{ config, lib, ... }:
{
  config = {
    # Darwin policy: keep activation-script path for sops and use system sudo path.
    nxmatic.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = lib.mkDefault (
        if config.nxmatic.sopsAgeKeyBootstrap.darwinSystemWideKey then
          config.nxmatic.sopsAgeKeyBootstrap.systemWideKeyFile
        else
          config.nxmatic.sopsAgeKeyBootstrap.darwinUserKeyFile
      );
      sudoCommand = lib.mkDefault "/usr/bin/sudo";
    };

    activation.loggerCmd = lib.mkDefault "/usr/bin/logger -p notice -t %TAG%";
  };
}