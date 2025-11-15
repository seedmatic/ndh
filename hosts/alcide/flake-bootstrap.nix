{
  description = "Bootstrap configuration for alcide - Stage 1: Linux builder only";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "APL-dk40njhk9h";
        hostAlias = "alcide";
        tailnet = { };
      };

      profileModule = { lib, config, pkgs, ... }: {
        imports = [ ./bootstrap.nix ];
      };
    in nix-darwin-home.mkHostOutputs { inherit hostProfile profileModule; };
}
