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
        knownNetworkServices = [ "Wi-Fi" "Ethernet Adaptor""Thunderbolt Ethernet" ];
      };

      profileModule = { pkgs, ... }: {
        imports = [ ../../profiles/committed.nix ];
        config = {
          profile = {
            host = hostProfile;
            darwin = darwinProfile;
          };
          # Enable cross-host distributed builds (Darwin only)
          services.crossHostBuilders.enable = true;
        };
      };
    in nix-darwin-home.mkHostOutputs { inherit hostProfile profileModule; };
}
