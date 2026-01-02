{ config, lib, ... }:
let
  hostProfile = config.profile.host;
  # Use hostAlias if set, otherwise fall back to hostName
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;
in
{
  config = {
    # Ensure all configuration attributes are within the config attribute
    networking = {
      # Set the computer name (what shows in Finder and System Preferences)
      computerName = lib.mkDefault effectiveHostName;

      # Set the hostname (returned by `hostname` command)
      hostName = lib.mkDefault effectiveHostName;

      # Set the Bonjour/mDNS local hostname (without .local suffix)
      # This enables mDNS publishing as <localHostName>.local
      localHostName = lib.mkDefault effectiveHostName;

      dns = [
        "100.100.100.100"
        "8.8.8.8"
        "2001:4860:4860::8888"
        "1.1.1.1"
        "2606:4700:4700::1111"
        "1.0.0.1"
        "8.8.4.4"
        "2001:4860:4860::8844"
      ];
      knownNetworkServices = config.profile.darwin.knownNetworkServices;
    };
  };
}
