{
  description = "nix system configurations";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://cache.flox.dev"
      "https://nxmatic.cachix.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
      "nxmatic.cachix.org-1:huMghYiwDpPa1PMXHXK4G1Dp4QOZjgsNqxcjf/AjuJ0="
    ];
  };

  inputs = {
    nxmatic-flake-commons.url = "github:nxmatic/nix-flake-commons/develop";
    flake-compat.follows = "nxmatic-flake-commons/flake-compat";
    flake-utils.follows = "nxmatic-flake-commons/flake-utils";
    nix.follows = "nxmatic-flake-commons/nix";
    nixos-hardware.follows = "nxmatic-flake-commons/nixos-hardware";
    nixpkgs.follows = "nxmatic-flake-commons/nixpkgs";
    cachix.follows = "nxmatic-flake-commons/cachix";
    darwin.follows = "nxmatic-flake-commons/darwin";
    home-manager.follows = "nxmatic-flake-commons/home-manager";
    devenv.follows = "nxmatic-flake-commons/devenv";
    flox.follows = "nxmatic-flake-commons/flox";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    bird.follows = "nxmatic-flake-commons/bird";
    maven-mvnd.follows = "nxmatic-flake-commons/maven-mvnd";
    socket-vmnet.follows = "nxmatic-flake-commons/socket-vmnet";
    zen-browser.follows = "nxmatic-flake-commons/zen-browser";
    ripvcs.follows = "nxmatic-flake-commons/ripvcs";
  };

  outputs =
    {
      self,
      darwin,
      devenv,
      flake-utils,
      home-manager,
      socket-vmnet,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (flake-utils.lib) eachSystemMap;
      defaultSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs defaultSystems;

      pkgsFor = forAllSystems (
        system:
        let
          basePackages = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              allowBroken = true;
              checkAllPackages = false;
            };
          };

          floxOverlay =
            final: prev:
            if inputs.flox.packages ? ${system} then
              inputs.flox.packages.${system}
            else
              throw "Flox packages not defined for ${system}";

          ripvcsOverlay =
            final: prev:
            if inputs.ripvcs.packages ? ${system} then
              inputs.ripvcs.packages.${system}
            else
              throw "Ripvcs packages not defined for ${system}";

          overlays = builtins.map (
            name:
            let
              overlay = self.overlays.${name} inputs;
            in
            final: prev: overlay final prev
          ) (builtins.attrNames self.overlays);

          applyOverlays =
            final: prev: builtins.foldl' (acc: overlay: (acc // (overlay final prev))) { } overlays;

        in
        basePackages.extend (
          final: prev: (floxOverlay final prev) // (ripvcsOverlay final prev) // (applyOverlays final prev)
        )
      );

      mkDarwinConfig =
        {
          profileName,
          system,
          nixpkgs ? inputs.nixpkgs,
          baseModules ? [
            socket-vmnet.darwinModules.socket_vmnet
            home-manager.darwinModules.home-manager
            ./modules/darwin
          ],
          extraModules ? [ ],
        }:
        let
          profileModule = import ./modules/home-manager/profiles/${profileName}.nix;
          debugModule =
            {
              config,
              pkgs,
              ...
            }:
            {
              _file = "debugModule";
              config = {
                system.activationScripts.debug.text = ''
                  echo "Debug: activationScripts is being executed"
                  echo "docker-compose version: ${pkgs.docker-compose.version}"
                '';
              };
            };
          combinedModules =
            baseModules
            ++ extraModules
            ++ [
              profileModule
              debugModule
            ];
        in
        inputs.darwin.lib.darwinSystem {
          inherit system;
          pkgs = pkgsFor.${system};
          modules = combinedModules;

          specialArgs =
            let
              profile = profileModule.config.profile;
            in
            {
              inherit
                self
                inputs
                nixpkgs
                profile
                ;
              lib = inputs.nixpkgs.lib.extend (
                _: _:
                inputs.home-manager.lib
                // {
                  # Any additional lib functions you want to include
                }
              );
            };
        };

      darwinConfigurations = builtins.listToAttrs (
        map
          (profileName: {
            name = profileName;
            value = mkDarwinConfig {
              profileName = profileName;
              system = "aarch64-darwin";
            };
          })
          [
            "work"
            "committed"
          ]
      );

    in
    {
      inherit darwinConfigurations;

      devShells = eachSystemMap defaultSystems (system: {
        default = devenv.lib.mkShell {
          inherit inputs;
          pkgs = pkgsFor.${system};
          modules = [ (import ./devenv.nix) ];
        };
      });

      packages = eachSystemMap defaultSystems (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          pyEnv = pkgs.python3.withPackages (
            ps: with ps; [
              black
              typer
              colorama
              shellingham
            ]
          );
          sysdo = pkgs.writeScriptBin "sysdo" ''
            #! ${pkgs.python3}/bin/python3
            ${builtins.readFile ./bin/do.py}
          '';
          qemu-pkgdb = pkgs.qemu-pkgdb;
        }
      );

      overlays = {
        channels = inputs: final: prev: {
          nixpkgs = import inputs.nixpkgs { system = prev.system; };
        };

        extraPackages = inputs: final: prev: {
          inherit (self.packages.${prev.system}) sysdo pyEnv;
          inherit (inputs.devenv.packages.${prev.system}) devenv;
        };

        birdOverlay = inputs: import ./overlays/bird.nix inputs;

        floxOverlay = inputs: import ./overlays/flox.nix inputs;

        qemuOverlay = inputs: import ./overlays/qemu.nix inputs;
      };
    };
}
