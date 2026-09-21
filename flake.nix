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
    flake-commons.url = "github:seedmatic/nix-flake-commons/develop";

    # 2. Aggregator passthroughs (alphabetized)
    bird.follows = "flake-commons/bird";
    cachix.follows = "flake-commons/cachix";
    chromium-bin.follows = "flake-commons/chromium-bin";
    darwin.follows = "flake-commons/darwin";
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

    # claude-hub provides the dynamic CLAUDE_CONFIG_DIR wrapper and shared
    # Claude Code tooling. Direct input (not via flake-commons) as it's
    # project-local infrastructure. Share the family version set via
    # flake-commons to dedup nixpkgs/flake-utils.
    claude-hub = {
      url = "github:seedmatic/claude-hub/main";
      inputs.flake-commons.follows = "flake-commons";
    };

    # rke2lab is the source of truth for the cluster network underlay (cluster/
    # node IDs, MAC derivation, addressing); the catalog consumes its flat
    # `lib.networkBlueprint` rather than hand-inlining MAC/IP values — the
    # BUILD/eval-time edge nix-darwin-home -> rke2lab. This is now a MUTUAL edge:
    # rke2lab in turn consumes ndh's `catalog.netplan.lan` (Direction A, the
    # home-LAN federation). So, exactly like the nnh input below, it is cut with
    # a reciprocal EMPTY follows (rke2lab's back-reference to ndh follows THIS
    # root), breaking the lock cycle while both flakes still build standalone.
    # See the hub memory flake-mutual-dependency-follows-root.
    # rke2lab is NOT routed through flake-commons (it already depends on
    # flake-commons, which would form a flake-commons <-> rke2lab cycle).
    # rke2lab defines its own `flake-commons` (github:seedmatic/nix-flake-commons,
    # the same source as ours) and follows nixpkgs/flox/sops-nix/… through it; we
    # pin `rke2lab.inputs.flake-commons.follows = "flake-commons"` so that whole
    # set resolves against ours — one shared flake-commons closure, not two in the lock.
    rke2lab = {
      url = "github:seedmatic/rke2lab/feature/nixos-node-substrate";
      inputs.ndh.follows = "";
      inputs.flake-commons.follows = "flake-commons";
    };

    # Federation: ndh unions nnh's self-contained lib.networkBlueprint (its
    # bare-br segments) alongside rke2lab's. nnh also consumes ndh's catalog, so
    # this is a mutual edge — cut with a reciprocal EMPTY follows (nnh's
    # back-reference to ndh follows THIS root). See the hub memory
    # flake-mutual-dependency-follows-root.
    nnh = {
      url = "github:seedmatic/nnh/main";
      inputs.ndh.follows = "";
      # Share the family version set: dedup nnh's flake-commons subtree
      # (devenv/cachix/bird/…) with ndh's so importing nnh for its blueprint
      # does not balloon the lock. akvorado stays (nnh-specific) but is never
      # forced — we read only nnh.lib.networkBlueprint.
      inputs.flake-commons.follows = "flake-commons";
    };

    # Forked tailscale carrying our patches (see overlays/tailscale.nix):
    # the CNAME-in-extra_records resolver support and the SSH-interception
    # port-2222 switch, rebased onto upstream's release-branch/1.102 as the
    # single `nxmatic/integration/1.102` branch. The fork is consumed as a
    # real flake — it builds itself via upstream tailscale's own
    # `flakehashes.json` (vendorHash + go-toolchain SRI, kept in sync with
    # go.mod by upstream), so vendorHash is decoupled from whatever
    # tailscale version nixpkgs-unstable happens to ship. `nixpkgs` is
    # pinned to flake-commons so the fork's binaries share a
    # glibc/openssl/etc with the rest of the closure.
    tailscale-fork = {
      url = "github:nxmatic/tailscale/nxmatic/integration/1.102";
      inputs.nixpkgs.follows = "flake-commons/nixpkgs-unstable";
    };
  };

  outputs =
    {
      self,
      darwin,
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
      # Cluster underlay from rke2lab, UNIONED with nnh's self-contained blueprint
      # (its bare-br segments; nnh introduces no ASNs). Both edges are cut with
      # reciprocal empty follows — see the rke2lab / nnh inputs. Only segments+asns
      # merge; everything else (clusters, nodes, addressing, MACs) stays rke2lab's.
      rke2labBlueprint = inputs.rke2lab.lib.networkBlueprint;
      nnhBlueprint = inputs.nnh.lib.networkBlueprint;
      networkBlueprint = rke2labBlueprint // {
        segments = (rke2labBlueprint.segments or [ ]) ++ (nnhBlueprint.segments or [ ]);
        asns = (rke2labBlueprint.asns or { }) // (nnhBlueprint.asns or { });
      };
      # rke2lab also owns the cluster ZFS dataset LAYOUT (the dataplan — the storage twin of the
      # networkBlueprint), pulled the same way and merged into catalog.datasets, materialised on the
      # host by zfs-disko-config.nix.
      dataplan = inputs.rke2lab.lib.dataplan;
      # …and the PUBLIC half of the `capn-provider` client certificate, pulled the same way. rke2lab
      # owns that identity (its in-cluster CAPN provider authenticates to Incus with it); ndh owns the
      # node's Incus trust store, which is daemon state — so the entry has to be re-asserted here, not
      # typed once by hand.
      capnProviderCert = inputs.rke2lab.lib.capnProviderCert;
      catalogData = import ./catalog/default.nix {
        inherit
          cacheTrust
          networkBlueprint
          dataplan
          capnProviderCert
          ;
      };
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
      # nixpkgs-unstable, only for packages the pinned (flake-commons) nixpkgs
      # lacks yet — e.g. darwin.linux-builder-vz (absent from 26.05, present in
      # unstable). Used by the bootstrap-linux-builder app; keep the surface
      # minimal so we don't drift the fleet onto unstable wholesale.
      pkgsUnstableForDarwin = import inputs.nixpkgs-unstable {
        system = "aarch64-darwin";
        config = nixpkgsConfig // {
          allowBroken = true;
          checkAllPackages = false;
        };
      };

      mkNdhStoreApiFor =
        pkgsForSystem:
        let
          storeNamePrefix = "io.seedmatic.ndh";
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
            # meta.mainProgram = the UNPREFIXED bin so `nix run <pkg>` resolves the
            # right executable: the derivation is named `prefixedName name`
            # (io.seedmatic.ndh-<name>) but the bin is `bin/<name>`, so without
            # mainProgram `nix run` guesses bin/<pname> (prefixed) → "No such file"
            # when resolved as a package (e.g. on a system with no matching apps.*
            # entry — the aarch64-linux guest running the baremetal-link deploy).
            pkgsForSystem.runCommand (prefixedName name) { meta.mainProgram = name; } ''
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
              elif [[ -d "/private/var/lib/git/seedmatic/ndh" ]]; then
                repo_root="/private/var/lib/git/seedmatic/ndh"
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
      # Connects a CORPORATE bare-metal Mac (vzhost.<host>) that cannot join the tailnet
      # to its Incus instance segment: a static /30 en0 alias + routes to the /25
      # and the no-NAT tailnet return path, re-applied on Wi-Fi re-association (a
      # WatchPaths LaunchDaemon).  Only baremetal hosts with a `linkCidr` — an
      # off-tailnet corp Mac reached over a /30 — get one; on-tailnet bare-metals
      # (bioskop) declare none.  Rendered from catalog.netplan.baremetal.<host> and
      # delivered as TEXT (no nix runtime, bash-3.2 ok on the target), so the deploy
      # runs from any host that resolves vzhost.<host> — the operator's Mac or the
      # nikopol-nixos activation oneshot.  See docs/network-topology-c4.adoc +
      # pkgs/baremetal-link.d/.
      baremetalLinkHosts = nixpkgs.lib.filterAttrs (_: bm: bm ? linkCidr) catalogData.netplan.baremetal;

      baremetalLinkLabel = "io.seedmatic.baremetal-link";

      # Common addressing tokens both install.sh and uninstall.sh take from the
      # catalog — single-sourced so the teardown undoes exactly what install set.
      baremetalLinkVars = bm: {
        interface = "en0";
        vzHostAddress = bm.vzHostAddress;
        netCidr = bm.netCidr;
        tailnetCidr = catalogData.netplan.tailnet.cidr;
        hostAddress = bm.hostAddress;
        domain = bm.domain;
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
            netGateway = bm.netGateway;
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
          ndhStoreApi = mkNdhStoreApiFor pkgsForSystem;
          trampoline =
            if system == "aarch64-darwin" then ndhNixBashTrampolineDarwin else ndhNixBashTrampolineLinux;
        in
        # Bash-trampoline pattern (like manage-tailnet): source the shared
        # trampoline (nix bash + logger + stable env), pin ssh by store path, and
        # run under ndh::logger:command:run so the full ssh pipe lands in the
        # unified log.  ssh is pinned rather than a runtimeInputs PATH entry
        # because the trampoline owns PATH.
        ndhStoreApi.installBinScript "${bm.domain}-baremetal-link-deploy" (
          pkgsForSystem.replaceVars ./pkgs/baremetal-link.d/deploy.sh {
            nixBashTrampoline = trampoline;
            loggerTag = "ndh.baremetal-link-deploy";
            ssh = "${pkgsForSystem.openssh}/bin/ssh";
            installScript = "${mkBaremetalLinkInstall system bm}";
            uninstallScript = "${mkBaremetalLinkUninstall system bm}";
            vzHost = "vzhost.${bm.domain}";
            bootstrapHost = "${bm.domain}.local";
            # Where the enrich pipeline lands the vz-nudge private+cert (usage
            # ssh-host → root-owned systemKeysDir). Read at runtime by deploy.sh and
            # shipped to the target so link-up.sh can auth the guest nudge. Matches
            # modules/.common.d/ssh-paths.nix `systemKeysDir` default. deploy.sh also
            # reads ${systemKeysDir}/rdp-host{,-cert.pub} from here as the vzhost
            # login identity (root-readable; the activation oneshot runs as root).
            systemKeysDir = "/var/lib/ndh/ssh-keys";
            # vzhost's OS login. The corp Mac refuses root ssh AND is off the
            # nix-darwin fleet, so its username is not derivable from a host config;
            # it is the operator's corp account. No single catalog source of truth
            # exists for it (already duplicated across the repo, e.g.
            # modules/home-manager/ssh-tailnet-hosts.nix), so it is duplicated here.
            vzUser = "stephane.lacoin";
          }
        );

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
        mkFleetRuntimeConfig
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
          ndhNixBashTrampoline =
            if system == "aarch64-darwin" then ndhNixBashTrampolineDarwin else ndhNixBashTrampolineLinux;
        in
        {
          # manage-tailnet on PATH for BOTH systems (a packages output, not just the app):
          # rke2lab's flox-catalogue re-exports packages.aarch64-linux.manage-tailnet so the
          # in-cluster tailnet-purge Job installs it via a FloxEnv. Wired to the PER-SYSTEM
          # store API + trampoline so it builds on aarch64-linux too — the script is bash +
          # curl + yq, cross-platform. On aarch64-darwin these resolve to the same Darwin
          # helpers as before, so the darwin build is unchanged (same store path).
          manage-tailnet = import ./modules/.common.d/manage-tailnet.d {
            pkgs = systemPkgs;
            catalog = catalogData;
            ndhStore = ndhStoreApi;
            nixBashTrampoline = ndhNixBashTrampoline;
          };
          # The fork tailscale/tailscaled (CNAME extra_records + SSH port-2222)
          # as a first-class packages output — systemPkgs already has
          # tailscaleOverlay applied (see overlays/tailscale.nix), so this just
          # re-exports the patched build. rke2lab's flox-catalogue consumes
          # packages.aarch64-linux.tailscale so the in-cluster mesh tailscaled
          # runs the fork, matching the operator host.
          inherit (systemPkgs) tailscale;
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
          # The git sops clean/smudge filter as a self-contained package — the SSOT the
          # operator's home-manager git AND rke2lab's flox-catalogue (re-exported for the
          # in-cluster render env) both consume, so the filter that encrypts `.secrets` on
          # a commit is byte-for-byte the one that smudges it in the aarch64-linux render
          # pod. See modules/home-manager/git.d/git-sops-filter.nix.
          git-sops-filter = systemPkgs.callPackage ./modules/home-manager/git.d/git-sops-filter.nix { };
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
          #   nerd-tart                    — generic, fleet-wide deploy bundle
          #   nerd-tart-<host>-config      — per-VM YAML manifest (scp to vz)
          #   nerd-tart-<host>-deploy      — operator helper: copy + activate on a REMOTE vz host
          #   nerd-tart-<host>-materialize — LOCAL materializer for the host that runs the VM
          # `-materialize` is the local counterpart of `-deploy`: on a host whose
          # activation hook is off (`vmMaterializerEnableActivationHook = false`)
          # and that runs the Tart VM itself (not a remote vz host), it is the only
          # entry point to (re)materialize the VM — e.g.
          # `VM_FACTORY_RESET=true nix run .#nerd-tart-bioskop-materialize`.
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
                  # matching `vzhost.<mainName>` ssh alias on the operator's
                  # home-manager (see modules/home-manager/ssh-tailnet-hosts.nix).
                  # Override by passing a host as the first positional argument.
                  vz_host="vzhost.${mainName}"
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
                  (default: vzhost.${mainName}); installs the YAML at
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
                  # the bare-metal vz host share a LAN, while `vzhost.<host>`
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
                "nerd-tart-${mainName}-config" = runManifest;
                "nerd-tart-${mainName}-deploy" = mkDeployHelper {
                  inherit mainName runManifest;
                  vmName = hostOutput.darwinConfiguration.config.tart.configGenerator.vmName;
                };
                "nerd-tart-${mainName}-materialize" =
                  hostOutput.darwinConfiguration.config.tart.configGenerator.materializerPackage;
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
            # manage-tailnet moved to the common (both-systems) body above — it now builds
            # for aarch64-linux too (per-system store API + trampoline), so the darwin-only
            # copy here is gone.
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
          # The Tart materializer is exposed under `packages.<system>` as
          # `nerd-tart-<host>-materialize` (its `meta.mainProgram` lets
          # `nix run .#nerd-tart-<host>-materialize` work), not duplicated here.
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
                meta.description = "Install/refresh the NDH bringup-runtime nix profile for ${mainName} — src: modules/.common.d/bringup-runtime.d/";
              };
              "${mainName}-log-capture" = {
                type = "app";
                program = "${logCapture}/bin/${ndhLogCaptureCommand}";
                meta.description = "Capture ${mainName}'s build + activation logs (Vector telemetry) — src: flake.nix (mkNdhLogCapturePackage)";
              };
              "${mainName}-tart-vm-bootstrap-installer" = {
                type = "app";
                program = "${tartBootstrapInstaller}/bin/${ndhVmTartBootstrapInstallerAttr}";
                meta.description = "Install ${mainName}'s Tart NixOS bringup VM (disk image -> ZFS) — src: flake.nix (mkNdhVmTartBootstrapInstallerPackage)";
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
                meta.description = "Install/refresh (or --uninstall) the baremetal-link LaunchDaemon on vzhost.${bm.domain} — src: pkgs/baremetal-link.d/";
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
          # manage-tailnet: administer the tailnet (rotate auth keys / sync-acl /
          # retag / prune stale devices).  The recipe is extracted to package.nix
          # so it is exposed BOTH here (the app) and as packages.<system>.manage-tailnet
          # (for PATH consumers — the flox env, another flake's runtimeInputs).
          manageTailnetPackage = import ./modules/.common.d/manage-tailnet.d {
            pkgs = pkgsForSystem;
            catalog = catalogData;
            ndhStore = ndhStoreApiDarwin;
            nixBashTrampoline = ndhNixBashTrampolineDarwin;
          };
          bboxReconcilePackage = import ./modules/.common.d/bbox-reconcile.d/package.nix {
            pkgs = pkgsForSystem;
            lib = nixpkgs.lib;
            catalog = catalogData;
            inherit worktreePath;
          };
          # Operator ceremony: mint/rotate a self-signed TLS root for a keys.yaml
          # authority. Hermetic — every tool the script's preconditions name is
          # pinned here, so `nix run` works off any dev env. Runs from the repo cwd
          # (git rev-parse --show-toplevel), reading/re-encrypting keys.yaml in place.
          authorityBootstrapTlsRootPackage = pkgsForSystem.writeShellApplication {
            name = "authority-bootstrap-tls-root";
            runtimeInputs = [
              pkgsForSystem.git
              pkgsForSystem.step-cli
              pkgsForSystem.sops
              pkgsForSystem.yq-go
              pkgsForSystem.openssh
              pkgsForSystem.coreutils
            ];
            text = builtins.readFile ./modules/.common.d/authority-bootstrap-tls-root.d/authority-bootstrap-tls-root.sh;
          };
          # System-admin helper: prune darwin/HM/user generations + GC. Drives the
          # AMBIENT sudo + system nix daemon (a pinned nix would desync from it), so
          # runtimeInputs stays empty — writeShellApplication PREPENDS to PATH, it
          # does not reset it, so ambient tooling stays reachable.
          cleanupActivationsPackage = pkgsForSystem.writeShellApplication {
            name = "cleanup-activations";
            runtimeInputs = [ ];
            text = builtins.readFile ./modules/.common.d/cleanup-activations.d/cleanup-activations.sh;
          };
          # Temporary local vz linux-builder for the bootstrap phase (cold start,
          # no aarch64-linux builder yet). runtimeInputs carries ONLY the vz
          # builder (for `create-builder`) — NOT sudo: writeShellApplication
          # prepends to PATH, so the ambient setuid /usr/bin/sudo (the wrapper)
          # stays in reach for both this script and create-builder's own
          # install-credentials. Pinning a nixpkgs sudo would shadow it.
          # The stock vz builder boots tiny (1 vCPU / ~3 GiB RAM / 20 GiB store →
          # OOM and "no space left" on real closures). bioskop has ample RAM, so
          # bake a generous guest. These are read by the vz VM at build time
          # (nixos/modules/virtualisation/vz-vm.nix: cpuCount = cfg.cores,
          # memorySizeMiB = cfg.memorySize, dd seek = cfg.diskSize; cfg =
          # config.virtualisation.darwin-builder), so they must be set here, not
          # at runtime. diskSize is sparse (dd seek), so a large cap costs
          # nothing until used. mkForce overrides the profile defaults.
          bootstrapLinuxBuilderVz = pkgsUnstableForDarwin.darwin.linux-builder-vz.override {
            modules = [
              (
                { lib, ... }:
                {
                  # cpuCount is read straight off virtualisation.cores (vz-vm.nix);
                  # memorySize/diskSize are darwin-builder knobs that nix-builder.nix
                  # maps onto virtualisation.memorySize / virtualisation.diskSize.
                  virtualisation.cores = lib.mkForce 8;
                  virtualisation.darwin-builder.memorySize = lib.mkForce 16384; # MiB (16 GiB)
                  virtualisation.darwin-builder.diskSize = lib.mkForce 102400; # MiB (100 GiB, sparse)
                }
              )
            ];
          };
          bootstrapLinuxBuilderPackage = pkgsForSystem.writeShellApplication {
            name = "bootstrap-linux-builder";
            runtimeInputs = [ bootstrapLinuxBuilderVz ];
            text = builtins.readFile ./modules/.common.d/bootstrap-linux-builder.d/bootstrap-linux-builder.sh;
          };
        in
        {
          nix-build-observe = {
            type = "app";
            program = "${nixBuildObservePackage}/bin/nix-build-observe";
            meta.description = "Stream nix build telemetry to the observability sink — src: modules/darwin/bringup-observe.d/";
          };
          ssh-keys-v2-validate = {
            type = "app";
            program = "${sshKeysValidatorPackage}/bin/ssh-keys-v2-validate";
            meta.description = "Validate ssh keys.yaml against its JSON schema (sops-decrypts first) — src: modules/home-manager/ssh.d/keys.schema.yaml";
          };
          manage-tailnet = {
            type = "app";
            program = "${manageTailnetPackage}/bin/manage-tailnet";
            meta.description = "Manage the tailnet: rotate per-kind Tailscale auth keys, reconcile the ACL, retag + prune stale devices (dry-run by default) — src: modules/.common.d/manage-tailnet.d/";
          };
          bbox-reconcile = {
            type = "app";
            program = "${bboxReconcilePackage}/bin/bbox-reconcile";
            meta.description = "Diff catalog.netplan.lan.hosts against the bbox /dhcp/clients reservations (read-only) — src: modules/.common.d/bbox-reconcile.d/";
          };
          authority-bootstrap-tls-root = {
            type = "app";
            program = "${authorityBootstrapTlsRootPackage}/bin/authority-bootstrap-tls-root";
            meta.description = "Mint/rotate a self-signed TLS root for a keys.yaml authority — <authority> [--force|--create <keyType>], run from repo root — src: modules/.common.d/authority-bootstrap-tls-root.d/";
          };
          cleanup-activations = {
            type = "app";
            program = "${cleanupActivationsPackage}/bin/cleanup-activations";
            meta.description = "Prune nix-darwin/Home-Manager/user generations + GC (DRY_RUN=1 to preview) — src: modules/.common.d/cleanup-activations.d/";
          };
          bootstrap-linux-builder = {
            type = "app";
            program = "${bootstrapLinuxBuilderPackage}/bin/bootstrap-linux-builder";
            meta.description = "Cold-start: launch a temporary local vz linux-builder + wire the nix-daemon to it so `nixos-rebuild .#<host>-nixos` can build aarch64-linux (--stop to tear down) — src: modules/.common.d/bootstrap-linux-builder.d/";
          };
        }
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
          nixosDiskoConfiguration = nixosOutputs.diskoConfiguration;
          mkHomeManagerConfig =
            profile:
            let
              vmConfigMaterializerPackage =
                if !withBringupImages then
                  null
                else
                  darwinOutputs.darwinConfigurations.${mainName}.config.tart.configGenerator.materializerPackage;
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
                  vmProvider = hostProfile.vmProvider or "tart";
                  nixBashTrampoline = ndhNixBashTrampolineDarwin;
                };
                ndhStore = ndhStoreApiDarwin;
                keysYamlPath = "${toString profile.user.home}/.local/var/run/secrets/sops/ssh-keys.yaml";
                claude-hub = inputs.claude-hub;
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
                      tart.configGenerator.linuxBuilderGcBeforeBuild = linuxBuilderGcBeforeBuild;
                      tart.configGenerator.enableBuildObserve = enableBuildObserve;
                      tart.configGenerator.buildObserveInterval = buildObserveInterval;
                    }
                    // lib.optionalAttrs withBringupImages {
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
          # The same placeholder host in FULL mode — the fleet-generic runtime
          # whose closure is the stack's middle EROFS layer.  Exposed so it can be
          # built and inspected on its own; the image build gets it from
          # mkNixosOutputs, which shares this one definition.
          nerd-runtime = mkFleetRuntimeConfig {
            catalog = catalogData;
            inventory = inventoryData;
          };
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

      # One bundle PER HOST.  The bringup *system* is still identity-less, but the
      # bundle stopped being so when the runtime closure moved into the layer
      # stack: the installer script bakes the union closure's registration and a
      # GC root on the host runtime toplevel, so its derivation differs per host
      # (verified: bioskop 4q24ly07…, nikopol jr2h199c…).  A single `nerd`
      # attribute taking an arbitrary host's bundle therefore shipped whichever
      # host sorted first, layer 003 carrying that host's residue.
      nixosDiskImages = builtins.mapAttrs (
        _: hostOutput: hostOutput.nixosDiskImageBringupSystemdZfs
      ) hostOutputs;

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
        incusOverlay = inputs: import ./overlays/incus.nix inputs;
        lazygitOverlay = inputs: import ./overlays/lazygit.nix inputs;
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

    };
}
