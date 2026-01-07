{
  description = "nix system configurations";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://nxmatic.cachix.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
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

  outputs =
    {
      self,
      darwin,
      devenv,
      flake-utils,
      nixos-generators,
      home-manager,
      disko,
      socket-vmnet,
      impermanence,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (flake-utils.lib) eachSystemMap;
      nixpkgsConfig = import ./modules/common/nixpkgs-config.nix;
      defaultSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs defaultSystems;

      pkgsFor =
        { system, ... }:
        let
          basePackages = import nixpkgs {
            inherit system;
            config = nixpkgsConfig // {
              allowBroken = true;
              checkAllPackages = false;
            };
          };

          vmnetOverlay =
            final: prev:
            if inputs.socket-vmnet.packages ? ${system} then
              inputs.socket-vmnet.packages.${system}
            else
              throw "Socket VMNet packages not defined for ${system}";

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
          final: prev: (vmnetOverlay final prev) // (ripvcsOverlay final prev) // (applyOverlays final prev)
        );
      pkgsForDarwin = (pkgsFor { system = "aarch64-darwin"; });
      pkgsForLinux = (pkgsFor { system = "aarch64-linux"; });

      mkBaseModulesFor =
        { hostProfile, system }:
        [
          {
            limaHost.hostName =
              if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
                hostProfile.hostAlias
              else
                hostProfile.hostName;
          }
        ]
        ++ (
          if system == "nixos" then
            [
              disko.nixosModules.disko
              home-manager.nixosModules.home-manager
              impermanence.nixosModules.impermanence
              ./modules/nixos
            ]
          else if system == "darwin" then
            [
              home-manager.darwinModules.home-manager
              # Only include impermanence if darwinModules exists
            ]
            ++ (if impermanence ? darwinModules then [ impermanence.darwinModules.impermanence ] else [ ])
            ++ [ ./modules/darwin ]
          else
            [ ]
        );
      mkModulesFor =
        {
          hostProfile,
          system,
          preModules ? [ ],
          extraModules ? [ ],
          ...
        }:
        let
          baseModules = mkBaseModulesFor { inherit hostProfile system; };
        in
        preModules ++ baseModules ++ extraModules;
      mkSpecialArgs =
        {
          modules,
          extraArgs ? { },
          ...
        }:
        let
          lib = inputs.nixpkgs.lib.extend (
            _: _:
            inputs.home-manager.lib
            // {
              # Any additional lib functions you want to include
            }
          );
          # Provide activation logger directly from the store (no /etc indirection)
          activationLoggerScriptLinux = pkgsForLinux.writeText "activation-logger.sh" ''
            #!/usr/bin/env bash
            LOGGER_CMD=""
            source ${./modules/common/default.d/activation-logger.sh}
          '';
        in
        {
          inherit self lib;
          _modules = modules;
          nixpkgsInput = nixpkgs;
          activationLogger = {
            script = activationLoggerScriptLinux;
            cmd = "";
          };
        }
        // extraArgs;

      mkContainerRegistryConfig =
        { hostProfile, catalog, ... }:
        nixpkgs.lib.nixosSystem {
          system = "aarch64-linux";
          pkgs = pkgsForLinux;
          modules = [
            ./modules/common/lima-host.nix
            ./modules/nixos/container-host.nix
            ./modules/nixos/caddy.nix
            ./modules/nixos/docker-registry.nix
            ./modules/nixos/tailscale.nix
            (
              { config, ... }:
              {
                limaHost.hostName = hostProfile.hostName;
                containerHost.guestName = "ctreg";
              }
            )
          ];
          specialArgs = { inherit catalog; };
        };
      mkDarwinConfig =
        {
          hostProfile,
          profileModule,
          catalog,
        }:
        let
          preModules = [
            profileModule
            # socket-vmnet.darwinModules.socket_vmnet
            (
              { lib, ... }:
              {
                lima.configGenerator.vmType = "vz";
              }
            )
          ];
          modules = mkModulesFor {
            inherit hostProfile preModules;
            system = "darwin";
          };
          specialArgs = mkSpecialArgs {
            inherit modules;
            extraArgs = { inherit catalog; };
          };
        in
        inputs.darwin.lib.darwinSystem {
          inherit specialArgs modules;
          system = "aarch64-darwin";
          pkgs = pkgsForDarwin.extend (
            final: prev: {
              chromium-bin = inputs.chromium-bin.packages."aarch64-darwin".default;
            }
          );
        };
      mkDarwinOutputs =
        {
          hostProfile,
          profileModule,
          catalog,
          ...
        }:
        let
          darwinConfiguration = mkDarwinConfig { inherit hostProfile profileModule catalog; };
          darwinConfigurations = {
            "${hostProfile.hostName}" = darwinConfiguration;
          }
          // (
            if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
              {
                "${hostProfile.hostAlias}" = darwinConfiguration;
              }
            else
              { }
          );
        in
        {
          inherit darwinConfigurations;
        };

      mkNixosConfig =
        {
          hostProfile,
          profileModule,
          zfsOverlays,
          containerRegistryConfiguration,
          catalog,
        }:
        let
          zfsOverlaysModule =
            { ... }:
            {
              zfsOverlays.override = zfsOverlays;
            };
          nixosTailscaleTagModule =
            { ... }:
            {
              tailscale.tags = [ "nixos" ];
            };
          preModules = [
            profileModule
            zfsOverlaysModule
            nixosTailscaleTagModule
          ];
          modules = mkModulesFor {
            inherit hostProfile preModules;
            system = "nixos";
          };
          specialArgs = mkSpecialArgs {
            inherit modules;
            extraArgs = {
              inherit hostProfile;
              inherit catalog;
              containerRegistrySystem = containerRegistryConfiguration;
            };
          };
          nixosSystem = nixpkgs.lib.nixosSystem {
            inherit modules specialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
          };
        in
        nixosSystem;
      mkNixosOutputs =
        {
          hostProfile,
          profileModule,
          containerRegistryConfiguration,
          catalog,
        }:
        let
          ext4Modules =
            let
              zfsOverlaysModule =
                { ... }:
                {
                  zfsOverlays.override = false;
                };
              nixosTailscaleTagModule =
                { ... }:
                {
                  tailscale.tags = [ "nixos" ];
                };
            in
            mkModulesFor {
              inherit hostProfile;
              system = "nixos";
              preModules = [
                profileModule
                zfsOverlaysModule
                nixosTailscaleTagModule
              ];
            };

          ext4SpecialArgs = mkSpecialArgs {
            modules = ext4Modules;
            extraArgs = {
              inherit hostProfile catalog;
              containerRegistrySystem = containerRegistryConfiguration;
            };
          };

          ext4 = nixpkgs.lib.nixosSystem {
            modules = ext4Modules;
            specialArgs = ext4SpecialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
          };

          zfs = mkNixosConfig {
            inherit
              hostProfile
              profileModule
              containerRegistryConfiguration
              catalog
              ;
            zfsOverlays = true;
          };
          # Disk size in MiB and bytes
          diskSizeMiB = 20 * 1024;
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
          mainName =
            if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
              hostProfile.hostAlias
            else
              hostProfile.hostName;
        in
        {
          inherit diskSizeHint;
          nixosConfigurations = {
            inherit ext4 zfs;
            "${mainName}-nixos" = zfs;
          };
          diskImage = nixos-generators.nixosGenerate {
            modules = ext4Modules ++ [
              {
                nix.registry.nixpkgs.flake = nixpkgs;
                virtualisation.diskSize = diskSizeMiB;
              }
            ];
            specialArgs = ext4SpecialArgs;
            system = "aarch64-linux";
            pkgs = pkgsForLinux;
            format = "raw-efi";
          };
        };
    in
    {
      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor { inherit system; };
          treefmtConfig = import ./treefmt.nix {
            inherit pkgs;
            projectRootFile = ".git/config";
          };
        in
        inputs.treefmt-nix.lib.mkWrapper pkgs treefmtConfig
      );

      # Disable flake checks to avoid treefmt-nix API mismatch during evaluation
      checks = forAllSystems (_: { });

      # Expose package sets with all overlays applied for both platforms we build
      pkgs = {
        aarch64-darwin = pkgsForDarwin;
        aarch64-linux = pkgsForLinux;
      };

      legacyPackages = {
        aarch64-darwin = pkgsForDarwin;
        aarch64-linux = pkgsForLinux;
      };

      mkHostOutputs =
        {
          hostProfile,
          profileModule,
          darwinExtraModules ? [ ],
          nixosExtraModules ? [ ],
          ...
        }:
        let
          mainName =
            if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
              hostProfile.hostAlias
            else
              hostProfile.hostName;
          catalog = {
            users = {
              work = {
                name = "stephane.lacoin";
                description = "Stephane Lacoin (aka nxmatic)";
                email = "stephane.lacoin@hyland.com";
              };

              committed = {
                name = "nxmatic";
                description = "Stephane Lacoin (aka nxmatic)";
                email = "stephane.lacoin@gmail.com";
              };
            };

            networks = {
              lan = {
                cidr = "192.168.1.0/24";
                domain = ".lan";
              };
              tailnet = {
                cidr = "100.64.0.0/10";
                domain = ".mammoth-skate.ts.net";
              };
            };

            hosts = {
              bioskop = [
                {
                  form = "baremetal";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  builder = {
                    systems = [ "aarch64-darwin" ];
                    maxJobs = 8;
                    protocol = "ssh-ng";
                  };
                }
                {
                  form = "baremetal";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  vm = {
                    kind = "qemu";
                    manager = "nix-darwin";
                  };
                  builder = {
                    systems = [ "aarch64-linux" ];
                    maxJobs = 8;
                    protocol = "ssh-ng";
                  };
                }
                {
                  form = "baremetal";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  vm = {
                    kind = "vz";
                    manager = "lima";
                  };
                  builder = {
                    systems = [ "aarch64-linux" ];
                    maxJobs = 8;
                    protocol = "ssh-ng";
                  };
                }
              ];

              alcide = [
                {
                  # alcide runs as a Tart/VZ macOS VM and does NOT serve as a darwin builder itself; it offloads to remote builders
                  form = "vm";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  vm = {
                    kind = "vz";
                    manager = "tart";
                  };
                  builder = null;
                }
                {
                  form = "vm";
                  networks = [
                    "lan"
                    "tailnet"
                  ];
                  vm = {
                    kind = "vz";
                    manager = "lima";
                  };
                  builder = {
                    systems = [ "aarch64-linux" ];
                    maxJobs = 8;
                    protocol = "ssh-ng";
                  };
                }
              ];
            };
          };

          defaultProfile = {
            name = mainName;
            host = hostProfile;
            user = catalog.users.committed // {
              home = "/Users/${catalog.users.committed.name}";
            };
          };
          darwinOutputs = mkDarwinOutputs {
            inherit hostProfile catalog;
            profileModule =
              { ... }:
              {
                imports = [ profileModule ] ++ darwinExtraModules;
              };
          };
          darwinConfiguration = darwinOutputs.darwinConfigurations.${mainName};

          containerRegistryConfiguration = mkContainerRegistryConfig { inherit hostProfile catalog; };

          nixosOutputs = mkNixosOutputs {
            inherit hostProfile containerRegistryConfiguration catalog;
            profileModule =
              { ... }:
              {
                imports = [ profileModule ] ++ nixosExtraModules;
              };
          };
          nixosConfiguration = nixosOutputs.nixosConfigurations."${mainName}-nixos";
          nixosDiskImage = nixosOutputs.diskImage;
          nixosDiskSizeHint = nixosOutputs.diskSizeHint;

          # Home Manager configurations for direct use
          homeManagerConfigurations =
            let
              activationLoggerScript = pkgsForDarwin.writeText "activation-logger.sh" ''
                #!/usr/bin/env bash
                LOGGER_CMD=""
                source ${./modules/common/default.d/activation-logger.sh}
              '';
            in
            {
              "${mainName}" = home-manager.lib.homeManagerConfiguration {
                pkgs = pkgsForDarwin;
                modules = [ ./modules/home-manager ];
                extraSpecialArgs = {
                  inherit hostProfile catalog;
                  profile = defaultProfile;
                  activationLogger = {
                    script = activationLoggerScript;
                    cmd = "";
                  };
                };
                # Optionally, set username and homeDirectory here if needed
              };
            };
        in
        nixosOutputs
        // darwinOutputs
        // {
          inherit
            darwinConfiguration
            nixosConfiguration
            nixosDiskImage
            nixosDiskSizeHint
            homeManagerConfigurations
            ;
          pkgs = {
            darwin = pkgsForDarwin;
            linux = pkgsForLinux;
          };
          defaultPackage."aarch64-darwin" = darwinConfiguration.system;
        };

      overlays = {
        channels = inputs: final: prev: {
          nixpkgs = import inputs.nixpkgs {
            system = prev.stdenv.hostPlatform.system;
          };
        };

        extraPackages = inputs: final: prev: let
          hostSystem = prev.stdenv.hostPlatform.system;
        in {
          #inherit (self.packages.${hostSystem}) sysdo pyEnv;
          #inherit (inputs.devenv.packages.${hostSystem}) devenv;

          # rancher-desktop = final.callPackage ./pkgs/rancher-desktop.nix {};
          inherit (inputs.maven-mvnd.packages.${hostSystem}) maven-mvnd-m39;
          inherit (inputs.disko.packages.${hostSystem}) disko;
          inherit (inputs.incus-compose.packages.${hostSystem}) incus-compose;
        };

        birdOverlay = inputs: import ./overlays/bird.nix inputs;
        qemuOverlay = inputs: import ./overlays/qemu.nix inputs;
        nodejsOverlay = inputs: import ./overlays/nodejs.nix inputs;
        incusComposeOverlay = inputs: import ./overlays/incus-compose.nix inputs;
        lazygitOverlay = inputs: import ./overlays/lazygit.nix inputs;
        limaOverlay = inputs: import ./overlays/lima.nix inputs;
        tailscaleOverlay = inputs: import ./overlays/tailscale.nix inputs;
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

      # Development shells (add docs environment with diagram support)
      devShells = flake-utils.lib.eachDefaultSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
            };
          };
        in
        {
          docs = pkgs.mkShell {
            packages = with pkgs; [
              asciidoctor-with-extensions
              plantuml
              graphviz
              # Optional: dot for Graphviz is already in graphviz
            ];
            shellHook = ''
              echo "Docs dev shell active (system: ${system})."
              echo "Run: modules/nixos/incus-rke2-cluster/bin/generate-docs.sh"
            '';
          };
        }
      );

    };
}
