{
  description = "nix system configurations for alcide";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "APL-dk40njhk9h";
        hostAlias = "alcide";
      };
      darwinProfile = {
        knownNetworkServices = [ "Wi-Fi" "Thunderbolt Ethernet" ];
      };
      profileModule = { ... }: {
        imports = [ ../../profiles/work.nix ];
        config = { profile = { host = hostProfile; darwin = darwinProfile; }; };
      };
    in nix-darwin-home.mkHostOutputs { inherit hostProfile profileModule; };
}
