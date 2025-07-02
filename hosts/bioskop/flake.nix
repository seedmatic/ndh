{
  description = "nix system configurations for bioskop";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      limaHostName = "bioskop";
      profileModule = { config, lib, pkgs, ... }: {
        imports = [ ../../profiles/committed.nix ];
        config = { profile = { host.name = limaHostName; }; };
      };
    in nix-darwin-home.mkHostOutputs { inherit limaHostName profileModule; };
}
