{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = {
    # Ensure all configuration attributes are within the config attribute
    environment = {
      systemPackages = with pkgs; [
        bfg-repo-cleaner
        nmap
      ];
    };

    # Example configuration
    services.openssh.enable = true;

    # Ensure no recursive reference to config.config
    # If you need to reference config, do it correctly
    # For example:
    # someOption = config.someOtherOption;
  };
}
