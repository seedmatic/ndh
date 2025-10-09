{
  description = "nix system configurations for alcide";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "APL-dk40njhk9h";
        hostAlias = "alcide";
        tailnet = { };
      };
      darwinProfile = {
        knownNetworkServices = [ "Wi-Fi" "Thunderbolt Ethernet" ];
      };

      profileModule = { pkgs, lib, ... }: {
        imports = [ 
          ../../profiles/work.nix
          # Teleport removed - using Tailscale for external access
        ];
        config = (
          {
            profile = {
              host = {
                hostName = lib.mkDefault hostProfile.hostName;
                hostAlias = lib.mkDefault hostProfile.hostAlias;
                tailnet = hostProfile.tailnet;
              };
              darwin = darwinProfile;
            };
            # Enable cross-host distributed builds (Darwin only)
            services.crossHostBuilders.enable = true;
          }
        );
      };
    in nix-darwin-home.mkHostOutputs { inherit hostProfile profileModule; };
}
