{
  description = "nix system configurations for alcide";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      limaHostName = "alcide";
      profileModule = { config, lib, pkgs, ... }: {
        imports = [ ../../profiles/work.nix ];
        config = { profile = { host.name = limaHostName; }; };
      };
    in nix-darwin-home.mkHostOutputs { inherit limaHostName profileModule; };
}
