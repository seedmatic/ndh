{
  description = "nix system configurations";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://nxmatic.cachix.org"
      "https://cache.flox.dev"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nxmatic.cachix.org-1:huMghYiwDpPa1PMXHXK4G1Dp4QOZjgsNqxcjf/AjuJ0="
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
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
    incus-compose.follows = "flake-commons/incus-compose";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs =
    {
      self,
      darwin,
      devenv,
      flake-utils,
      home-manager,
      disko,
      socket-vmnet,
      impermanence,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (flake-utils.lib) eachSystemMap;
      nixpkgsConfig = import ./modules/.common.d/nixpkgs-config.nix;
      cacheTrust = import ./catalog/cache-trust.nix;
      inventoryData = import ./inventory/default.nix;
      catalogData = import ./catalog/default.nix { inherit cacheTrust; };
      defaultSystems = [
        "aarch64-darwin"
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

      mkNdhStoreApiFor =
        pkgsForSystem:
        let
          storeNamePrefix = "io.nxmatic.nix-darwin-home";
          prefixStoreName =
            name:
            if nixpkgs.lib.hasPrefix "${storeNamePrefix}-" name then name else "${storeNamePrefix}-${name}";
        in
        rec {
          prefix = storeNamePrefix;
          prefixedName = prefixStoreName;
          installScript =
            {
              name,
              source,
              preferLocalBuild ? null,
              allowSubstitutes ? null,
              mode ? "0555",
            }:
            pkgsForSystem.runCommand (prefixedName name)
              (
                (nixpkgs.lib.optionalAttrs (preferLocalBuild != null) { inherit preferLocalBuild; })
                // (nixpkgs.lib.optionalAttrs (allowSubstitutes != null) { inherit allowSubstitutes; })
              )
              ''
                install -m ${mode} ${source} "$out"
              '';
          runCommand =
            name: attrs: text:
            pkgsForSystem.runCommand (prefixedName name) attrs text;
          writeText = name: text: pkgsForSystem.writeText (prefixedName name) text;
          writeShellScript = name: text: pkgsForSystem.writeShellScript (prefixedName name) text;
        };

      ndhStoreApiDarwin = mkNdhStoreApiFor pkgsForDarwin;
      ndhStoreApiLinux = mkNdhStoreApiFor pkgsForLinux;
      ndhBringupRuntimeAttr = "ndh-bringup-runtime";
      ndhBringupInstallerAttr = "ndh-bringup-install";
      ndhBringupInstallerCommand = "ndh-bringup-install";
      ndhVmLimaMaterializeAttr = "ndh-vm-lima-materialize";
      ndhVmTartMaterializeAttr = "ndh-vm-tart-materialize";
      ndhLogCaptureAttr = "ndh-log-capture";
      ndhLogCaptureCommand = "ndh-log-capture";
      hostCatalog = builtins.mapAttrs (
        hostName: _: import (./hosts + "/${hostName}")
      ) inventoryData.hosts;
      hostMainNameForProfile =
        hostProfile:
        if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
          hostProfile.hostAlias
        else
          hostProfile.hostName;
      forAllHosts = f: nixpkgs.lib.mapAttrs f hostCatalog;

      mkBaseModulesFor =
        { hostProfile, system }:
        let
          hostImageMode = hostProfile.nixosImageMode or "full";
          bringupModeInternal = hostImageMode == "bootstrap";
          requestedHomeManagerEnabled =
            if hostProfile ? enableHomeManager && hostProfile.enableHomeManager != null then
              hostProfile.enableHomeManager
            else
              true;
          homeManagerEnabled =
            if system == "nixos" && bringupModeInternal then false else requestedHomeManagerEnabled;
        in
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
              inputs.sops-nix.nixosModules.sops
            ]
            ++ (if homeManagerEnabled then [ home-manager.nixosModules.home-manager ] else [ ])
            ++ [
              impermanence.nixosModules.impermanence
              ./modules/nixos
            ]
          else if system == "darwin" then
            [
              inputs.sops-nix.darwinModules.sops
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

      mkLoggerSpecialArg =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          loggerScript = ndhStoreApi.writeText "logger.sh" ''
            #!/usr/bin/env bash
            LOGGER_CMD=""
            source ${./modules/.common.d/shell.d/logger.sh}
          '';
        in
        {
          script = loggerScript;
          cmd = "";
        };

      mkNdhBootstrapRuntimePackage =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          bashPackage = pkgsForSystem.lib.getBin pkgsForSystem.bashInteractive;
          nixPackage = pkgsForSystem.lib.getBin pkgsForSystem.nix;
        in
        pkgsForSystem.symlinkJoin {
          name = ndhStoreApi.prefixedName "bringup-runtime-profile-holder";
          paths = with pkgsForSystem; [
            bashPackage
            nixPackage
            age
            coreutils-full
            findutils
            gawk
            git
            gnugrep
            gnused
            keychain
            openssh
            yq-go
          ];
        };

      mkNdhBringupRuntimeInstaller =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          runtimePackage = mkNdhBootstrapRuntimePackage system;
          loggerScript = (mkLoggerSpecialArg system).script;
          scriptSource =
            pkgsForSystem.replaceVars ./modules/.common.d/bringup-runtime.d/install-standalone.sh
              {
                bash = "${pkgsForSystem.bash}/bin/bash";
                nix = "${pkgsForSystem.nix}/bin/nix";
                logger = loggerScript;
                loggerTag = "ndh.bringup-runtime.install-standalone";
                runtimePackage = runtimePackage;
                defaultProfileDir = "/nix/var/nix/profiles/per-user/root/io-nxmatic-nix-darwin-home-bringup-runtime";
                requiredCommands = "bash nix age age-keygen awk sed grep ssh ssh-keygen yq git";
              };
        in
        ndhStoreApi.runCommand "bringup-runtime-profile-installer" { } ''
          install -Dm755 ${scriptSource} "$out/bin/${ndhBringupInstallerCommand}"
        '';

      mkNdhLogCapturePackage =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
        in
        pkgsForSystem.writeShellApplication {
          name = ndhLogCaptureCommand;
          runtimeInputs = with pkgsForSystem; [ coreutils gnused ];
          text = ''
            set -euo pipefail

            usage() {
              cat >&2 <<'EOF'
            Usage: ndh-log-capture [--name NAME] [--dir DIR] -- <command> [args...]

            Environment:
              NDH_CAPTURE_DIR   Default log directory (default: /tmp)
              NDH_CAPTURE_NAME  Default log name prefix when --name is omitted
            EOF
            }

            log_dir="''${NDH_CAPTURE_DIR:-/tmp}"
            log_name="''${NDH_CAPTURE_NAME:-}"

            while (($#)); do
              case "$1" in
                --name)
                  shift
                  [[ $# -gt 0 ]] || { echo "[ndh-log-capture][ERROR] --name requires a value" >&2; usage; exit 2; }
                  log_name="$1"
                  ;;
                --dir)
                  shift
                  [[ $# -gt 0 ]] || { echo "[ndh-log-capture][ERROR] --dir requires a value" >&2; usage; exit 2; }
                  log_dir="$1"
                  ;;
                --help|-h)
                  usage
                  exit 0
                  ;;
                --)
                  shift
                  break
                  ;;
                *)
                  break
                  ;;
              esac
              shift
            done

            if (($# == 0)); then
              echo "[ndh-log-capture][ERROR] missing command" >&2
              usage
              exit 2
            fi

            if [[ -z "$log_name" ]]; then
              log_name="$(basename "$1")"
            fi

            log_name="$(printf '%s' "$log_name" | tr -cs '[:alnum:]._- ' '-' | tr ' ' '-' | sed 's/^-*//; s/-*$//')"
            if [[ -z "$log_name" ]]; then
              log_name="command"
            fi

            timestamp="$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$log_dir"
            log_file="$log_dir/ndh-$log_name-$timestamp.log"

            cmd_pretty="$(printf '%q ' "$@")"
            {
              echo "# ndh-log-capture"
              echo "# timestamp: $(date -Is)"
              echo "# cwd: $PWD"
              echo "# command: $cmd_pretty"
              echo
            } > "$log_file"

            set +e
            "$@" 2>&1 | tee -a "$log_file"
            cmd_rc=''${PIPESTATUS[0]}
            set -e

            echo "[ndh-log-capture] log file: $log_file" >&2
            exit "$cmd_rc"
          '';
        };

      mkSpecialArgs =
        {
          modules,
          system,
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
        in
        {
          inherit self lib;
          _modules = modules;
          nixpkgsInput = nixpkgs;
          logger = mkLoggerSpecialArg system;
        }
        // extraArgs;

      darwinOutputsApi = import ./modules/darwin/outputs.nix {
        inherit
          inputs
          pkgsForDarwin
          mkModulesFor
          mkSpecialArgs
          ;
      };

      nixosOutputsApi = import ./modules/nixos/outputs.nix {
        inherit
          nixpkgs
          pkgsForLinux
          mkModulesFor
          mkSpecialArgs
          ;
      };

      inherit (darwinOutputsApi)
        mkDarwinConfig
        mkDarwinOutputs
        ;

      inherit (nixosOutputsApi)
        mkNixosConfig
        mkNixosOutputs
        ;
    in
    rec {
      formatter = forAllSystems (
        system:
        let
          pkgs = pkgsFor { inherit system; };
          treefmtConfig = import ./treefmt.nix {
            inherit pkgs;
            projectRootFile = "flake.nix";
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

      packages = nixpkgs.lib.genAttrs [ "aarch64-darwin" "aarch64-linux" ] (
        system:
        {
          ${ndhBringupRuntimeAttr} = mkNdhBootstrapRuntimePackage system;
          ${ndhBringupInstallerAttr} = mkNdhBringupRuntimeInstaller system;
          ${ndhLogCaptureAttr} = mkNdhLogCapturePackage system;
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") (
          builtins.foldl'
            (
              acc: hostName:
              let
                hostSpec = hostCatalog.${hostName};
                mainName = hostMainNameForProfile hostSpec.hostProfile;
                hostOutput = hostOutputs.${hostName};
              in
              acc
              // {
                "nixos-${mainName}-bringup-lima-vm-disk" = hostOutput.limaNixosDiskImageBringupSystemdExt4;
                "nixos-${mainName}-bringup-tart-disk" = hostOutput.tartNixosDiskImageBringupGrubExt4;
              }
            )
            { }
            (builtins.attrNames hostCatalog)
        )
      );

      apps = forAllSystems (
        system:
        let
          installer = mkNdhBringupRuntimeInstaller system;
          logCapture = mkNdhLogCapturePackage system;
          limaMaterializer =
            hostOutputs.bioskop.darwinConfigurations.bioskop.config.lima.configGenerator.materializerPackage;
          tartMaterializer =
            hostOutputs.bioskop.darwinConfigurations.bioskop.config.tart.configGenerator.materializerPackage;
        in
        {
          ${ndhBringupInstallerAttr} = {
            type = "app";
            program = "${installer}/bin/${ndhBringupInstallerCommand}";
          };
          ${ndhLogCaptureAttr} = {
            type = "app";
            program = "${logCapture}/bin/${ndhLogCaptureCommand}";
          };
          ${ndhVmLimaMaterializeAttr} = {
            type = "app";
            program = "${limaMaterializer}/bin/${ndhVmLimaMaterializeAttr}";
          };
          ${ndhVmTartMaterializeAttr} = {
            type = "app";
            program = "${tartMaterializer}/bin/${ndhVmTartMaterializeAttr}";
          };
        }
      );

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
          catalog = catalogData;

          workHomeManagerUser =
            if hostProfile ? homeManagerUser && hostProfile.homeManagerUser != null then
              hostProfile.homeManagerUser
            else
              catalog.users.work;
          workHomeManagerUserWithHome = workHomeManagerUser // {
            home =
              if workHomeManagerUser ? home && workHomeManagerUser.home != null then
                workHomeManagerUser.home
              else
                "/Users/${workHomeManagerUser.name}";
          };
          committedHomeManagerUserWithHome = catalog.users.committed // {
            home =
              if catalog.users.committed ? home && catalog.users.committed.home != null then
                catalog.users.committed.home
              else
                "/Users/${catalog.users.committed.name}";
          };
          workProfile = {
            name = "work";
            sshKeyProfileName = "committed";
            host = hostProfile;
            user = workHomeManagerUserWithHome;
            email = workHomeManagerUserWithHome.email;
          };
          committedProfile = {
            name = "committed";
            host = hostProfile;
            user = committedHomeManagerUserWithHome;
            email = committedHomeManagerUserWithHome.email;
          };
          nixosOutputs = mkNixosOutputs {
            inherit hostProfile catalog;
            inventory = inventoryData;
            profileModule =
              { ... }:
              {
                imports = [ profileModule ] ++ nixosExtraModules;
              };
          };
          nixosConfiguration = nixosOutputs.nixosConfigurations."${mainName}-nixos";
          nixosDiskImage = nixosOutputs.diskImageFull;
          limaNixosDiskImageBringupSystemdExt4 = nixosOutputs.diskImageBringupSystemdExt4Boot;
          tartNixosDiskImageBringupSystemdExt4 = nixosOutputs.diskImageBringupSystemdExt4Boot;
          tartNixosDiskImageBringupSystemdZfs = nixosOutputs.diskImageBringupZfsSystemdBoot;
          tartNixosDiskImageBringupGrubExt4 = nixosOutputs.diskImageBringupGrub;
          nixosDiskSizeHint = nixosOutputs.diskSizeHint;
          nixosDiskSizeMiB = nixosOutputs.diskSizeMiB;
          mkHomeManagerConfig =
            profile:
            home-manager.lib.homeManagerConfiguration {
              pkgs = pkgsForDarwin;
              modules = [
                ./modules/home-manager
                (
                  { lib, ... }:
                  {
                    home.username = lib.mkDefault profile.user.name;
                    home.homeDirectory = lib.mkDefault (toString profile.user.home);
                  }
                )
              ];
              extraSpecialArgs = {
                inherit profile;
                ndh = {
                  store = ndhStoreApiDarwin;
                  inherit catalog;
                  inventory = inventoryData;
                  vm = {
                    provider = hostProfile.vmProvider or "lima";
                    configMaterializerPackage =
                      if (hostProfile.vmProvider or "lima") == "tart" then
                        darwinOutputs.darwinConfigurations.${mainName}.config.tart.configGenerator.materializerPackage
                      else
                        darwinOutputs.darwinConfigurations.${mainName}.config.lima.configGenerator.materializerPackage;
                  };
                  logger = mkLoggerSpecialArg "aarch64-darwin";
                  ssh = {
                    keysYamlPath = "${toString profile.user.home}/.local/var/run/secrets/sops/ssh-keys.yaml";
                  };
                };
              };
            };
          darwinOutputs = mkDarwinOutputs {
            inherit hostProfile catalog;
            inventory = inventoryData;
            profileModule =
              { lib, ... }:
              {
                imports = [
                  profileModule
                  (
                    { ... }:
                    {
                      lima.configGenerator.imageManifestPath = "${limaNixosDiskImageBringupSystemdExt4}/manifest.yaml";
                      lima.configGenerator.imageStorePath = "${limaNixosDiskImageBringupSystemdExt4}/nixos.img";
                      lima.configGenerator.diskSizeGiB = builtins.div nixosDiskSizeMiB 1024;

                      tart.configGenerator.rawImageManifestPath = "${tartNixosDiskImageBringupSystemdZfs}/manifest.yaml";
                      tart.configGenerator.rawImageStorePath = "${tartNixosDiskImageBringupSystemdZfs}/nixos.img";
                    }
                  )
                ]
                ++ darwinExtraModules;
              };
          };
          darwinConfiguration = darwinOutputs.darwinConfigurations.${mainName};
          limaMaterializerPackage = darwinConfiguration.config.lima.configGenerator.materializerPackage;
          tartMaterializerPackage = darwinConfiguration.config.tart.configGenerator.materializerPackage;
          autofsNetMaterializerPackage =
            if
              darwinConfiguration ? config
              && darwinConfiguration.config ? services
              && darwinConfiguration.config.services ? nfsDarwin
              && darwinConfiguration.config.services.nfsDarwin ? autofs
              && darwinConfiguration.config.services.nfsDarwin.autofs ? materializerPackage
            then
              darwinConfiguration.config.services.nfsDarwin.autofs.materializerPackage
            else
              null;
          autofsNetMaterializerProgram =
            if autofsNetMaterializerPackage != null then
              "${autofsNetMaterializerPackage}/bin/nfs-autofs-net-materialize"
            else
              null;
          ndhBootstrapRuntimePackage = mkNdhBootstrapRuntimePackage "aarch64-darwin";
          ndhBootstrapInstallerPackage = mkNdhBringupRuntimeInstaller "aarch64-darwin";
          ndhBootstrapRuntimePackageLinux = mkNdhBootstrapRuntimePackage "aarch64-linux";
          ndhBootstrapInstallerPackageLinux = mkNdhBringupRuntimeInstaller "aarch64-linux";
          ndhPrerequisitesInstallerScriptSource =
            pkgsForDarwin.replaceVars ./modules/.common.d/bringup-runtime.d/prerequisites-install-wrapper.sh
              {
                bash = "${pkgsForDarwin.bash}/bin/bash";
                logger = (mkLoggerSpecialArg "aarch64-darwin").script;
                loggerTag = "ndh.bringup-runtime.prerequisites-install.darwin";
                autofsMaterializerProgram =
                  if autofsNetMaterializerProgram != null then autofsNetMaterializerProgram else "";
                standaloneInstaller = "${ndhBootstrapInstallerPackage}/bin/${ndhBringupInstallerCommand}";
              };
          ndhPrerequisitesInstallerScriptSourceLinux =
            pkgsForLinux.replaceVars ./modules/.common.d/bringup-runtime.d/prerequisites-install-wrapper.sh
              {
                bash = "${pkgsForLinux.bash}/bin/bash";
                logger = (mkLoggerSpecialArg "aarch64-linux").script;
                loggerTag = "ndh.bringup-runtime.prerequisites-install.linux";
                autofsMaterializerProgram = "";
                standaloneInstaller = "${ndhBootstrapInstallerPackageLinux}/bin/${ndhBringupInstallerCommand}";
              };
          ndhPrerequisitesInstallerPackage = ndhStoreApiDarwin.runCommand "prerequisites-install" { } ''
            install -Dm755 ${ndhPrerequisitesInstallerScriptSource} "$out/bin/${ndhBringupInstallerCommand}"
          '';
          ndhPrerequisitesInstallerPackageLinux = ndhStoreApiLinux.runCommand "prerequisites-install" { } ''
            install -Dm755 ${ndhPrerequisitesInstallerScriptSourceLinux} "$out/bin/${ndhBringupInstallerCommand}"
          '';
          hostDarwinPackages = {
            ${ndhBringupRuntimeAttr} = ndhBootstrapRuntimePackage;
            ${ndhBringupInstallerAttr} = ndhPrerequisitesInstallerPackage;
            ${ndhVmLimaMaterializeAttr} = limaMaterializerPackage;
            ${ndhVmTartMaterializeAttr} = tartMaterializerPackage;
          };
          hostLinuxPackages = {
            ${ndhBringupRuntimeAttr} = ndhBootstrapRuntimePackageLinux;
            ${ndhBringupInstallerAttr} = ndhPrerequisitesInstallerPackageLinux;
          };
          hostDarwinApps = {
            ${ndhBringupInstallerAttr} = {
              type = "app";
              program = "${ndhPrerequisitesInstallerPackage}/bin/${ndhBringupInstallerCommand}";
            };
            ${ndhVmLimaMaterializeAttr} = {
              type = "app";
              program = "${limaMaterializerPackage}/bin/${ndhVmLimaMaterializeAttr}";
            };
            ${ndhVmTartMaterializeAttr} = {
              type = "app";
              program = "${tartMaterializerPackage}/bin/${ndhVmTartMaterializeAttr}";
            };
          };
          hostLinuxApps = {
            ${ndhBringupInstallerAttr} = {
              type = "app";
              program = "${ndhPrerequisitesInstallerPackageLinux}/bin/${ndhBringupInstallerCommand}";
            };
          };

          # Home Manager configurations are explicitly profile-keyed.
          homeManagerConfigurations = {
            work = mkHomeManagerConfig workProfile;
            bringup = mkHomeManagerConfig workProfile;
            committed = mkHomeManagerConfig committedProfile;
          };
        in
        nixosOutputs
        // darwinOutputs
        // {
          inherit
            darwinConfiguration
            nixosConfiguration
            nixosDiskImage
            limaNixosDiskImageBringupSystemdExt4
            tartNixosDiskImageBringupSystemdExt4
            tartNixosDiskImageBringupSystemdZfs
            tartNixosDiskImageBringupGrubExt4
            nixosDiskSizeHint
            homeManagerConfigurations
            ;
          homeManagerConfiguration = homeManagerConfigurations.committed;
          pkgs = {
            darwin = pkgsForDarwin;
            linux = pkgsForLinux;
          };

          packages =
            nixpkgs.lib.optionalAttrs (hostDarwinPackages != { }) {
              aarch64-darwin = hostDarwinPackages;
            }
            // nixpkgs.lib.optionalAttrs (hostLinuxPackages != { }) {
              aarch64-linux = hostLinuxPackages;
            };

          apps =
            nixpkgs.lib.optionalAttrs (hostDarwinApps != { }) {
              aarch64-darwin = hostDarwinApps;
            }
            // nixpkgs.lib.optionalAttrs (hostLinuxApps != { }) {
              aarch64-linux = hostLinuxApps;
            };

          defaultPackage."aarch64-darwin" = darwinConfiguration.system;
        };

      hostOutputs = forAllHosts (_: hostSpec: mkHostOutputs hostSpec);

      darwinConfigurations = builtins.foldl' (
        acc: hostOutput: acc // hostOutput.darwinConfigurations
      ) { } (builtins.attrValues hostOutputs);

      nixosConfigurations = builtins.foldl' (
        acc: hostOutput: acc // hostOutput.nixosConfigurations
      ) { } (builtins.attrValues hostOutputs);

      # Provider-scoped VM configuration aliases.
      # Keep canonical behavior unchanged; expose stable provider names for operators.
      vmConfigurations =
        let
          mkVmHostAliases =
            hostName: hostSpec:
            let
              mainName = hostMainNameForProfile hostSpec.hostProfile;
              hostNixosConfigurations = hostOutputs.${hostName}.nixosConfigurations;
            in
            {
              lima = {
                bringup = hostNixosConfigurations."lima-${mainName}-bringup-systemd-ext4";
                runtime = hostNixosConfigurations."${mainName}-nixos-lima";
              };
              tart = {
                bringupExt4 = hostNixosConfigurations."tart-${mainName}-bringup-systemd-ext4";
                bringupZfs = hostNixosConfigurations."tart-${mainName}-bringup-systemd-zfs";
                bringupZfsGrub = hostNixosConfigurations."tart-${mainName}-bringup-grub-zfs";
                bringup = hostNixosConfigurations."tart-${mainName}-bringup-grub-zfs";
                runtime = hostNixosConfigurations."${mainName}-nixos-tart";
              };
              selected = {
                bringup = hostNixosConfigurations."lima-${mainName}-bringup-systemd-ext4";
                runtime = hostNixosConfigurations."${mainName}-nixos";
              };
            };

          vmAliasesByHost = forAllHosts mkVmHostAliases;
        in
        {
          lima = builtins.mapAttrs (_: hostAliases: hostAliases.lima) vmAliasesByHost;
          tart = builtins.mapAttrs (_: hostAliases: hostAliases.tart) vmAliasesByHost;
          selected = builtins.mapAttrs (_: hostAliases: hostAliases.selected) vmAliasesByHost;
        };

      homeManagerConfigurations = builtins.mapAttrs (
        _: hostOutput: hostOutput.homeManagerConfigurations
      ) hostOutputs;

      nixosDiskImages = builtins.mapAttrs (
        _: hostOutput:
        {
          full = hostOutput.nixosDiskImage;
          limaSystemdExt4 = hostOutput.limaNixosDiskImageBringupSystemdExt4;
          tartSystemdExt4 = hostOutput.tartNixosDiskImageBringupSystemdExt4;
          tartSystemdZfs = hostOutput.tartNixosDiskImageBringupSystemdZfs;
          tartGrubExt4 = hostOutput.tartNixosDiskImageBringupGrubExt4;
        }
      ) hostOutputs;

      overlays = {
        channels = inputs: final: prev: {
          nixpkgs = import inputs.nixpkgs {
            system = prev.stdenv.hostPlatform.system;
          };
        };

        extraPackages =
          inputs: final: prev:
          let
            hostSystem = prev.stdenv.hostPlatform.system;
          in
          {
            #inherit (self.packages.${hostSystem}) sysdo pyEnv;
            #inherit (inputs.devenv.packages.${hostSystem}) devenv;

            # rancher-desktop = final.callPackage ./pkgs/rancher-desktop.nix {};
            tart-guest-agent = final.callPackage ./pkgs/tart-guest-agent.nix { };
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

        direnvOverlay = _inputs: final: prev: {
          # Upstream direnv fish tests are intermittently SIGKILLed on this build fleet.
          # Keep runtime package deterministic by disabling checks in the canonical overlay path.
          direnv = prev.direnv.overrideAttrs (old: {
            doCheck = false;
            dontCheck = true;
            checkPhase = "echo skipping direnv checkPhase";
            installCheckPhase = "echo skipping direnv installCheckPhase";
            phases = builtins.filter (p: p != "checkPhase" && p != "installCheckPhase") (old.phases or [ ]);
          });
        };
      };

      homeManagerModules = {
        primaryUser = import ./modules/.common.d/primary-user.nix;
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
              echo "Run: modules/nixos/rke2lab/bin/generate-docs.sh"
            '';
          };
        }
      );

    };
}
