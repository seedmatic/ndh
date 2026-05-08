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

    extra-experimental-features = [
      "nix-command"
      "flakes"
      "ca-derivations"
      "configurable-impure-env"
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
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
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
              overlay = self.overlayFactories.${name} inputs;
            in
            final: prev: overlay final prev
          ) (builtins.attrNames self.overlayFactories);

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
          writeShellScriptBin =
            name: text:
            pkgsForSystem.runCommand (prefixedName name) { } ''
              install -Dm755 ${pkgsForSystem.writeShellScript name text} "$out/bin/${name}"
            '';
          installBinScript =
            name: source:
            pkgsForSystem.runCommand (prefixedName name) { } ''
              install -Dm755 ${source} "$out/bin/${name}"
            '';
        };

      ndhStoreApiDarwin = mkNdhStoreApiFor pkgsForDarwin;
      ndhStoreApiLinux = mkNdhStoreApiFor pkgsForLinux;
      mkNdhNixBashTrampoline =
        {
          pkgsForSystem,
          loggerCmd,
        }:
        let
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          loggerScript = ndhStoreApi.writeText "logger.sh" ''
            #!/usr/bin/env bash
            LOGGER_CMD="${loggerCmd}"
            source ${./modules/.common.d/shell.d/logger.sh}
          '';
          trampolineDir = ndhStoreApi.runCommand "trampoline-dir" { } ''
            mkdir -p "$out"
            install -m 0644 ${loggerScript} "$out/logger.sh"
            install -m 0755 ${./modules/.common.d/shell.d/nix-bash-trampoline.sh} "$out/nix-bash-trampoline.sh"
          '';
        in
        "${trampolineDir}/nix-bash-trampoline.sh";
      ndhNixBashTrampolineDarwin = mkNdhNixBashTrampoline {
        pkgsForSystem = pkgsForDarwin;
        loggerCmd = "/usr/bin/logger -p notice -t %TAG%";
      };
      ndhNixBashTrampolineLinux = mkNdhNixBashTrampoline {
        pkgsForSystem = pkgsForLinux;
        loggerCmd = "${pkgsForLinux.util-linux}/bin/logger -p notice -t %TAG%";
      };
      ndhBootstrapRuntimePackageLinux = mkNdhBootstrapRuntimePackage "aarch64-linux";
      ndhBringupRuntimeAttr = "nerd-bringup-runtime";
      ndhBringupInstallerAttr = "nerd-bringup-install";
      ndhBringupInstallerCommand = "nerd-bringup-install";
      ndhVmLimaMaterializeAttr = "nerd-lima-vm-materialize";
      ndhVmTartMaterializeAttr = "nerd-tart-vm-materialize";
      ndhVmTartBootstrapInstallerAttr = "nerd-tart-vm-bootstrap-installer";
      ndhLogCaptureAttr = "nerd-log-capture";
      ndhLogCaptureCommand = "nerd-log-capture";
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
        {
          hostProfile,
          system,
          generationMode ? "full",
        }:
        let
          bringupModeInternal = generationMode == "bringup";
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
          generationMode ? "full",
          preModules ? [ ],
          extraModules ? [ ],
          ...
        }:
        let
          baseModules = mkBaseModulesFor {
            inherit
              hostProfile
              system
              generationMode
              ;
          };
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
          name = ndhBringupRuntimeAttr;
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
          runtimePackage = mkNdhBootstrapRuntimePackage system;
          loggerScript = (mkLoggerSpecialArg system).script;
          scriptSource =
            pkgsForSystem.replaceVars ./modules/.common.d/bringup-runtime.d/install-standalone.sh
              {
                bash = "${pkgsForSystem.bash}/bin/bash";
                nix = "${pkgsForSystem.nix}/bin/nix";
                loggerTag = "ndh.bringup-runtime.install-standalone";
                runtimePackage = runtimePackage;
                defaultProfileDir = "/nix/var/nix/profiles/per-user/root/nerd-bringup-runtime";
                requiredCommands = "bash nix age age-keygen awk sed grep ssh ssh-keygen yq git";
              };
        in
        pkgsForSystem.runCommand ndhBringupInstallerAttr { } ''
          install -Dm755 ${scriptSource} "$out/bin/${ndhBringupInstallerCommand}"
        '';

      mkNdhLogCapturePackage =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
        in
        pkgsForSystem.writeShellApplication {
          name = ndhLogCaptureCommand;
          runtimeInputs = with pkgsForSystem; [
            coreutils
            gnused
          ];
          text = ''
            set -euo pipefail

            usage() {
              cat >&2 <<'EOF'
            Usage: nerd-log-capture [--name NAME] [--dir DIR] -- <command> [args...]

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
                  [[ $# -gt 0 ]] || { echo "[nerd-log-capture][ERROR] --name requires a value" >&2; usage; exit 2; }
                  log_name="$1"
                  ;;
                --dir)
                  shift
                  [[ $# -gt 0 ]] || { echo "[nerd-log-capture][ERROR] --dir requires a value" >&2; usage; exit 2; }
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
              echo "[nerd-log-capture][ERROR] missing command" >&2
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
            log_file="$log_dir/nerd-$log_name-$timestamp.log"

            cmd_pretty="$(printf '%q ' "$@")"
            {
              echo "# nerd-log-capture"
              echo "# timestamp: $(date -Is)"
              echo "# cwd: $PWD"
              echo "# command: $cmd_pretty"
              echo
            } > "$log_file"

            set +e
            "$@" 2>&1 | tee -a "$log_file"
            cmd_rc=''${PIPESTATUS[0]}
            set -e

            echo "[nerd-log-capture] log file: $log_file" >&2
            exit "$cmd_rc"
          '';
        };

      mkNdhVmTartBootstrapInstallerPackage =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
        in
        pkgsForSystem.writeShellApplication {
          name = ndhVmTartBootstrapInstallerAttr;
          runtimeInputs = with pkgsForSystem; [
            coreutils
            findutils
            gnugrep
            git
          ];
          text = ''
            set -euo pipefail

            usage() {
              cat >&2 <<'EOF'
            Usage: nerd-tart-vm-bootstrap-installer [--vm NAME] [--repo PATH] [--iso PATH] [--tag TAG]

            Launches Tart VM in installer bootstrap mode using the existing run wrapper:
              - recovery boot enabled
              - installer ISO attached read-only
              - repo mounted via virtiofs

            Options:
              --vm NAME     VM name (default: nerd-nixos)
              --repo PATH   Git checkout to mount as virtiofs (default: auto-detect)
              --iso PATH    Installer ISO path (default: auto-detect)
              --tag TAG     Virtiofs tag for repo mount (default: ndh)

            Environment overrides:
              VM_NAME
              BOOTSTRAP_REPO
              INSTALLER_ISO_PATH
              BOOTSTRAP_SHARE_TAG
              RUN_EXTRA_ARGS (preserved and appended)
            EOF
            }

            vm_name="''${VM_NAME:-nerd-nixos}"
            repo_root="''${BOOTSTRAP_REPO:-}"
            iso_path="''${INSTALLER_ISO_PATH:-}"
            share_tag="''${BOOTSTRAP_SHARE_TAG:-ndh}"

            while (($#)); do
              case "$1" in
                --vm)
                  shift
                  [[ $# -gt 0 ]] || { echo "[nerd-tart-vm-bootstrap-installer][ERROR] --vm requires a value" >&2; usage; exit 2; }
                  vm_name="$1"
                  ;;
                --repo)
                  shift
                  [[ $# -gt 0 ]] || { echo "[nerd-tart-vm-bootstrap-installer][ERROR] --repo requires a value" >&2; usage; exit 2; }
                  repo_root="$1"
                  ;;
                --iso)
                  shift
                  [[ $# -gt 0 ]] || { echo "[nerd-tart-vm-bootstrap-installer][ERROR] --iso requires a value" >&2; usage; exit 2; }
                  iso_path="$1"
                  ;;
                --tag)
                  shift
                  [[ $# -gt 0 ]] || { echo "[nerd-tart-vm-bootstrap-installer][ERROR] --tag requires a value" >&2; usage; exit 2; }
                  share_tag="$1"
                  ;;
                --help|-h)
                  usage
                  exit 0
                  ;;
                *)
                  echo "[nerd-tart-vm-bootstrap-installer][ERROR] unknown argument: $1" >&2
                  usage
                  exit 2
                  ;;
              esac
              shift
            done

            if [[ -z "$repo_root" ]]; then
              if repo_candidate="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)" && [[ -n "$repo_candidate" ]]; then
                repo_root="$repo_candidate"
              elif [[ -d "/private/var/lib/git/nxmatic/nix-darwin-home" ]]; then
                repo_root="/private/var/lib/git/nxmatic/nix-darwin-home"
              else
                echo "[nerd-tart-vm-bootstrap-installer][ERROR] unable to detect repo root; pass --repo PATH" >&2
                exit 1
              fi
            fi

            if [[ ! -d "$repo_root" ]]; then
              echo "[nerd-tart-vm-bootstrap-installer][ERROR] repo path does not exist: $repo_root" >&2
              exit 1
            fi

            if [[ -z "$iso_path" ]]; then
              iso_path="$(find "$repo_root/sandbox/zfs-raidz1-lab/.tart/opt/lib" -maxdepth 1 -type f -name '*nixos*.iso' 2>/dev/null | sort | tail -n 1 || true)"
            fi

            if [[ -z "$iso_path" ]]; then
              iso_path="$(find "$HOME/.tart" "$repo_root" -type f -name '*nixos*.iso' 2>/dev/null | sort | tail -n 1 || true)"
            fi

            if [[ -z "$iso_path" || ! -f "$iso_path" ]]; then
              echo "[nerd-tart-vm-bootstrap-installer][ERROR] installer ISO not found; pass --iso PATH" >&2
              exit 1
            fi

            wrapper="$HOME/.tart/vms/$vm_name.sh"
            if [[ ! -x "$wrapper" ]]; then
              echo "[nerd-tart-vm-bootstrap-installer][ERROR] VM run wrapper missing or not executable: $wrapper" >&2
              echo "[nerd-tart-vm-bootstrap-installer][ERROR] run nerd-tart-vm-materialize first" >&2
              exit 1
            fi

            extra_args=(
              "--recovery"
              "--disk=$iso_path:ro"
              "--dir=$repo_root:rw,tag=$share_tag"
            )

            if [[ -n "''${RUN_EXTRA_ARGS:-}" ]]; then
              read -r -a user_extra_args <<<"$RUN_EXTRA_ARGS"
              extra_args=("''${user_extra_args[@]}" "''${extra_args[@]}")
            fi

            joined_extra_args="$(printf '%q ' "''${extra_args[@]}")"
            joined_extra_args="''${joined_extra_args% }"

            echo "[nerd-tart-vm-bootstrap-installer] vm=$vm_name"
            echo "[nerd-tart-vm-bootstrap-installer] repo=$repo_root"
            echo "[nerd-tart-vm-bootstrap-installer] iso=$iso_path"
            echo "[nerd-tart-vm-bootstrap-installer] tag=$share_tag"

            export RUN_EXTRA_ARGS="$joined_extra_args"
            exec "$wrapper"
          '';
        };

      mkNdhDiskoPinnedModule =
        system:
        let
          ndhStoreApi = mkNdhStoreApiFor (pkgsFor {
            inherit system;
          });
        in
        ndhStoreApi.writeText "disko-module-pinned.nix" ''
          { lib, ... }:
          {
            disko = import ${./modules/nixos/zfs-disko-config.nix} {
              inherit lib;
            };
          }
        '';

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
        }
        // extraArgs;
      mkNdhHomeManagerSpecialArgs = import ./modules/.common.d/ndh-home-manager-special-args.nix;

      darwinOutputsApi = import ./modules/darwin/outputs.nix {
        inherit
          inputs
          pkgsForDarwin
          ndhStoreApiDarwin
          ndhNixBashTrampolineDarwin
          mkModulesFor
          mkSpecialArgs
          ;
      };

      nixosOutputsApi = import ./modules/nixos/outputs.nix {
        inherit
          nixpkgs
          pkgsForLinux
          ndhStoreApiLinux
          ndhNixBashTrampolineLinux
          ndhBootstrapRuntimePackageLinux
          mkModulesFor
          mkSpecialArgs
          ;
        inherit (inputs) disko sops-nix;
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

      diskoConfigurations = {
        default = import ./modules/nixos/zfs-disko-config.nix { lib = nixpkgs.lib; };
      }
      // builtins.foldl' (acc: hostOutput: acc // hostOutput.diskoConfigurations) { } (
        builtins.attrValues hostOutputs
      );

      diskoModules = {
        default = ./modules/nixos/disko.nix;
        pinned = forAllSystems (system: mkNdhDiskoPinnedModule system);
      };

      # Expose package sets with all overlays applied for both platforms we build
      pkgs = {
        aarch64-darwin = pkgsForDarwin;
        aarch64-linux = pkgsForLinux;
      };

      legacyPackages = {
        aarch64-darwin = pkgsForDarwin;
        aarch64-linux = pkgsForLinux;
      };

      mkNixBuildObservePackage =
        system:
        let
          pkgs = pkgsFor { inherit system; };
          nixBashTrampoline = if system == "aarch64-darwin"
            then ndhNixBashTrampolineDarwin
            else ndhNixBashTrampolineLinux;
        in
        pkgs.writeShellScriptBin "nix-build-observe" ''
          export NDH_NIX_BASH_TRAMPOLINE="${nixBashTrampoline}"
          ${builtins.readFile ./modules/darwin/bringup-observe.d/nix-build-observe.sh}
        '';

      packages = nixpkgs.lib.genAttrs [ "aarch64-darwin" "aarch64-linux" ] (
        system:
        let
          ndhStoreApi = mkNdhStoreApiFor (pkgsFor {
            inherit system;
          });
        in
        {
          ${ndhBringupRuntimeAttr} = mkNdhBootstrapRuntimePackage system;
          ndh-disko-module-pinned = mkNdhDiskoPinnedModule system;
          ndh-disko-config = ndhStoreApi.writeText "zfs-disko-config.nix" (
            builtins.readFile ./modules/nixos/zfs-disko-config.nix
          );
          nix-build-observe = mkNixBuildObservePackage system;
        }
        // builtins.foldl' (
          acc: hostName:
          let
            hostSpec = hostCatalog.${hostName};
            mainName = hostMainNameForProfile hostSpec.hostProfile;
          in
          acc
          // {
            "${mainName}-bringup-install" = mkNdhBringupRuntimeInstaller system;
            "${mainName}-log-capture" = mkNdhLogCapturePackage system;
            "${mainName}-tart-vm-bootstrap-installer" = mkNdhVmTartBootstrapInstallerPackage system;
          }
        ) { } (builtins.attrNames hostCatalog)
        // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") (
          builtins.foldl' (
            acc: hostName:
            let
              hostSpec = hostCatalog.${hostName};
              mainName = hostMainNameForProfile hostSpec.hostProfile;
              hostOutput = hostOutputs.${hostName};
            in
            acc
            // {
              "${mainName}-lima-vm-materialize" =
                hostOutput.darwinConfiguration.config.lima.configGenerator.materializerPackage;
              "${mainName}-tart-vm-materialize" =
                hostOutput.darwinConfiguration.config.tart.configGenerator.materializerPackage;
            }
          ) { } (builtins.attrNames hostCatalog)
        )
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") (
          builtins.foldl' (
            acc: hostName:
            let
              hostSpec = hostCatalog.${hostName};
              mainName = hostMainNameForProfile hostSpec.hostProfile;
              hostOutput = hostOutputs.${hostName};
            in
            acc
            // {
              "${mainName}-bringup-zfs-systemd-disk" = hostOutput.nixosDiskImageBringupSystemdZfs;
            }
          ) { } (builtins.attrNames hostCatalog)
        )
      );

      apps = forAllSystems (
        system:
        let
          installer = mkNdhBringupRuntimeInstaller system;
          logCapture = mkNdhLogCapturePackage system;
          tartBootstrapInstaller = mkNdhVmTartBootstrapInstallerPackage system;
          hostMaterializerApps = builtins.foldl' (
            acc: hostName:
            let
              hostSpec = hostCatalog.${hostName};
              mainName = hostMainNameForProfile hostSpec.hostProfile;
              hostOutput = hostOutputs.${hostName};
              limaMaterializerPackage =
                hostOutput.darwinConfiguration.config.lima.configGenerator.materializerPackage;
              tartMaterializerPackage =
                hostOutput.darwinConfiguration.config.tart.configGenerator.materializerPackage;
            in
            acc
            // {
              "${mainName}-lima-vm-materialize" = {
                type = "app";
                program = "${limaMaterializerPackage}/bin/${ndhVmLimaMaterializeAttr}";
              };
              "${mainName}-tart-vm-materialize" = {
                type = "app";
                program = "${tartMaterializerPackage}/bin/${ndhVmTartMaterializeAttr}";
              };
            }
          ) { } (builtins.attrNames hostCatalog);
          hostBootstrapInstallerApps = builtins.foldl' (
            acc: hostName:
            let
              hostSpec = hostCatalog.${hostName};
              mainName = hostMainNameForProfile hostSpec.hostProfile;
            in
            acc
            // {
              "${mainName}-bringup-install" = {
                type = "app";
                program = "${installer}/bin/${ndhBringupInstallerCommand}";
              };
              "${mainName}-log-capture" = {
                type = "app";
                program = "${logCapture}/bin/${ndhLogCaptureCommand}";
              };
              "${mainName}-tart-vm-bootstrap-installer" = {
                type = "app";
                program = "${tartBootstrapInstaller}/bin/${ndhVmTartBootstrapInstallerAttr}";
              };
            }
          ) { } (builtins.attrNames hostCatalog);
          nixBuildObservePackage = mkNixBuildObservePackage system;
        in
        {
          nix-build-observe = {
            type = "app";
            program = "${nixBuildObservePackage}/bin/nix-build-observe";
          };
        }
        // hostMaterializerApps
        // hostBootstrapInstallerApps
      );

      mkHostOutputs =
        {
          hostProfile,
          profileModule,
          darwinExtraModules ? [ ],
          nixosExtraModules ? [ ],
          withBringupImages ? true,
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
          nixosConfiguration = nixosOutputs.nixosConfigurations."${mainName}-bringup";
          nixosDiskImage = nixosOutputs.diskImageFull;
          nixosDiskImageBringupSystemd = nixosOutputs.diskImageBringupSystemdBoot;
          nixosDiskImageBringupSystemdZfs = nixosOutputs.diskImageBringupZfsSystemdBoot;
          nixosDiskImageBringupGrub = nixosOutputs.diskImageBringupGrub;
          nixosDiskSizeHint = nixosOutputs.diskSizeHint;
          nixosDiskSizeMiB = nixosOutputs.diskSizeMiB;
          nixosDiskSizeGiB = nixosOutputs.diskSizeGiB;
          nixosDiskoConfiguration = nixosOutputs.diskoConfiguration;
          mkHomeManagerConfig =
            profile:
            let
              vmConfigMaterializerPackage =
                if !withBringupImages then
                  null
                else if (hostProfile.vmProvider or "lima") == "tart" then
                  darwinOutputs.darwinConfigurations.${mainName}.config.tart.configGenerator.materializerPackage
                else
                  darwinOutputs.darwinConfigurations.${mainName}.config.lima.configGenerator.materializerPackage;
            in
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
              extraSpecialArgs = mkNdhHomeManagerSpecialArgs {
                inherit
                  self
                  profile
                  vmConfigMaterializerPackage
                  ;
                ndhContext = {
                  inherit
                    hostProfile
                    catalog
                    ;
                  inventory = inventoryData;
                  generationMode = "full";
                  vmProvider = hostProfile.vmProvider or "lima";
                  nixBashTrampoline = ndhNixBashTrampolineDarwin;
                };
                ndhStore = ndhStoreApiDarwin;
                keysYamlPath = "${toString profile.user.home}/.local/var/run/secrets/sops/ssh-keys.yaml";
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
                    { lib, ... }:
                    { lima.configGenerator.diskSizeGiB = nixosDiskSizeGiB; }
                    // lib.optionalAttrs withBringupImages {
                      lima.configGenerator.imageManifestPath = "${nixosDiskImageBringupSystemdZfs}/manifest.yaml";
                      lima.configGenerator.imageStorePath = "${nixosDiskImageBringupSystemdZfs}/boot.img";

                      tart.configGenerator.rawImageManifestPath = "${nixosDiskImageBringupSystemdZfs}/manifest.yaml";
                      tart.configGenerator.rawImageStorePath = "${nixosDiskImageBringupSystemdZfs}/boot.img";
                      tart.configGenerator.vmRunFirstBootAttachDiskManifestPath = null;
                      tart.configGenerator.vmRunFirstBootAttachDiskPath = "";
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
                loggerTag = "ndh.bringup-runtime.prerequisites-install.darwin";
                autofsMaterializerProgram =
                  if autofsNetMaterializerProgram != null then autofsNetMaterializerProgram else "";
                standaloneInstaller = "${ndhBootstrapInstallerPackage}/bin/${ndhBringupInstallerCommand}";
              };
          ndhPrerequisitesInstallerScriptSourceLinux =
            pkgsForLinux.replaceVars ./modules/.common.d/bringup-runtime.d/prerequisites-install-wrapper.sh
              {
                bash = "${pkgsForLinux.bash}/bin/bash";
                loggerTag = "ndh.bringup-runtime.prerequisites-install.linux";
                autofsMaterializerProgram = "";
                standaloneInstaller = "${ndhBootstrapInstallerPackageLinux}/bin/${ndhBringupInstallerCommand}";
              };
          ndhPrerequisitesInstallerPackage = pkgsForDarwin.runCommand ndhBringupInstallerAttr { } ''
            install -Dm755 ${ndhPrerequisitesInstallerScriptSource} "$out/bin/${ndhBringupInstallerCommand}"
          '';
          ndhPrerequisitesInstallerPackageLinux = pkgsForLinux.runCommand ndhBringupInstallerAttr { } ''
            install -Dm755 ${ndhPrerequisitesInstallerScriptSourceLinux} "$out/bin/${ndhBringupInstallerCommand}"
          '';
          hostDarwinPackages = {
            ${ndhBringupRuntimeAttr} = ndhBootstrapRuntimePackage;
            ${ndhBringupInstallerAttr} = ndhPrerequisitesInstallerPackage;
            ${ndhVmLimaMaterializeAttr} = limaMaterializerPackage;
            ${ndhVmTartMaterializeAttr} = tartMaterializerPackage;
            ${ndhVmTartBootstrapInstallerAttr} = mkNdhVmTartBootstrapInstallerPackage "aarch64-darwin";
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
            ${ndhVmTartBootstrapInstallerAttr} = {
              type = "app";
              program = "${(mkNdhVmTartBootstrapInstallerPackage "aarch64-darwin")}/bin/${ndhVmTartBootstrapInstallerAttr}";
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
            nixosDiskImageBringupSystemd
            nixosDiskImageBringupSystemdZfs
            nixosDiskImageBringupGrub
            nixosDiskSizeHint
            homeManagerConfigurations
            ;
          homeManagerConfiguration = homeManagerConfigurations.committed;
          diskoConfigurations = {
            "${mainName}-nixos" = nixosDiskoConfiguration;
          };
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

      hostOutputs = forAllHosts (
        _: hostSpec:
        let
          envObserve = builtins.getEnv "NDH_ZFS_INSTALL_OBSERVE";
          envInterval = builtins.getEnv "NDH_ZFS_INSTALL_OBSERVE_INTERVAL";
        in
        mkHostOutputs (hostSpec // {
          pauseAfterInstall = builtins.getEnv "NDH_BRINGUP_PAUSE" == "1";
          enableInstallObserve = if envObserve == "0" then false else true;
          installObserveInterval = if envInterval != "" then
            (builtins.fromJSON envInterval) else 5;
        })
      );

      darwinConfigurations = builtins.foldl' (
        acc: hostOutput: acc // hostOutput.darwinConfigurations
      ) { } (builtins.attrValues hostOutputs);

      nixosConfigurations = builtins.foldl' (acc: hostOutput: acc // hostOutput.nixosConfigurations) { } (
        builtins.attrValues hostOutputs
      );

      # Provider-scoped VM configuration aliases (full runtime systems, not bringup).
      vmConfigurations =
        let
          mkVmHostAliases =
            hostName: hostSpec:
            let
              mainName = hostMainNameForProfile hostSpec.hostProfile;
              hostNixosConfigurations = hostOutputs.${hostName}.nixosConfigurations;
            in
            {
              lima.system = hostNixosConfigurations."${mainName}-lima";
              tart.system = hostNixosConfigurations."${mainName}-tart";
            };

          vmAliasesByHost = forAllHosts mkVmHostAliases;
        in
        {
          lima = builtins.mapAttrs (_: hostAliases: hostAliases.lima) vmAliasesByHost;
          tart = builtins.mapAttrs (_: hostAliases: hostAliases.tart) vmAliasesByHost;
        };

      homeManagerConfigurations = builtins.mapAttrs (
        _: hostOutput: hostOutput.homeManagerConfigurations
      ) hostOutputs;

      nixosDiskImages =
        builtins.mapAttrs (_: hostOutput: hostOutput.nixosDiskImageBringupSystemdZfs) hostOutputs;

      # Overlay factories (curried: inputs: final: prev:) — used internally via overlayFactories.
      overlayFactories = {
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
        vmToolsDeterministicOverlay = inputs: import ./overlays/vm-tools-deterministic.nix inputs;

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

      # Standard nixpkgs overlays with inputs pre-applied — correct type for the flake overlays output.
      overlays = nixpkgs.lib.mapAttrs (_: f: f inputs) overlayFactories;

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
