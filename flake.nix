{
  description = "nix system configurations";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://kclejeune.cachix.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "kclejeune.cachix.org-1:fOCrECygdFZKbMxHClhiTS6oowOkJ/I/dh9q9b1I4ko="
    ];
  };

  inputs = {
    # package repos
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.05";

    # system management
    nixos-hardware.url = "github:nixos/nixos-hardware";
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # home manager
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # devenv
    devenv.url = "github:cachix/devenv/latest";

    # shell stuff
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    # bird fork
    bird-fork = {
      type = "github";
      owner = "nxmatic";
      repo = "bird";
      ref = "hotfix/v2.15.1-nix-darwin";
      flake = false;
    };

    # nvim git plugins
    packer-nvim = {
      type = "github";
      owner = "wbthomason";
      repo = "packer.nvim";
      flake = false;
    };

    # maven-mvnd
    maven-mvnd = {
      type = "github";
      owner = "nxmatic";
      repo = "nix-maven-mvnd";
      ref = "refs/heads/develop";
      flake = true;
    };
  };

  outputs = {
    self,
    darwin,
    devenv,
    flake-utils,
    home-manager,
    ...
  } @ inputs: let
    inherit (flake-utils.lib) eachSystemMap;

    isDarwin = system: (builtins.elem system inputs.nixpkgs.lib.platforms.darwin);

    homePrefix = system:
      if isDarwin system
      then "/Users"
      else "/home";

    defaultSystems = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
    ];

    # generate a base darwin configuration with the
    # specified hostname, overlays, and any extraModules applied
    mkDarwinConfig = {
      system ? "aarch64-darwin",
      nixpkgs ? inputs.nixpkgs,
      baseModules ? [
        home-manager.darwinModules.home-manager
        ./modules/darwin
      ],
      extraModules ? [],
    }:
      inputs.darwin.lib.darwinSystem {
        inherit system;
        modules = baseModules ++ extraModules;
        specialArgs = {inherit self inputs nixpkgs;};
      };

    # generate a base nixos configuration with the
    # specified overlays, hardware modules, and any extraModules applied

    # generate a home-manager configuration usable on any unix system
    # with overlays and any extraModules applied
    mkHomeConfig = {
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
      extraModules ? [],
    }:
      inputs.home-manager.lib.homeManagerConfiguration rec {
        pkgs = import nixpkgs {
          inherit system;
          overlays = builtins.attrValues self.overlays;
        };
        extraSpecialArgs = {inherit self inputs nixpkgs;};
        modules = baseModules ++ extraModules;
      };

    mkChecks = {
      arch,
      os,
      username ? "nxmatic",
      profile ? "work",
    }: {
      "${arch}-${os}" = {
        "${username}_${os}" =
          (
            if os == "darwin"
            then self.darwinConfigurations
            else self.nixosConfigurations
          )
          ."${profile}@${arch}-${os}"
          .config
          .system
          .build
          .toplevel;
        "${username}_home" =
          self.homeConfigurations."${profile}@${arch}-${os}".activationPackage;
        devShell = self.devShells."${arch}-${os}".default;
      };
    };
  in {
    checks =
      {}
      // (mkChecks {
        arch = "aarch64";
        os = "darwin";
        profile = "work";
      });
    # // (mkChecks {
    #   arch = "x86_64";
    #   os = "linux";
    #   profile = "committed";
    # });

    darwinConfigurations = {
      "work@aarch64-darwin" = mkDarwinConfig {
        system = "aarch64-darwin";
        extraModules = [
          ./profiles/darwin/work.nix
        ];
      };
      # "committed@aarch64-darwin" = mkDarwinConfig {
      #   system = "aarch64-darwin";
      #   extraModules = [
      #     ./profiles/darwin/committed.nix
      #   ];
      # };
    };

    homeConfigurations = {
      "work@aarch64-darwin" = mkHomeConfig {
        username = "stephane.lacoin";
        system = "aarch64-darwin";
        profile = "work";
        extraModules = [
          ./profiles/home-manager/work.nix
        ];
      };
      # "committed@aarch64-darwin" = mkHomeConfig {
      #   username = "nxmatic";
      #   system = "aarch64-darwin";
      #   profile = "committed";
      #   extraModules = [
      #     ./profiles/home-manager/committed.nix
      #   ];
      # };
    };

    devShells = eachSystemMap defaultSystems (
      system: let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = builtins.attrValues self.overlays;
        };
      in {
        default = devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            (import ./devenv.nix)
          ];
        };
      }
    );

    packages = eachSystemMap defaultSystems (system: let
      pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = builtins.attrValues self.overlays;
      };
    in rec {
      pyEnv =
        pkgs.python3.withPackages
        (ps: with ps; [black typer colorama shellingham]);
      sysdo = pkgs.writeScriptBin "sysdo" ''
        #! ${pyEnv}/bin/python3
        ${builtins.readFile ./bin/do.py}
      '';
      maven-mvnd-m39 = inputs.maven-mvnd.packages.${system}.maven-mvnd-m39;
      maven-mvnd-m40 = inputs.maven-mvnd.packages.${system}.maven-mvnd-m40;
    });

    apps = eachSystemMap defaultSystems (system: rec {
      sysdo = {
        type = "app";
        program = "${self.packages.${system}.sysdo}/bin/sysdo";
      };
      default = sysdo;
    });

    overlays = {
      channels = final: prev: {
        # expose other channels via overlays
        nixpkgs = import inputs.nixpkgs {system = prev.system;};
      };
      extraPackages = final: prev: {
        sysdo = self.packages.${prev.system}.sysdo;
        pyEnv = self.packages.${prev.system}.pyEnv;
        devenv = self.packages.${prev.system}.devenv;
        maven-mvnd-m39 = self.packages.${prev.system}.maven-mvnd-m39;
        maven-mvnd-m40 = self.packages.${prev.system}.maven-mvnd-m40;
      };
    };
  };
}
