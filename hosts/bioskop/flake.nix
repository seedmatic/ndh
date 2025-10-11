{
  description = "nix system configurations for bioskop";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "bioskop";
        tailnet = { };
      };
      darwinProfile = {
        knownNetworkServices = [ "Wi-Fi" "Ethernet Adaptor" "Thunderbolt Ethernet" ];
      };

      profileModule = { pkgs, lib, ... }: {
        imports = [ 
          ../../profiles/committed.nix
          # Teleport removed - using Headscale for internal network
        ];
        config = (
          {
            profile = {
              host = {
                hostName = lib.mkDefault hostProfile.hostName;
                tailnet = hostProfile.tailnet;
              } // (if hostProfile ? hostAlias then {
                hostAlias = lib.mkDefault hostProfile.hostAlias;
              } else {});
              darwin = darwinProfile;
            };

            # Headscale client - connects to server in Lima VM
            # Note: Server must be deployed first at 192.168.5.10:8080
            services.headscale-client = {
              enable = true;
              serverUrl = "http://192.168.5.10:8080";
              enableSSH = true;
            };
            
            # Enable cross-host distributed builds (Darwin only)
            services.crossHostBuilders.enable = true;
          }
        );
      };
    in nix-darwin-home.mkHostOutputs { inherit hostProfile profileModule; };
}
