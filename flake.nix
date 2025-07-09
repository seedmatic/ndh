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
    flake-commons.url = "github:nxmatic/nix-flake-commons/develop";
    flake-compat.follows = "flake-commons/flake-compat";
    flake-utils.follows = "flake-commons/flake-utils";
    nix.follows = "flake-commons/nix";
    lix-module.follows = "flake-commons/lix-module";
    nixos-hardware.follows = "flake-commons/nixos-hardware";
    nixpkgs.follows = "flake-commons/nixpkgs";
    cachix.follows = "flake-commons/cachix";
    darwin.follows = "flake-commons/darwin";
    home-manager.follows = "flake-commons/home-manager";
    devenv.follows = "flake-commons/devenv";
    flox.follows = "flake-commons/flox";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    bird.follows = "flake-commons/bird";
    maven-mvnd.follows = "flake-commons/maven-mvnd";
    socket-vmnet.follows = "flake-commons/socket-vmnet";
    zen-browser.follows = "flake-commons/zen-browser";
    ripvcs.follows = "flake-commons/ripvcs";
    chromium-bin.follows = "flake-commons/chromium-bin";
    disko.follows = "flake-commons/disko";
    impermanence.follows = "flake-commons/impermanence";
    nixos-generators.follows = "flake-commons/nixos-generators";
    incus-compose.follows = "flake-commons/incus-compose";
  };

  outputs = { self, darwin, devenv, flake-utils, nixos-generators, home-manager
    , disko, socket-vmnet, impermanence, nixpkgs, ... }@inputs:
    let
      inherit (flake-utils.lib) eachSystemMap;
      defaultSystems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" ];

      forAllSystems = nixpkgs.lib.genAttrs defaultSystems;

      pkgsFor = { system, ... }:
        let
          basePackages = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              allowBroken = true;
              checkAllPackages = false;
            };
          };

          vmnetOverlay = final: prev:
            if inputs.socket-vmnet.packages ? ${system} then
              inputs.socket-vmnet.packages.${system}
            else
              throw "Socket VMNet packages not defined for ${system}";

          floxOverlay = final: prev:
            if inputs.flox.packages ? ${system} then
              inputs.flox.packages.${system}
            else
              throw "Flox packages not defined for ${system}";

          ripvcsOverlay = final: prev:
            if inputs.ripvcs.packages ? ${system} then
              inputs.ripvcs.packages.${system}
            else
              throw "Ripvcs packages not defined for ${system}";

          overlays = builtins.map (name:
            let overlay = self.overlays.${name} inputs;
            in final: prev: overlay final prev)
            (builtins.attrNames self.overlays);

          applyOverlays = final: prev:
            builtins.foldl' (acc: overlay: (acc // (overlay final prev))) { }
            overlays;
        in basePackages.extend (final: prev:
          (vmnetOverlay final prev) // (floxOverlay final prev)
          // (ripvcsOverlay final prev) // (applyOverlays final prev));
      pkgsForDarwin = (pkgsFor { system = "aarch64-darwin"; });
      pkgsForLinux = (pkgsFor { system = "aarch64-linux"; });

      mkBaseModulesFor = { hostProfile, system }:
        [{ limaHost.hostName = hostProfile.hostName; }] ++ (if system == "nixos" then [
          disko.nixosModules.disko
          home-manager.nixosModules.home-manager
          impermanence.nixosModules.impermanence
          ./modules/nixos
        ] else if system == "darwin" then
          [
            home-manager.darwinModules.home-manager
            # Only include impermanence if darwinModules exists
          ] ++ (if impermanence ? darwinModules then
            [ impermanence.darwinModules.impermanence ]
          else
            [ ]) ++ [ ./modules/darwin ]
        else
          [ ]);
      mkModulesFor =
        { hostProfile, system, preModules ? [ ], extraModules ? [ ], ... }:
        let baseModules = mkBaseModulesFor { inherit hostProfile system; };
        in preModules ++ baseModules ++ extraModules;
      mkSpecialArgs = { modules, profile, extraArgs ? { }, ... }:
        let
          lib = inputs.nixpkgs.lib.extend (_: _:
            inputs.home-manager.lib // {
              # Any additional lib functions you want to include
            });
        in {
          inherit self profile lib;
          _modules = modules;
          nixpkgsInput = nixpkgs;
        } // extraArgs;

      mkContainerRegistryConfig = { hostProfile, ... }:
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          pkgs = pkgsForLinux;
          modules = [
            ./modules/common/lima-host.nix
            ./modules/nixos/container-host.nix
            ./modules/nixos/caddy.nix
            ./modules/nixos/docker-registry.nix
            ./modules/nixos/tailscale.nix
            ({ config, ... }: {
              limaHost.hostName = hostProfile.hostName;
              containerHost.guestName = "ctreg";
            })
          ];
        };
      mkDarwinConfig = { hostProfile, profileModule }:
        let
          preModules =
            [ profileModule socket-vmnet.darwinModules.socket_vmnet ];
          modules = mkModulesFor {
            inherit hostProfile preModules;
            system = "darwin";
          };
          specialArgs = mkSpecialArgs {
            inherit modules;
            profile = profileModule.config.profile;
          };
        in inputs.darwin.lib.darwinSystem {
          inherit specialArgs modules;
          system = "aarch64-darwin";
          pkgs = pkgsForDarwin.extend (final: prev: {
            chromium-bin =
              inputs.chromium-bin.packages."aarch64-darwin".default;
          });
        };
      mkDarwinOutputs = { hostProfile, profileModule, ... }:
        let
          darwinConfiguration =
            mkDarwinConfig { inherit hostProfile profileModule; };
        in {
          darwinConfigurations = {
            "${hostProfile.hostName}" = darwinConfiguration;
          } // (if builtins.hasAttr "hostAlias" hostProfile then {
            "${hostProfile.hostAlias}" = darwinConfiguration;
          } else
            { });
        };

      mkNixosConfig = { hostProfile, profileModule, zfsOverlays
        , containerRegistryConfiguration }:
        let
          zfsOverlaysModule = { ... }: { zfsOverlays.override = zfsOverlays; };
          nixosTailscaleTagModule = { ... }: { tailscale.tags = [ "nixos" ]; };
          preModules =
            [ profileModule zfsOverlaysModule nixosTailscaleTagModule ];
          modules = mkModulesFor {
            inherit hostProfile preModules;
            system = "nixos";
          };
          specialArgs = mkSpecialArgs {
            inherit modules;
            profile = profileModule.config.profile;
            extraArgs = {
              inherit hostProfile;
              containerRegistrySystem = containerRegistryConfiguration;
            };
          };
          nixosSystem = nixpkgs.lib.nixosSystem {
            inherit modules specialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
          };
        in nixosSystem;
      mkNixosOutputs =
        { hostProfile, profileModule, containerRegistryConfiguration }:
        let
          ext4 = mkNixosConfig {
            inherit hostProfile profileModule containerRegistryConfiguration;
            zfsOverlays = false;
          };
          zfs = mkNixosConfig {
            inherit hostProfile profileModule containerRegistryConfiguration;
            zfsOverlays = true;
          };
          # Disk size in MiB and bytes
          diskSizeMiB = 18 * 1024;
          diskSizeBytes = diskSizeMiB * 1024 * 1024;
          # System closure path
          systemPath = zfs.config.system.build.toplevel;
          # Output a JSON hint with all relevant info for post-build checks
          diskSizeHint = builtins.toJSON {
            systemPath = systemPath;
            diskSizeBytes = diskSizeBytes;
            diskSizeMiB = diskSizeMiB;
            hint = "nix path-info -Sh ${systemPath}";
            note = "closure size should be less than diskSizeBytes";
          };
        in {
          inherit diskSizeHint;
          nixosConfigurations = ({
            inherit ext4 zfs;
            "${hostProfile.hostName}-nixos" = zfs;
          } // (if builtins.hasAttr "hostAlias" hostProfile then {
            "${hostProfile.hostAlias}-nixos" = zfs;
          } else
            { }));
          diskImage = nixos-generators.nixosGenerate {
            modules = [{
              nix.registry.nixpkgs.flake = nixpkgs;
              virtualisation.diskSize = diskSizeMiB;
            }] ++ ext4._module.specialArgs._modules;
            specialArgs = ext4._module.specialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
            format = "raw-efi";
          };
        };
    in {
      mkHostOutputs = { hostProfile, profileModule, ... }:
        let
          darwinOutputs =
            mkDarwinOutputs { inherit hostProfile profileModule; };
          darwinConfiguration =
            darwinOutputs.darwinConfigurations.${hostProfile.hostName};

          containerRegistryConfiguration =
            mkContainerRegistryConfig { inherit hostProfile; };

          nixosOutputs = mkNixosOutputs {
            inherit hostProfile containerRegistryConfiguration profileModule;
          };
          nixosConfiguration =
            nixosOutputs.nixosConfigurations."${hostProfile.hostName}-nixos";
          nixosDiskImage = nixosOutputs.diskImage;
          nixosDiskSizeHint = nixosOutputs.diskSizeHint;
        in nixosOutputs // darwinOutputs // {
          inherit darwinConfiguration nixosConfiguration nixosDiskImage
            nixosDiskSizeHint;
          pkgs = {
            darwin = pkgsForDarwin;
            linux = pkgsForLinux;
          };
          defaultPackage."aarch64-darwin" = darwinConfiguration.system;
        };

      overlays = {
        channels = inputs: final: prev: {
          nixpkgs = import inputs.nixpkgs { system = prev.system; };
        };

        extraPackages = inputs: final: prev: {
          #inherit (self.packages.${prev.system}) sysdo pyEnv;
          #inherit (inputs.devenv.packages.${prev.system}) devenv;

          # rancher-desktop = final.callPackage ./pkgs/rancher-desktop.nix {};
          inherit (inputs.maven-mvnd.packages.${prev.system}) maven-mvnd-m39;
          inherit (inputs.disko.packages.${prev.system}) disko;
          inherit (inputs.incus-compose.packages.${prev.system}) incus-compose;
        };

        birdOverlay = inputs: import ./overlays/bird.nix inputs;
        qemuOverlay = inputs: import ./overlays/qemu.nix inputs;
        nodejsOverlay = inputs: import ./overlays/nodejs.nix inputs;
      };

      homeManagerModules = {
        primaryUser = import ./modules/common/primary-user.nix;
        manager = import ./modules/home-manager;
        profiles = {
          # Optionally, expose profiles as modules if they are home-manager compatible
          work = import ./profiles/work.nix;
          committed = import ./profiles/committed.nix;
        };
      };

    };
}
