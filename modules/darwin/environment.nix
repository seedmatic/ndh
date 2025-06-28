{ config, lib, pkgs, ... }: {
  config = {
    environment = { };

    # Example configuration
    services.openssh.enable = true;

    # Ensure no recursive reference to config.config
    # If you need to reference config, do it correctly
    # For example:
    # someOption = config.someOtherOption;
  };
}
