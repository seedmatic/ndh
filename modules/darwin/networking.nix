{ config, ... }: {
  config = {
    # Ensure all configuration attributes are within the config attribute
    networking = {
      dns = [ "100.100.100.100" "8.8.8.8" "1.1.1.1" "1.0.0.1" "8.8.4.4" ];
      knownNetworkServices = config.profile.darwin.knownNetworkServices;
    };
  };
}
