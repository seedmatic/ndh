{ config, lib, ... }:
{
  config = {
    # Darwin policy: keep activation-script path for sops and use system sudo path.
    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = lib.mkDefault (
        if config.ndh.sopsAgeKeyBootstrap.darwinSystemWideKey then
          config.ndh.sopsAgeKeyBootstrap.systemWideKeyFile
        else
          config.ndh.sopsAgeKeyBootstrap.darwinUserKeyFile
      );
      sudoCommand = lib.mkDefault "/usr/bin/sudo";
    };

    nixBashLogger.cmd = lib.mkDefault "/usr/bin/logger -p notice -t %TAG%";
  };
}
