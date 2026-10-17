# Shared attic pin: the server in the cache containers and the client on every machine take the
# same revision, from nixpkgs-unstable (attic 7a19204d, the one the private-cache spec's source
# facts were read on), while services.atticd comes from stable nixpkgs — the headscale-pkg.nix way.
{
  lib,
  pkgs,
  self,
  ...
}:
let
  unstable = import self.inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config = pkgs.config;
  };
in
{
  options.ndh.atticPkgs = lib.mkOption {
    readOnly = true;
    default = {
      server = unstable.attic-server;
      client = unstable.attic-client;
    };
    description = "attic's server and client, one pin for every consumer.";
  };
}
