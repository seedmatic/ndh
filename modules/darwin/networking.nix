{ config, ... }: {
  config = {
    # Ensure all configuration attributes are within the config attribute
    networking = {
      dns = [ 
        "100.100.100.100"
         "8.8.8.8" "2001:4860:4860::8888" 
         "1.1.1.1" "2606:4700:4700::1111" 
         "1.0.0.1" 
         "8.8.4.4" "2001:4860:4860::8844"
      ];
      knownNetworkServices = config.profile.darwin.knownNetworkServices;
    };
  };
}
