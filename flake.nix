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
    nixpkgs-develop.follows = "nxmatic-flake-commons/nixpkgs-develop";
    nixpkgs-staging.follows = "nxmatic-flake-commons/nixpkgs-staging";

    cachix.follows = "nxmatic-flake-commons/cachix";
    darwin.follows = "nxmatic-flake-commons/darwin";
    devenv.follows = "nxmatic-flake-commons/devenv";
    flox.follows = "nxmatic-flake-commons/flox";

    treefmt-nix.url = "github:numtide/treefmt-nix";

    bird.follows = "nxmatic-flake-commons/bird";
    maven-mvnd.follows = "nxmatic-flake-commons/maven-mvnd";
    socket-vmnet.follows = "nxmatic-flake-commons/socket-vmnet";
    zen-browser.follows = "nxmatic-flake-commons/zen-browser";
  };

  outputs = {
    self,
    darwin,
    devenv,
    flake-utils,
    home-manager,
    socket-vmnet,
    nixpkgs,
    ...
  } @ inputs: let
    inherit (flake-utils.lib) eachSystemMap;
    isDarwin = system: builtins.elem system nixpkgs.lib.platforms.darwin;
    homePrefix = system:
      if isDarwin system
      then "/Users"
      else "/home";
    defaultSystems = ["aarch64-darwin" "x86_64-darwin" "x86_64-linux"];

    # Helper function to generate a set of attributes for each system
    forAllSystems = nixpkgs.lib.genAttrs defaultSystems;

    # Import nixpkgs with overlays and config for each system
    pkgsFor = forAllSystems (system: let
      # Import base packages with specific configurations
      basePackages = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          allowBroken = true;
          checkAllPackages = false;
        };
      };

      # Create an overlay that includes Flox packages
      floxOverlay = final: prev:
        if inputs.flox.packages ? ${system}
        then inputs.flox.packages.${system}
        else throw "Flox packages not defined for ${system}";

      overlays = builtins.map (name: let
        overlay = self.overlays.${name} inputs;
      in
        final: prev:
          builtins.traceVerbose "Applying overlay: ${name}"
          (overlay final prev)) (builtins.attrNames self.overlays);

      applyOverlays = final: prev:
        builtins.foldl' (acc: overlay: (acc // (overlay final prev))) {}
        overlays;

      tracePackages = pkgs:
        builtins.mapAttrs
        (name: pkg: builtins.traceVerbose "Processing package: ${name}" pkg)
        pkgs;
    in
      basePackages.extend (final: prev:
        tracePackages
        (
          (floxOverlay final prev)
          // (applyOverlays final prev)
        )));

    profiles = [
      {
        name = "work";
        username = "stephane.lacoin";
      }
      {
        name = "committed";
        username = "nxmatic";
      }
    ];

    mkDarwinConfig = {
      profilename,
      system ? "aarch64-darwin",
      nixpkgs ? inputs.nixpkgs,
      baseModules ? [
        #       inputs.zen-browser.darwinModule
        socket-vmnet.darwinModules.socket_vmnet
        home-manager.darwinModules.home-manager
        ./modules/darwin
      ],
      extraModules ? [
        "./profiles/darwin/${profilename}.nix"
      ],
    }: let
      debugModule = {
        config,
        pkgs,
        ...
      }: {
        _file = "debugModule";
        config = {
          system.activationScripts.debug.text = ''
            echo "Debug: activationScripts is being executed"
            echo "docker-compose version: ${pkgs.docker-compose.version}"
          '';
        };
      };
    in
      builtins.traceVerbose "Starting darwinSystem evaluation"
      (inputs.darwin.lib.darwinSystem {
        inherit system;
        pkgs = pkgsFor.${system};
        modules =
          builtins.traceVerbose "Combining modules"
          (baseModules ++ extraModules ++ [debugModule]);
        specialArgs = builtins.traceVerbose "Setting specialArgs" {
          inherit self inputs nixpkgs;
        };
      });

    mkHomeConfig = {
      profilename,
      username,
      system,
      nixpkgs ? inputs.nixpkgs,
      baseModules ? [
        ./modules/home-manager
        {
          home = {
            inherit username;
            homeDirectory = "${homePrefix system}/${username}";
          };
        }
      ],
      extraModules ? [
        "./profiles/home-manager/${profilename}.nix"
      ],
    }:
      inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = pkgsFor.${system};
        modules =
          baseModules
          ++ extraModules
          ++ [
            {
              nixpkgs.config = {
                allowUnfree = true;
                allowBroken = true;
                checkAllPackages = false;
              };
            }
          ];
        extraSpecialArgs = {inherit self inputs nixpkgs;};
      };

    darwinConfigurations = builtins.listToAttrs (map (profile: {
        name = "${profile.name}";
        value = mkDarwinConfig {
          profilename = profile.profilename;
          system = "aarch64-darwin";
          extraModules = [./profiles/darwin/${profile.name}.nix];
        };
      })
      profiles);

    homeConfigurations = builtins.listToAttrs (map (profile: {
        name = "${profile.name}";
        value = mkHomeConfig {
          profilename = profile.profilename;
          username = profile.username;
          system = "aarch64-darwin";
          extraModules = [./profiles/home-manager/${profile.name}.nix];
        };
      })
      profiles);
  in {
    darwinConfigurations = darwinConfigurations;
    homeConfigurations = homeConfigurations;

    devShells = eachSystemMap defaultSystems (system: {
      default = devenv.lib.mkShell {
        inherit inputs;
        pkgs = pkgsFor.${system};
        modules = [(import ./devenv.nix)];
      };
    });

    packages = eachSystemMap defaultSystems (system: let
      pkgs = pkgsFor.${system};
    in {
      pyEnv =
        pkgs.python3.withPackages
        (ps: with ps; [black typer colorama shellingham]);
      sysdo = pkgs.writeScriptBin "sysdo" ''
        #! ${pkgs.python3}/bin/python3
        ${builtins.readFile ./bin/do.py}
      '';
      #       maven-mvnd-m39 = inputs.maven-mvnd.packages.${system}.maven-mvnd-m39;
      #       maven-mvnd-m40 = inputs.maven-mvnd.packages.${system}.maven-mvnd-m40;
    });

    overlays = {
      channels = inputs: final: prev: {
        nixpkgs = import inputs.nixpkgs {system = prev.system;};
      };

      extraPackages = inputs: final: prev: {
        inherit (self.packages.${prev.system}) sysdo pyEnv;
        inherit (inputs.devenv.packages.${prev.system}) devenv;
        inherit
          (inputs.maven-mvnd.packages.${prev.system})
          maven-mvnd-m39
          maven-mvnd-m40
          ;
        inherit (inputs.socket-vmnet.packages.${prev.system}) socket_vmnet;
      };

      birdOverlay = inputs: import ./overlays/bird.nix inputs;

      floxOverlay = inputs: import ./overlays/flox.nix inputs;

      # zenBrowserOverlay = inputs: import ./overlays/zen-browser.nix inputs;
    };
  };
}
