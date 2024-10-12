{
  description = "nix system configurations";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://kclejeune.cachix.org"
      "https://cache.flox.dev"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "kclejeuneachix.org-1:fOCrECygdFZKbMxHClhiTS6oowOkJ/I/dh9q9b1I4ko="
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-24.05";
    nixos-hardware.url = "github:nixos/nixos-hardware";
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devenv.url = "github:cachix/devenv/latest";
    flox = {
      url = "github:nxmatic/flox?ref=hotfix/nix-remove-attrcursor-force-errors";
      inputs.nixpkgs.follows = "nixpkgs";
      #     flake = true;
    };
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    bird = {
      url = "github:nxmatic/bird?ref=hotfix/v2.15.1-nix-darwin";
      flake = true;
    };
    maven-mvnd = {
      url = "github:nxmatic/nix-maven-mvnd/develop";
      flake = true;
    };
  };

  outputs = {
    self,
    darwin,
    devenv,
    flake-utils,
    home-manager,
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

    mkDarwinConfig = {
      system ? "aarch64-darwin",
      nixpkgs ? inputs.nixpkgs,
      baseModules ? [home-manager.darwinModules.home-manager ./modules/darwin],
      extraModules ? [],
    }:
      inputs.darwin.lib.darwinSystem {
        inherit system;
        modules = baseModules ++ extraModules;
        specialArgs = {inherit self inputs nixpkgs;};
        pkgs = import nixpkgs {
          inherit system;
          overlays = [self.overlays.floxOverlay self.overlays.birdOverlay] ++ builtins.attrValues self.overlays;
        };
      };

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
      inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = import nixpkgs {
          inherit system;
          overlays = [self.overlays.floxOverlay] ++ builtins.attrValues self.overlays;
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
        "${username}_home" = self.homeConfigurations."${profile}@${arch}-${os}".activationPackage;
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

    darwinConfigurations."work@aarch64-darwin" = mkDarwinConfig {
      system = "aarch64-darwin";
      extraModules = [./profiles/darwin/work.nix];
    };

    homeConfigurations."work@aarch64-darwin" = mkHomeConfig {
      username = "stephane.lacoin";
      system = "aarch64-darwin";
      profile = "work";
      extraModules = [./profiles/home-manager/work.nix];
    };

    devShells = eachSystemMap defaultSystems (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [self.overlays.floxOverlay];
        };
      in {
        default = devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [(import ./devenv.nix)];
        };
      }
    );

    packages = eachSystemMap defaultSystems (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [self.overlays.floxOverlay];
        };
      in {
        pyEnv = pkgs.python3.withPackages (ps: with ps; [black typer colorama shellingham]);
        sysdo = pkgs.writeScriptBin "sysdo" ''
          #! ${pkgs.python3}/bin/python3
          ${builtins.readFile ./bin/do.py}
        '';
        maven-mvnd-m39 = inputs.maven-mvnd.packages.${system}.maven-mvnd-m39;
        maven-mvnd-m40 = inputs.maven-mvnd.packages.${system}.maven-mvnd-m40;
      }
    );

    overlays = {
      channels = final: prev: {
        nixpkgs = import inputs.nixpkgs {system = prev.system;};
      };

      extraPackages = final: prev: {
        inherit (self.packages.${prev.system}) sysdo pyEnv;
        inherit (inputs.devenv.packages.${prev.system}) devenv;
        inherit (inputs.maven-mvnd.packages.${prev.system}) maven-mvnd-m39 maven-mvnd-m40;
      };

      birdOverlay = final: prev: {
        bird = let
          birdPkg = inputs.bird.packages.${prev.system}.default;
        in
          builtins.trace "Bird package: ${builtins.toJSON birdPkg.meta}, sysioMd5sum: ${birdPkg.passthru.sysioMd5sum}"
          birdPkg;
      };

      floxOverlay = final: prev: {
        flox-pkgdb =
          builtins.trace "Applying flox overlay"
          (prev.flox.overrideAttrs (oldAttrs: {
            patches = (oldAttrs.patches or []) ++ [./flox-maybeGetAttr.patch];
            prePatch = ''
              ${oldAttrs.prePatch or ""}
              echo "Starting prePatch phase"
            '';
            postPatch = ''
              ${oldAttrs.postPatch or ""}
              echo "Starting postPatch phase"
              echo "Content of src/buildenv/realise.cc after patching:"
              cat src/buildenv/realise.cc
              echo "Ending postPatch phase"
            '';
            postUnpack = ''
              ${oldAttrs.postUnpack or ""}
              echo "Starting postUnpack phase"
              echo "Current directory: $(pwd)"
              ls -la
            '';
            # Force a rebuild by changing the version
            version = "${oldAttrs.version}-patched";
          }))
          .override {
            nix = final.nix; # Ensure we're using the latest nix from the final set
          };
      };
    };
  };
}
