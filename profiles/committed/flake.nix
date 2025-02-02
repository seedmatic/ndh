{
  description = "Committed profile for nix-darwin";

  inputs = {
    nxmatic-flake-commons.url = "github:nxmatic/nix-flake-commons/develop";
    flake-compat.follows = "nxmatic-flake-commons/flake-compat";
    flake-utils.follows = "nxmatic-flake-commons/flake-utils";
    nix.follows = "nxmatic-flake-commons/nix";
    nixos-hardware.follows = "nxmatic-flake-commons/nixos-hardware";
    nixpkgs.follows = "nxmatic-flake-commons/nixpkgs";
    home-manager.follows = "nxmatic-flake-commons/home-manager";
    cachix.follows = "nxmatic-flake-commons/cachix";
    darwin.follows = "nxmatic-flake-commons/darwin";
    devenv.follows = "nxmatic-flake-commons/devenv";
    home.url = "path:../..";
    socket-vmnet.follows = "nxmatic-flake-commons/socket-vmnet";
  };

  outputs =
    {
      self,
      darwin,
      devenv,
      flake-utils,
      home-manager,
      nixpkgs,
      home,
      ...
    }@inputs:
    let
      tailnet = {
        name = "mammoth-skate";
        domain = "ts.net";
      };

      host = {
        inherit tailnet;

        name = "bioskop";
      };

      user = {
        name = "nxmatic";
        email = "stephane.lacoin@gmail.com";
        description = "Stephane Lacoin (aka nxmatic)";
        home = builtins.toPath "/Users/nxmatic";
        shell = nixpkgs.legacyPackages.aarch64-darwin.zsh;
      };

      profile = {
        inherit host user;

        name = "committed";
      };

      overlays = home.mkOverlays self;

      packages = home.eachSystemMap home.defaultSystems (system: home.mkPackages overlays system);

      devShells = home.eachSystemMap home.defaultSystems (system: home.mkDevShell overlays system);

    in
    {
      inherit
        profile
        overlays
        packages
        devShells
        ;

      darwinConfigurations = {
        bioskop = (
          home.mkDarwinConfig {
            inherit self profile overlays;

          }
        );
      };
    };
}
