{
  description = "nix system configurations for alcide";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = { hostName = "bioskop"; };
      darwinProfile = {
        knownNetworkServices = [ "Wi-Fi" "Ethernet Adaptor" "Thunderbolt Ethernet" ];
      };
      profileModule = { config, lib, pkgs, ... }: {
        imports = [ ../../profiles/committed.nix ];
        config = {
          profile = {
            host = hostProfile;
            darwin = darwinProfile;
          };
        };
      };
    in nix-darwin-home.mkHostOutputs { inherit hostProfile profileModule; };
}
