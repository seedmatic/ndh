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

  # Inputs are organized into three groups to keep the surface scannable:
  #
  #   1. Aggregator pin — `flake-commons` is the single source of truth for
  #      most third-party flakes. Bump that flake to roll a coordinated set
  #      of dependencies across all consumers.
  #   2. Aggregator passthroughs — every entry is `follows = "flake-commons/<x>";`.
  #      Listed alphabetically so adds/removes diff cleanly.
  #   3. Direct inputs — flakes pinned here because flake-commons does not
  #      re-export them (`treefmt-nix`, `sops-nix`) or because they're
  #      project-local (`tailscale-fork`).
  inputs = {
    # 1. Aggregator pin
    flake-commons.url = "github:nxmatic/nix-flake-commons/develop";

    # 2. Aggregator passthroughs (alphabetized)
    bird.follows = "flake-commons/bird";
    cachix.follows = "flake-commons/cachix";
    chromium-bin.follows = "flake-commons/chromium-bin";
    darwin.follows = "flake-commons/darwin";
    devenv.follows = "flake-commons/devenv";
    disko.follows = "flake-commons/disko";
    flake-compat.follows = "flake-commons/flake-compat";
    flake-utils.follows = "flake-commons/flake-utils";
    flox.follows = "flake-commons/flox";
    home-manager.follows = "flake-commons/home-manager";
    impermanence.follows = "flake-commons/impermanence";
    incus-compose.follows = "flake-commons/incus-compose";
    lix-module.follows = "flake-commons/lix-module";
    maven-mvnd.follows = "flake-commons/maven-mvnd";
    nix.follows = "flake-commons/nix";
    nixos-hardware.follows = "flake-commons/nixos-hardware";
    nixpkgs.follows = "flake-commons/nixpkgs";
    nixpkgs-unstable.follows = "flake-commons/nixpkgs-unstable";
    ripvcs.follows = "flake-commons/ripvcs";
    socket-vmnet.follows = "flake-commons/socket-vmnet";
    zen-browser.follows = "flake-commons/zen-browser";

    # 3. Direct inputs (not aggregated upstream)
    sops-nix.url = "github:Mic92/sops-nix";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    # rke2lab is the source of truth for the cluster network underlay (cluster/
    # node IDs, MAC derivation, addressing). The catalog consumes its flat
    # `lib.networkBlueprint` instead of hand-inlining MAC/IP values. This is the
    # sanctioned BUILD/eval-time edge: nix-darwin-home -> rke2lab. The reverse
    # (rke2lab -> nix-darwin-home) is forbidden and guarded in rke2lab's flake;
    # rke2lab is NOT routed through flake-commons because rke2lab already depends
    # on flake-commons, which would form a flake-commons <-> rke2lab cycle.
    # `flake-commons` follows ours so the two flakes share one resolved version set.
    rke2lab = {
      url = "github:nxmatic/rke2lab/feature/network-blueprint-segments";
      inputs.flake-commons.follows = "flake-commons";
    };

    # Forked tailscale carrying the CNAME-in-extra_records patch (see
    # overlays/tailscale.nix and the upstream PR tracked there). The
    # fork is consumed as a real flake — it builds itself via its
    # own `flakehashes.json` so vendorHash is no longer coupled to
    # whatever tailscale version nixpkgs-unstable happens to ship.
    # `nixpkgs` is pinned to flake-commons so the fork's binaries
    # share a glibc/openssl/etc with the rest of the closure.
    tailscale-fork = {
      url = "github:nxmatic/tailscale/nxmatic/feature/extra-records-cname";
      inputs.nixpkgs.follows = "flake-commons/nixpkgs-unstable";
    };
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
      # Cluster network underlay, single source of truth (see the rke2lab input).
      networkBlueprint = inputs.rke2lab.lib.networkBlueprint;
      catalogData = import ./catalog/default.nix { inherit cacheTrust networkBlueprint; };
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
          # Compose a Darwin launchd Label scoped to this flake's prefix.
          # Use as `Label = ndh.store.mkLaunchdLabel "headscale-bootstrap"`
          # in `launchd.user.agents.<key>.serviceConfig` /
          # `launchd.daemons.<key>.serviceConfig`.  Without this,
          # nix-darwin falls back to its `org.nixos.<key>` default —
          # avoid for our own services so an `ls /Library/LaunchDaemons/`
          # is self-evident about ownership.  Mirrored in
          # modules/.common.d/default.nix's ndhStore for the rare module
          # that gets ndh from `_module.args` instead of specialArgs.
          mkLaunchdLabel =
            name:
            if nixpkgs.lib.hasPrefix "${storeNamePrefix}." name then name else "${storeNamePrefix}.${name}";
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
          # Bundle several pre-substituted scripts into one derivation,
          # exposing each at $out/bin/<attrName>. Callers still run
          # replaceVars per script before handing it in, so per-caller
          # substitutions (logger tags, allowed key names, etc.) stay
          # isolated. Use this when 2+ scripts share a consumer boundary
          # (same systemd unit, same activation step) to cut the number of
          # store paths and replaceVars indirections.
          installBinScriptBundle =
            name: scripts:
            pkgsForSystem.runCommand (prefixedName name) { } (
              "mkdir -p $out/bin\n"
              + nixpkgs.lib.concatStrings (
                nixpkgs.lib.mapAttrsToList (binName: src: ''
                  install -Dm755 ${src} "$out/bin/${binName}"
                '') scripts
              )
            );
        };

      ndhStoreApiDarwin = mkNdhStoreApiFor pkgsForDarwin;
      ndhStoreApiLinux = mkNdhStoreApiFor pkgsForLinux;
      # Canonical trampoline directory: one store path per platform that
      # carries `nix-bash-trampoline.sh` + the raw `logger.sh`.
      #
      # The logger deliberately ships as-is — no LOGGER_CMD pre-binding.
      # `ndh::logger:command:resolve` probes `/usr/bin/logger` then
      # `command -v logger` at call time, which works in three contexts:
      #
      #   - Darwin activation: `/usr/bin/logger` always present.
      #   - NixOS stage-2: systemd units carry util-linux on PATH.
      #   - NixOS initrd: neither available; the probe returns empty and
      #     `ndh::logger:lines:tag` falls back to the no-logger branch
      #     (tag-prefix to stdout/stderr only, no external command).
      #
      # Baking an absolute `${pkgs.util-linux}/bin/logger` into the
      # trampoline was wrong for the initrd case: make-initrd-ng only
      # copies paths explicitly listed in `boot.initrd.systemd.storePaths`
      # and does not scan shell-script text for closure edges, so the
      # baked logger binary would be missing at runtime — causing a
      # silent SIGPIPE on the first write to the redirected FD-2 and
      # zpool-init.service exit 1.
      mkNdhNixBashTrampoline =
        {
          pkgsForSystem,
        }:
        let
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          trampolineDir = ndhStoreApi.runCommand "trampoline-dir" { } ''
            mkdir -p "$out"
            install -m 0644 ${./modules/.common.d/shell.d/logger.sh} "$out/logger.sh"
            install -m 0755 ${./modules/.common.d/shell.d/nix-bash-trampoline.sh} "$out/nix-bash-trampoline.sh"
          '';
        in
        "${trampolineDir}/nix-bash-trampoline.sh";
      ndhNixBashTrampolineDarwin = mkNdhNixBashTrampoline {
        pkgsForSystem = pkgsForDarwin;
      };
      ndhNixBashTrampolineLinux = mkNdhNixBashTrampoline {
        pkgsForSystem = pkgsForLinux;
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
            vm.hostName =
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
            step-cli
            yq-go
          ];
        };

      mkNdhBringupRuntimeInstaller =
        system:
        let
          pkgsForSystem = pkgsFor { inherit system; };
          runtimePackage = mkNdhBootstrapRuntimePackage system;
          nixBashTrampoline =
            if system == "aarch64-darwin" then ndhNixBashTrampolineDarwin else ndhNixBashTrampolineLinux;
          scriptSource =
            pkgsForSystem.replaceVars ./modules/.common.d/bringup-runtime.d/install-standalone.sh
              {
                inherit nixBashTrampoline;
                nix = "${pkgsForSystem.nix}/bin/nix";
                loggerTag = "ndh.bringup-runtime.install-standalone";
                runtimePackage = runtimePackage;
                defaultProfileDir = "/nix/var/nix/profiles/per-user/root/nerd-bringup-runtime";
                requiredCommands = "bash nix age age-keygen awk sed grep ssh ssh-keygen step yq git";
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

      # --- baremetal-link (corp-Mac IP-alias daemon) ----------------------------
      # Connects a CORPORATE bare-metal Mac (vz.<host>) that cannot join the tailnet
      # to its Incus instance segment: a static /30 en0 alias + routes to the /25
      # and the no-NAT tailnet return path, re-applied on Wi-Fi re-association (a
      # WatchPaths LaunchDaemon).  Only baremetal hosts with a `linkCidr` — an
      # off-tailnet corp Mac reached over a /30 — get one; on-tailnet bare-metals
      # (bioskop) declare none.  Rendered from catalog.netplan.baremetal.<host> and
      # delivered as TEXT (no nix runtime, bash-3.2 ok on the target), so the deploy
      # runs from any host that resolves vz.<host> — the operator's Mac or the
      # nikopol-nixos activation oneshot.  See docs/network-topology-c4.adoc +
      # pkgs/baremetal-link.d/.
      baremetalLinkHosts = nixpkgs.lib.filterAttrs (_: bm: bm ? linkCidr) catalogData.netplan.baremetal;

      baremetalLinkLabel = "io.nxmatic.baremetal-link";

      # Common addressing tokens both install.sh and uninstall.sh take from the
      # catalog — single-sourced so the teardown undoes exactly what install set.
      baremetalLinkVars = bm: {
        interface = "en0";
        vzHostAddress = bm.vzHostAddress;
        netCidr = bm.netCidr;
        tailnetCidr = catalogData.netplan.tailnet.cidr;
        hostAddress = bm.hostAddress;
        label = baremetalLinkLabel;
        plist = "/Library/LaunchDaemons/${baremetalLinkLabel}.plist";
        confDir = "/etc/baremetal-link";
      };

      mkBaremetalLinkInstall =
        system: bm:
        (pkgsFor { inherit system; }).replaceVars ./pkgs/baremetal-link.d/install.sh (
          baremetalLinkVars bm
          // {
            linkPrefix = nixpkgs.lib.last (nixpkgs.lib.splitString "/" bm.linkCidr);
            log = "/var/log/baremetal-link.log";
          }
        );

      mkBaremetalLinkUninstall =
        system: bm:
        (pkgsFor { inherit system; }).replaceVars ./pkgs/baremetal-link.d/uninstall.sh (
          baremetalLinkVars bm
        );

      mkBaremetalLinkDeploy =
        system: bm:
        let
          pkgsForSystem = pkgsFor { inherit system; };
        in
        pkgsForSystem.writeShellApplication {
          name = "${bm.domain}-baremetal-link-deploy";
          runtimeInputs = [ pkgsForSystem.openssh ];
          text = builtins.readFile (
            pkgsForSystem.replaceVars ./pkgs/baremetal-link.d/deploy.sh {
              installScript = "${mkBaremetalLinkInstall system bm}";
              uninstallScript = "${mkBaremetalLinkUninstall system bm}";
              vzHost = "vz.${bm.domain}";
              bootstrapHost = "${bm.domain}.local";
            }
          );
        };

      # Per-baremetal-host deploy packages, keyed `<domain>-baremetal-link-deploy`.
      mkBaremetalLinkPackages =
        system:
        builtins.foldl' (
          acc: bm: acc // { "${bm.domain}-baremetal-link-deploy" = mkBaremetalLinkDeploy system bm; }
        ) { } (builtins.attrValues baremetalLinkHosts);

      # Resolve a relative path to a path literal anchored at the repo
      # root.  Each call hashes only the file (or subtree) named, not
      # the whole worktree the way `${self}/<file>` does — so unrelated
      # source edits don't bust downstream derivations like the bringup
      # disk image.  See docs/bringup-image-unification.adoc.
      worktreePath = {
        of = rel: ./. + "/${rel}";
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
          inherit self lib worktreePath;
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
          self
          worktreePath
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

      # Operator gates — resolved at flake evaluation time from environment
      # variables.  Each boolean gate uses canonical "true"/"false" strings
      # (never "0"/"1").  The resolved values are propagated through
      # mkHostOutputs as typed nix arguments; downstream modules bake them into
      # shell code as literal `true`/`false` tokens that can be *run* as bash
      # commands (the shell builtins `true` and `false` return the matching
      # exit status) rather than string-compared.
      envBool =
        name: default:
        let
          v = builtins.getEnv name;
        in
        if v == "" then
          default
        else if v == "true" then
          true
        else if v == "false" then
          false
        else
          throw "${name} must be \"true\" or \"false\", got: ${v}";

      envInt =
        name: default:
        let
          v = builtins.getEnv name;
        in
        if v == "" then default else builtins.fromJSON v;

      hostGateOverrides = {
        pauseAfterInstall = envBool "NDH_BRINGUP_PAUSE" false;
        enableBuildObserve = envBool "NDH_BUILD_OBSERVE" false;
        linuxBuilderGcBeforeBuild = envBool "NDH_LINUX_BUILDER_GC_BEFORE_BUILD" true;
        buildObserveInterval = envInt "NDH_BUILD_OBSERVE_INTERVAL" 5;
      };

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

      # Surface the resolved catalog + inventory as flat (OS-independent) outputs
      # so the operator can review them directly — `nix eval .#catalog.netplan.lan.hosts`
      # or `:lf .` then `catalog…` — without drilling through a host's
      # `darwinConfigurations.<host>._module.specialArgs.catalog`. The catalog's
      # rke2 hosts are the projection of rke2lab's networkBlueprint (see the
      # rke2lab input), so this is also the easiest way to diff the live underlay
      # against the blueprint / bbox reservations.
      catalog = catalogData;
      inventory = inventoryData;

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
          nixBashTrampoline =
            if system == "aarch64-darwin" then ndhNixBashTrampolineDarwin else ndhNixBashTrampolineLinux;
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
          systemPkgs = pkgsFor { inherit system; };
        in
        {
          ${ndhBringupRuntimeAttr} = mkNdhBootstrapRuntimePackage system;
          ndh-disko-module-pinned = mkNdhDiskoPinnedModule system;
          ndh-disko-config = ndhStoreApi.writeText "zfs-disko-config.nix" (
            builtins.readFile ./modules/nixos/zfs-disko-config.nix
          );
          nix-build-observe = mkNixBuildObservePackage system;
          # mDNS alias publisher used by the headscale-daemon modules to
          # advertise a fleet-scoped alias pointing at the current owner.
          # See packages/ndh-mdns-publish/{main.go,default.nix}.
          ndh-mdns-publish = systemPkgs.callPackage ./packages/ndh-mdns-publish { };
        }
        // mkBaremetalLinkPackages system
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
          # Tart artifacts grouped by `nerd-tart-` prefix to make their
          # role obvious in `nix flake show`.  `packages.<system>` must be
          # flat (the flake schema rejects nested attrsets), so we use a
          # `nerd-tart-<host>-<role>` naming scheme:
          #   nerd-tart                — generic, fleet-wide deploy bundle
          #   nerd-tart-<host>-config  — per-VM YAML manifest (scp to vz)
          #   nerd-tart-<host>-deploy  — operator helper: copy + activate
          # The per-host materializer derivation is intentionally NOT
          # surfaced as a flake package — it's an internal artifact
          # consumed by the darwin module's activation script
          # (`config.tart.configGenerator.materializerPackage`).  Operators
          # use `-deploy` instead.
          # Lima materializers keep their original `<host>-lima-vm-materialize`
          # naming — Lima is out of scope for the nerd-tart refactor.
          let
            systemPkgs = pkgsFor { inherit system; };
            anyHostName = builtins.head (builtins.attrNames hostCatalog);
            anyHostDeploy =
              hostOutputs.${anyHostName}.darwinConfiguration.config.tart.configGenerator.deployPackage;
            anyHostBringup = hostOutputs.${anyHostName}.nixosDiskImageBringupSystemdZfs;
            mkDeployHelper =
              {
                mainName,
                vmName,
                runManifest,
              }:
              systemPkgs.writeShellApplication {
                name = "nerd-tart-${mainName}-deploy";
                runtimeInputs = [
                  systemPkgs.nix
                  systemPkgs.openssh
                ];
                text = ''
                  set -euo pipefail

                  # Default vz host: by convention every Tart VM has a
                  # matching `vz.<mainName>` ssh alias on the operator's
                  # darwin home-manager (see hosts/<host>/modules/home-manager/
                  # vz-host-resolver.nix).  Override by passing a host as the
                  # first positional argument.
                  vz_host="vz.${mainName}"
                  if (($# > 0)) && [[ "$1" != --* ]]; then
                    vz_host="$1"
                    shift
                  fi

                  case "''${1:-}" in
                    -h|--help)
                      cat >&2 <<-USAGE
                  Usage: nerd-tart-${mainName}-deploy [vz-host] [-- extra tart run args]

                  Copies the generic Tart deploy bundle, the ${mainName}-specific
                  per-VM YAML, and the fleet-wide bringup disk images to <vz-host>
                  (default: vz.${mainName}); installs the YAML at
                  ~/.config/nerd-tart/${mainName}.yaml on the vz host; then execs
                  nerd-tart there to materialize and run the VM.
                  USAGE
                      exit 0
                      ;;
                  esac

                  deploy_bundle=${anyHostDeploy}
                  vm_config=${runManifest}
                  bringup_images=${anyHostBringup}

                  # Pull, don't push.  The operator host (e.g. bioskop) and
                  # the bare-metal vz host share a LAN, while `vz.<host>`
                  # routes through the Tart guest via ProxyJump — a
                  # single-stream ssh tunnel that throttles disk-image
                  # transfer to ~600 KB/s and traverses the bare metal's
                  # network stack twice.  Inverting the direction lets
                  # vz_host pull straight from the operator over mDNS,
                  # which is the LAN-direct path.
                  #
                  # Source URL is `ssh-ng://$USER@<src>.local`, not the
                  # cert-bound `nix-store.<peer>` alias from
                  # modules/.common.d/nix-store-identity.nix: vz hosts are
                  # bare-metal Macs outside the fleet inventory, so the
                  # nix-store-identity ssh client fragment isn't generated
                  # there.  Plain mDNS + the operator's normal ssh key is
                  # what's reliably available.  `--no-check-sigs` covers
                  # the case where vz_host's nix.conf doesn't trust the
                  # fleet signing key (drift can leave the catalog stale
                  # on a vz host that hasn't been rebuilt recently).
                  src_host="$(hostname -s)"
                  src_url="ssh-ng://$USER@$src_host.local"
                  echo "[nerd-tart-deploy] pulling artifacts on $vz_host from $src_url" >&2
                  # shellcheck disable=SC2029
                  ssh "$vz_host" \
                    "nix copy --no-check-sigs --from '$src_url' \
                       '$deploy_bundle' '$vm_config' '$bringup_images'"

                  echo "[nerd-tart-deploy] installing per-VM YAML on $vz_host" >&2
                  # `$vm_config` is intentionally expanded client-side: it
                  # holds the local store path, which has just been copied
                  # to the vz host's nix store and is now valid there too.
                  # The symlink basename must match the wrapper basename
                  # at ~/.tart/vms/<vmName>.sh, since run.sh resolves the
                  # manifest by `basename "$0" .sh`.  vmName is the Tart
                  # VM directory name (default "nerd-nixos") and is
                  # distinct from mainName (the host-catalog key).
                  # shellcheck disable=SC2029
                  ssh "$vz_host" \
                    "mkdir -p ~/.config/nerd-tart && \
                     ln -sfn '$vm_config' ~/.config/nerd-tart/${vmName}.yaml"

                  echo "[nerd-tart-deploy] activating nerd-tart on $vz_host" >&2
                  exec ssh -t "$vz_host" "$deploy_bundle/bin/nerd-tart" \
                    --config "$vm_config" "$@"
                '';
              };
            tartAttrs = builtins.foldl' (
              acc: hostName:
              let
                hostSpec = hostCatalog.${hostName};
                mainName = hostMainNameForProfile hostSpec.hostProfile;
                hostOutput = hostOutputs.${hostName};
                runManifest = hostOutput.darwinConfiguration.config.tart.configGenerator.runManifest;
              in
              acc
              // {
                "${mainName}-lima-vm-materialize" =
                  hostOutput.darwinConfiguration.config.lima.configGenerator.materializerPackage;
                "nerd-tart-${mainName}-config" = runManifest;
                "nerd-tart-${mainName}-deploy" = mkDeployHelper {
                  inherit mainName runManifest;
                  vmName = hostOutput.darwinConfiguration.config.tart.configGenerator.vmName;
                };
              }
            ) { } (builtins.attrNames hostCatalog);
            # Single fleet-wide deploy bundle — identical for every host that
            # runs Tart, so we pick an arbitrary host's deployPackage.  The
            # underlying derivation depends only on host-agnostic inputs (the
            # bringup image and the activation/run scripts).
          in
          tartAttrs
          // {
            nerd-tart = anyHostDeploy;
          }
        )
        // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") (
          # Single shared bringup disk image — bit-identical for every
          # host, per docs/bringup-image-unification.adoc.  The bringup
          # NixOS config is identity-less; per-host identity is set by
          # the full-system push at activation time, not by the image
          # bytes (the speculative cloud-init seed in the original plan
          # turned out to be unnecessary — see Phase 4 verdict in the
          # plan note).
          #
          # Picks an arbitrary host's `nixosDiskImageBringupSystemdZfs`
          # because the underlying derivation is the same regardless
          # of which host's mkNixosOutputs computed it (the config
          # closure no longer depends on hostProfile).  Nix dedups.
          let
            anyHostName = builtins.head (builtins.attrNames hostCatalog);
          in
          {
            nerd-nixos-bringup-zfs-systemd-disk = hostOutputs.${anyHostName}.nixosDiskImageBringupSystemdZfs;
          }
        )
      );

      apps = forAllSystems (
        system:
        let
          installer = mkNdhBringupRuntimeInstaller system;
          logCapture = mkNdhLogCapturePackage system;
          tartBootstrapInstaller = mkNdhVmTartBootstrapInstallerPackage system;
          # `apps.<system>` must be flat (each leaf is `{ type = "app"; … }`).
          # Lima materializers stay surfaced as apps for now; the Tart
          # materializer is intentionally not exposed (operators use
          # `nerd-tart-<host>-deploy` instead — it covers the same
          # workflow end-to-end).
          hostMaterializerApps = builtins.foldl' (
            acc: hostName:
            let
              hostSpec = hostCatalog.${hostName};
              mainName = hostMainNameForProfile hostSpec.hostProfile;
              hostOutput = hostOutputs.${hostName};
              limaMaterializerPackage =
                hostOutput.darwinConfiguration.config.lima.configGenerator.materializerPackage;
            in
            acc
            // {
              "${mainName}-lima-vm-materialize" = {
                type = "app";
                program = "${limaMaterializerPackage}/bin/${ndhVmLimaMaterializeAttr}";
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
          baremetalLinkApps = builtins.foldl' (
            acc: bm:
            acc
            // {
              "${bm.domain}-baremetal-link-deploy" = {
                type = "app";
                program = "${mkBaremetalLinkDeploy system bm}/bin/${bm.domain}-baremetal-link-deploy";
                meta.description = "Install/refresh (or --uninstall) the baremetal-link LaunchDaemon on vz.${bm.domain}";
              };
            }
          ) { } (builtins.attrValues baremetalLinkHosts);
          nixBuildObservePackage = mkNixBuildObservePackage system;
          pkgsForSystem = pkgsFor { inherit system; };
          # Run check-jsonschema against the canonical keys.yaml. The target
          # is sops-encrypted at rest, so we decrypt into a tempfile before
          # validating. Pass a path to validate a different file ad-hoc:
          #   nix run .#ssh-keys-v2-validate -- path/to/keys.yaml
          sshKeysValidatorPackage = pkgsForSystem.writeShellApplication {
            name = "ssh-keys-v2-validate";
            runtimeInputs = [
              pkgsForSystem.check-jsonschema
              pkgsForSystem.sops
            ];
            text = ''
              target="''${1:-modules/home-manager/ssh.d/keys.yaml}"
              schema="modules/home-manager/ssh.d/keys.schema.yaml"
              if [[ ! -r "$schema" ]]; then
                echo "schema not found at $schema (run from repo root)" >&2
                exit 1
              fi
              if [[ ! -r "$target" ]]; then
                echo "target yaml not found: $target" >&2
                exit 1
              fi
              tmp="$(mktemp -t ssh-keys-v2.XXXXXX.yaml)"
              trap 'rm -f "$tmp"' EXIT
              if ! sops -d "$target" > "$tmp" 2>/dev/null; then
                cp "$target" "$tmp"
              fi
              exec check-jsonschema --schemafile "$schema" "$tmp"
            '';
          };
          # Rotate the per-kind Tailscale SaaS auth keys in .secrets using the
          # long-lived OAuth client (tailnet.tailscale.client).  Kinds + tag
          # pairs are baked from catalog.tailnet.tags so the script needs no
          # runtime `nix eval`.  Safe by default (dry-run).  Script:
          # modules/.common.d/rotate-tailnet-secrets.d/rotate-tailnet-secrets.sh.
          tailnetAuthKindsSpec =
            let
              t = catalogData.tailnet.tags;
              pair =
                k:
                if k == "darwin" then
                  [
                    t.role.console
                    t.kind.${k}
                  ]
                else
                  [
                    t.role.headless
                    t.kind.${k}
                  ];
            in
            map (
              k:
              let
                tags = map (x: "tag:" + x) (pair k);
              in
              {
                inherit tags;
                kind = k;
                # Full Tailscale POST /keys request body, built here so the
                # script only reads/extracts JSON with yq-go (no runtime JSON
                # construction).  90-day expiry = the auth-key maximum.
                body = {
                  capabilities.devices.create = {
                    reusable = true;
                    ephemeral = false;
                    preauthorized = true;
                    inherit tags;
                  };
                  expirySeconds = 7776000;
                  description = "ndh ${k} per-kind auth key";
                };
              }
            ) (builtins.attrNames t.kind);
          tailnetAuthKindsFile = pkgsForSystem.writeText "tailnet-auth-kinds.json" (
            builtins.toJSON tailnetAuthKindsSpec
          );
          # Canonical Tailscale-SaaS ACL fragment, built from the catalog.  The
          # `--sync-acl` reconcile merges this into the LIVE tailnet policy
          # (preserving personal/k8s tags, nodeAttrs, and existing routes;
          # pruning the superseded operator/service/container tags).
          #
          # OAuth-client tag ownership follows the Tailscale-recommended pattern
          # (kb/1215/oauth-clients): a dedicated owner tag — assigned to the
          # rotation OAuth client in the console — owns the per-kind tags, so the
          # client may mint keys carrying them.  We keep the legacy `acls` block
          # (not `grants`) so the same tag vocabulary stays usable by the
          # headscale controller too; `ssh` uses `accept` per the single-operator
          # rationale in catalog/tailnet/acl.hujson.
          tailnetAclCanonical =
            let
              t = catalogData.tailnet.tags;
              tg = x: "tag:" + x;
              ownerTag = "tag:tailnet-key-owner";
              ourTags = [
                t.role.console
                t.role.headless
              ]
              ++ builtins.attrValues t.kind;
              bm = catalogData.netplan.baremetal or { };
              routeApprovers = builtins.listToAttrs (
                map (h: {
                  name = bm.${h}.advertiseCidr;
                  value = [ (tg t.kind.nixos) ];
                }) (builtins.filter (h: bm.${h} ? advertiseCidr) (builtins.attrNames bm))
              );
            in
            {
              tagOwners = {
                ${ownerTag} = [ "autogroup:admin" ];
              }
              // builtins.listToAttrs (
                map (x: {
                  name = tg x;
                  value = [ ownerTag ];
                }) ourTags
              );
              acls = [
                # Trusted owner devices (untagged members: laptop, phone) reach
                # everything.  Tagged fleet nodes below stay role-segmented.
                {
                  action = "accept";
                  src = [ "autogroup:members" ];
                  dst = [ "*:*" ];
                }
                {
                  action = "accept";
                  src = [ (tg t.role.console) ];
                  dst = [
                    "${tg t.role.console}:*"
                    "${tg t.role.headless}:*"
                  ];
                }
                {
                  action = "accept";
                  src = [ (tg t.role.headless) ];
                  dst = [ "${tg t.role.headless}:*" ];
                }
              ];
              ssh = [
                # Console (operator admin) hosts SSH the ENTIRE tailnet.  A bare
                # "*" is not a valid ssh dst, so we enumerate the exhaustive set:
                # every node is either a member device or carries a role tag.
                {
                  action = "accept";
                  src = [ (tg t.role.console) ];
                  dst = [
                    "autogroup:members"
                    (tg t.role.console)
                    (tg t.role.headless)
                  ];
                  users = [
                    "autogroup:nonroot"
                    "root"
                  ];
                }
                # Headless nodes SSH each other (nix copy, node-to-node ops).
                {
                  action = "accept";
                  src = [ (tg t.role.headless) ];
                  dst = [ (tg t.role.headless) ];
                  users = [
                    "autogroup:nonroot"
                    "root"
                  ];
                }
                # Member devices reach their own devices.
                {
                  action = "accept";
                  src = [ "autogroup:members" ];
                  dst = [ "autogroup:self" ];
                  users = [
                    "autogroup:nonroot"
                    "root"
                  ];
                }
              ];
              autoApprovers.routes = routeApprovers;
            };
          tailnetAclCanonicalFile = pkgsForSystem.writeText "tailnet-acl-canonical.json" (
            builtins.toJSON tailnetAclCanonical
          );
          # Bash-trampoline pattern: source the shared trampoline (nix-managed
          # bash + logger + stable env), pin every tool by absolute store path
          # (@sops@/@curl@/@yq@ — yq-go only, no jq), and bake the kinds + ACL
          # canonical files in.
          rotateTailnetSecretsPackage = ndhStoreApiDarwin.installBinScript "rotate-tailnet-secrets" (
            pkgsForSystem.replaceVars ./modules/.common.d/rotate-tailnet-secrets.d/rotate-tailnet-secrets.sh {
              nixBashTrampoline = ndhNixBashTrampolineDarwin;
              loggerTag = "ndh.rotate-tailnet-secrets";
              sops = "${pkgsForSystem.sops}/bin/sops";
              curl = "${pkgsForSystem.curl}/bin/curl";
              yq = "${pkgsForSystem.yq-go}/bin/yq";
              authKinds = tailnetAuthKindsFile;
              aclCanonical = tailnetAclCanonicalFile;
            }
          );
        in
        {
          nix-build-observe = {
            type = "app";
            program = "${nixBuildObservePackage}/bin/nix-build-observe";
          };
          ssh-keys-v2-validate = {
            type = "app";
            program = "${sshKeysValidatorPackage}/bin/ssh-keys-v2-validate";
          };
          rotate-tailnet-secrets = {
            type = "app";
            program = "${rotateTailnetSecretsPackage}/bin/rotate-tailnet-secrets";
            meta.description = "[operator-run · exec] Rotate per-kind Tailscale SaaS auth keys in .secrets (dry-run by default) — doc: modules/.common.d/rotate-tailnet-secrets.d/";
          };
        }
        // hostMaterializerApps
        // hostBootstrapInstallerApps
        // baremetalLinkApps
      );

      mkHostOutputs =
        {
          hostProfile,
          profileModule,
          darwinExtraModules ? [ ],
          nixosExtraModules ? [ ],
          withBringupImages ? true,
          pauseAfterInstall ? false,
          enableBuildObserve ? false,
          buildObserveInterval ? 5,
          linuxBuilderGcBeforeBuild ? true,
          ...
        }:
        let
          mainName =
            if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
              hostProfile.hostAlias
            else
              hostProfile.hostName;
          catalog = catalogData;

          # HM user identity, augmented with a resolved home directory.
          homeManagerUserWithHome = catalog.user // {
            home =
              if catalog.user ? home && catalog.user.home != null then
                catalog.user.home
              else
                "/Users/${catalog.user.name}";
          };
          hostUserProfile = {
            host = hostProfile;
            user = homeManagerUserWithHome;
            email = homeManagerUserWithHome.email;
          };
          nixosOutputs = mkNixosOutputs {
            inherit hostProfile catalog;
            inventory = inventoryData;
            inherit pauseAfterInstall enableBuildObserve buildObserveInterval;
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
                  worktreePath
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
                    {
                      lima.configGenerator.diskSizeGiB = nixosDiskSizeGiB;
                      tart.configGenerator.linuxBuilderGcBeforeBuild = linuxBuilderGcBeforeBuild;
                      tart.configGenerator.enableBuildObserve = enableBuildObserve;
                      tart.configGenerator.buildObserveInterval = buildObserveInterval;
                    }
                    // lib.optionalAttrs withBringupImages {
                      lima.configGenerator.imageManifestPath = "${nixosDiskImageBringupSystemdZfs}/manifest.yaml";
                      lima.configGenerator.imageStorePath = "${nixosDiskImageBringupSystemdZfs}/boot.img";
                      lima.configGenerator.runtimeSystemPath = nixosOutputs.runtimeSystem;

                      tart.configGenerator.rawImageManifestPath = "${nixosDiskImageBringupSystemdZfs}/manifest.yaml";
                      tart.configGenerator.rawImageStorePath = "${nixosDiskImageBringupSystemdZfs}/boot.img";
                      tart.configGenerator.runtimeSystemPath = nixosOutputs.runtimeSystem;
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

          # Home Manager configuration for the single host user.
          homeManagerConfigurations = {
            default = mkHomeManagerConfig hostUserProfile;
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
          homeManagerConfiguration = homeManagerConfigurations.default;
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

      hostOutputs = forAllHosts (_: hostSpec: mkHostOutputs (hostSpec // hostGateOverrides));

      darwinConfigurations = builtins.foldl' (
        acc: hostOutput: acc // hostOutput.darwinConfigurations
      ) { } (builtins.attrValues hostOutputs);

      # Per-host nixosConfigurations expose `${name}-bringup` (per-host bringup
      # binding), `${name}-tart` (canonical runtime), and `${name}-nixos`
      # (host-named runtime alias). The fleet-wide `nerd-nixos` bringup alias
      # is added once at the top level — its bytes are identical for every
      # host and Nix dedups the underlying derivation.
      nixosConfigurations =
        let
          merged = builtins.foldl' (acc: hostOutput: acc // hostOutput.nixosConfigurations) { } (
            builtins.attrValues hostOutputs
          );
          anyHostName = builtins.head (builtins.attrNames hostCatalog);
          anyMainName = hostMainNameForProfile hostCatalog.${anyHostName}.hostProfile;
        in
        merged
        // {
          nerd-nixos = merged."${anyMainName}-bringup";
        };

      # Provider-scoped VM configuration aliases (full runtime systems, not bringup).
      # Lima variant was retired — only Tart remains.
      vmConfigurations =
        let
          mkVmHostAliases =
            hostName: hostSpec:
            let
              mainName = hostMainNameForProfile hostSpec.hostProfile;
              hostNixosConfigurations = hostOutputs.${hostName}.nixosConfigurations;
            in
            {
              tart.system = hostNixosConfigurations."${mainName}-tart";
            };

          vmAliasesByHost = forAllHosts mkVmHostAliases;
        in
        {
          tart = builtins.mapAttrs (_: hostAliases: hostAliases.tart) vmAliasesByHost;
        };

      homeManagerConfigurations = builtins.mapAttrs (
        _: hostOutput: hostOutput.homeManagerConfigurations
      ) hostOutputs;

      # The bringup image is identity-less (see modules/nixos/outputs.nix
      # `minimalBringupSystemBase`): bytes are bit-identical for every host
      # on the fleet, so a single fleet-wide attribute is correct here.
      # Per-host `${name}-bringup` nixosConfigurations remain available in
      # `self.nixosConfigurations` for tooling that needs the per-host
      # binding (e.g. nixos-rebuild --flake .#${name}-bringup).
      nixosDiskImages =
        let
          anyHostName = builtins.head (builtins.attrNames hostCatalog);
        in
        {
          nerd = hostOutputs.${anyHostName}.nixosDiskImageBringupSystemdZfs;
        };

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
            flox = inputs.flox.packages.${hostSystem}.default;
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
        profile = import ./profile.nix;
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
