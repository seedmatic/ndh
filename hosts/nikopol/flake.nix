{
  description = "nix system configurations for nikopol";

  inputs = {
    nix-darwin-home.url = "path:../..";
  };

  outputs =
    { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "nikopol";
        tailnet = { };
      };
      darwinProfile = {
        knownNetworkServices = [
          "Wi-Fi"
          "Thunderbolt Ethernet"
        ];
      };

      profileModule =
        {
          pkgs,
          lib,
          config,
          ...
        }:
        {
          imports = [
            ../../profiles/committed.nix
          ];
          config = {
            profile = {
              host = {
                hostName = lib.mkDefault hostProfile.hostName;
                tailnet = hostProfile.tailnet;
              }
              // (
                if hostProfile ? hostAlias then
                  {
                    hostAlias = lib.mkDefault hostProfile.hostAlias;
                  }
                else
                  { }
              );
              darwin = darwinProfile;
            };

            services.headscale-client = {
              enable = true;
              serverUrl = "http://192.168.1.193:8080";
              enableSSH = true;
            };
          };
        };
    in
    nix-darwin-home.mkHostOutputs {
      inherit hostProfile profileModule;
    };
}
