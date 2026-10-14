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
  #
  # Every SEEDMATIC-owned input below is an INDIRECT id (`url = "flake-commons"`),
  # resolved through nix's registry: the branch-less default targets live in the
  # committed flake-registry.json, and the operator re-aims one by dropping a
  # flake-registry.local.json beside it (see the [hook] in .flox/env/manifest.toml).
  #
  # Why, and it is not a preference: this chain is PUSH-GATED, so a branch named here
  # could only be re-aimed by pushing an edit to this file — which is precisely how the
  # same pin rotted twice, advancing along a line nobody was on without ever erroring.
  # Naming no branch means naming nothing that can be deleted.
  #
  # Hermeticity is unaffected, measured: an indirect id is consulted only when
  # RE-locking. flake.lock still records a revision, so anyone evaluating this flake
  # from the lock — with no registry at all — resolves exactly what we resolved.
  inputs = {
    # 1. Aggregator pin
    flake-commons.url = "flake-commons";

    # 2. Aggregator passthroughs (alphabetized)
    chromium-bin.follows = "flake-commons/chromium-bin";
    darwin.follows = "flake-commons/darwin";
    disko.follows = "flake-commons/disko";
    flake-compat.follows = "flake-commons/flake-compat";
    flake-utils.follows = "flake-commons/flake-utils";
    flox.follows = "flake-commons/flox";
    home-manager.follows = "flake-commons/home-manager";
    impermanence.follows = "flake-commons/impermanence";
    lix-module.follows = "flake-commons/lix-module";
    maven-mvnd.follows = "flake-commons/maven-mvnd";
    nix.follows = "flake-commons/nix";
    nixos-hardware.follows = "flake-commons/nixos-hardware";
    nixpkgs.follows = "flake-commons/nixpkgs";
    nixpkgs-unstable.follows = "flake-commons/nixpkgs-unstable";

    # 3. Direct inputs (not aggregated upstream)
    sops-nix.url = "github:Mic92/sops-nix";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    # The fabric's two deliveries, pinned as DATA rather than as the flakes that produce them.
    # rke2lab's plan is the source of truth for the cluster network underlay (cluster/node IDs,
    # MACs, addressing) and for the cluster dataset layout: netplan.json and dataplan.json on its
    # fabric/plan orphan, which rke2lab's publish-plan writes. nnh's contribution is its fabric-br
    # segments: network-blueprint.json on its fabric/contribution orphan. ndh used to pin rke2lab
    # and nnh themselves, each of which pins ndh back — two cycles, cut at the lock by reciprocal
    # empty follows. An orphan pins nothing, so no cycle is left to cut.
    fabric-plan.url = "fabric-plan";
    fabric-plan.flake = false;
    nnh-contribution.url = "nnh-contribution";
    nnh-contribution.flake = false;

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
      impermanence,
      nixpkgs,
      ...
    }@inputs:
    let
      inherit (flake-utils.lib) eachSystemMap;
      nixpkgsConfig = import ./modules/.common.d/nixpkgs-config.nix;
      cacheTrust = import ./catalog/cache-trust.nix;
      inventoryData = import ./inventory/default.nix;
      # The cluster underlay is rke2lab's plan, UNIONED with nnh's contribution (its fabric-br
      # segments; nnh introduces no ASNs) — both read from their pinned deliveries (see the
      # fabric-plan / nnh-contribution inputs). Only segments+asns merge; everything else
      # (clusters, nodes, addressing, MACs) stays rke2lab's.
      rke2labBlueprint = builtins.fromJSON (builtins.readFile "${inputs.fabric-plan}/netplan.json");
      nnhBlueprint = builtins.fromJSON (
        builtins.readFile "${inputs.nnh-contribution}/network-blueprint.json"
      );
      networkBlueprint = rke2labBlueprint // {
        segments = (rke2labBlueprint.segments or [ ]) ++ (nnhBlueprint.segments or [ ]);
        asns = (rke2labBlueprint.asns or { }) // (nnhBlueprint.asns or { });
      };
      # rke2lab also owns the cluster ZFS dataset LAYOUT (the dataplan — the storage twin of the
      # networkBlueprint), delivered beside it and merged into catalog.datasets, materialised on the
      # host by zfs-disko-config.nix.
      dataplan = builtins.fromJSON (builtins.readFile "${inputs.fabric-plan}/dataplan.json");
      # `hostForms` lets the catalog derive each vz-host's kind instead of declaring it: the
      # vz-host is nix-managed exactly when the config named <host> is the bare metal itself.
      # Injected from here because this file owns the host tree; see catalog/default.nix.
      # The ONE identity the incus cluster-cert closure reaches a member with: the OPERATOR
      # principal's key on the seat, read from bioskop's configuration (sshPaths, the profile
      # user) so it is never retyped. Step 9 moves it from rdp-host to the `operator` key here.
      # Roles × keys 6a: every name a fleet host or guest answers to, the union ONE host certificate is
      # signed for on the seat (ssh-keys-certify). Each inventory host, and each guest read from its own
      # configuration (vm.guestHostName, and vm.guestName.vm.hostName, the bare-metal's dnsmasq zone), in
      # the bare, .lan, .local and <ssh authority domain> forms. Computed, never retyped.
      fleetHostPrincipals =
        let
          lib = nixpkgs.lib;
          authorities = lib.filterAttrs (
            _: a: lib.elem "ssh-authority" (a.usage or [ ])
          ) self.darwinConfigurations.bioskop.config.ndh.keysYaml.authorities;
          domain =
            assert lib.assertMsg (lib.length (lib.attrNames authorities) == 1)
              "fleetHostPrincipals: exactly one ssh-authority is expected, found ${toString (lib.attrNames authorities)}";
            (lib.head (lib.attrValues authorities)).domain;
          forms = name: [
            name
            "${name}.lan"
            "${name}.local"
            "${name}.${domain}"
          ];
          hosts = lib.attrNames inventoryData.hosts;
          guests = lib.concatMap (
            host:
            lib.optional (
              self.nixosConfigurations ? "${host}-nixos"
            ) self.nixosConfigurations."${host}-nixos".config.vm
          ) hosts;
        in
        lib.sort lib.lessThan (
          lib.unique (
            lib.concatMap forms hosts
            ++ lib.concatMap (vm: forms vm.guestHostName ++ [ "${vm.guestName}.${vm.hostName}" ]) guests
          )
        );

      incusCertOperatorIdentity =
        let
          seat = self.darwinConfigurations.bioskop.config;
        in
        {
          user = seat.profile.user.name;
          keyFile = seat.sshPaths.privKeyFile;
          certFile = seat.sshPaths.userCertPublic;
        };
      catalogData = import ./catalog/default.nix {
        inherit cacheTrust networkBlueprint dataplan;
        hostForms = builtins.mapAttrs (_: entry: entry.hostProfile.form or null) hostCatalog;
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
        basePackages.extend applyOverlays;
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

            # Which revision of THIS repo is running was not answerable from a host: the only
            # revisions a host exposed were nixpkgs' (`nixosVersion`) and nix-darwin's
            # (`darwinRevision`), so "what is deployed?" had to be reconstructed by hypothesis —
            # and it was wrong at least once, when bioskop switched AFTER nikopol yet with the
            # older configuration. Now `nixos-version --json` and `darwin-version --json` say it.
            # Set here rather than per assembly site because this list feeds both nixos and
            # darwin. `dirtyRev` is the fallback for an uncommitted tree; null when the flake is
            # evaluated outside a git tree at all.
            #
            # ⚠️ This reaches 9 of the 12 configurations — the 4 darwin and the 5 FULL nixos.
            # The three bringup ones cannot carry it, for a reason specific to them: they force
            # `disableInstallerTools`, which removes the only program that consumes the option.
            # See minimalBringupSystemBase in modules/nixos/outputs.nix. Discriminator, if this
            # is ever claimed again: whether the toplevel drv hash MOVES between two revisions —
            # a config can report the option at eval and still not carry it at build.
            system.configurationRevision = self.rev or self.dirtyRev or null;
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
                requiredCommands = "bash nix age age-keygen awk sed grep ssh ssh-keygen sops step yq git";
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

      # --- baremetal-link (vz-host IP-alias daemon) -----------------------------
      # Connects a bare-metal Mac (vzhost.<host>) to its Incus instance segment: a static
      # /30 alias on the NIC its vz guest is bridged onto, plus the routes that reach the
      # segment, re-applied whenever that link comes back (a WatchPaths LaunchDaemon).
      # Every baremetal host with a `linkCidr` gets one — BOTH of them do, for different
      # reasons: nikopol's corp Mac is off-tailnet so the /30 is its only path in, while
      # bioskop's Mac is reachable itself but not from its own tenants (see
      # catalog.netplan.baremetal.bioskop).
      #
      # `vzHostKind` decides the DELIVERY. A `foreign` vz-host (nikopol's JAMF Mac: no nix,
      # no tailscale) gets the daemon rendered as TEXT and piped over ssh — no nix runtime
      # on the target, bash-3.2 ok — run by the operator or by <host>-nixos at activation.
      # A `nix-managed` vz-host declares the same daemon in its own darwin config instead
      # (modules/darwin/baremetal-link.nix), so `darwin-rebuild switch` delivers it; it gets
      # no deploy app, because a second delivery path for one daemon is a way to drift.
      # See docs/network-topology-c4.adoc + pkgs/baremetal-link.d/.
      baremetalLinkHosts = nixpkgs.lib.filterAttrs (
        _: bm: bm ? linkCidr && bm.vzHostKind == "foreign"
      ) catalogData.netplan.baremetal;

      baremetalLinkLabel = "io.seedmatic.baremetal-link";

      # Common addressing tokens both install.sh and uninstall.sh take from the
      # catalog — single-sourced so the teardown undoes exactly what install set.
      baremetalLinkVars = bm: {
        # The tailnet's MagicDNS zone, unqualified.  A FOREIGN vz-host can never join the
        # tailnet, so it gets a SECOND scoped resolver for this zone pointing at the segment's
        # dnsmasq, which forwards it to MagicDNS (modules/nixos/baremetal-segment.nix).  Without
        # it that seat can reach a Tailscale Service only by its virtual IP.  Shared by install
        # and uninstall so the teardown removes the same file the install wrote.
        tailnetZone = nixpkgs.lib.removePrefix "." catalogData.netplan.tailnet.domain;

        # The adapter to alias is the one the vz guest is BRIDGED onto — that is what puts
        # the /30's two ends (this alias, the guest's lan-br) on a shared L2.  So it is read
        # from the same declaration Tart's bridge mode uses, `hardware.vmBridgeService`,
        # rather than restated: this token used to be a flat `en0`, which was accidentally
        # right for nikopol (Wi-Fi) and silently wrong for bioskop (Thunderbolt Ethernet).
        # A SERVICE name, resolved to its device by the script at runtime — `enX` numbering
        # shifts when adapters are added or removed.  `bm.domain` is the host directory name
        # (the catalog keys `baremetal.<host>` by it — see modules/nixos/baremetal-segment.nix).
        bridgeService = (import (./hosts + "/${bm.domain}/hardware.nix")).vmBridgeService;
        vzHostAddress = bm.vzHostAddress;
        # The spans to route over the /30, as ONE list the script just loops over — so the
        # decision lives here, in the data, instead of being wired into the script.
        #   - the segment itself, always: a direct L2 path, and more specific than the
        #     advertised /24 a tailnet-member Mac already holds via its utun.
        #   - the tailnet, ONLY for a `foreign` vz-host, which has no tailnet interface and
        #     can reach it no other way. Adding it on a nix-managed (tailnet-member) Mac
        #     would hijack its own 100.64/10 route through the guest.
        linkRoutes = nixpkgs.lib.concatStringsSep " " (
          [ bm.netCidr ] ++ nixpkgs.lib.optional (bm.vzHostKind == "foreign") catalogData.netplan.tailnet.cidr
        );
        # The script also branches on the kind for the two things nix-darwin already owns on
        # a nix-managed vz-host: /etc/resolver/<domain> (baremetal-resolvers.nix) and the
        # guest-reconfigure nudge (which exists because a ROAMING corp Mac is the only one
        # that can tell its guest the network moved).
        vzHostKind = bm.vzHostKind;
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
            # Hard bound on the reachability probe: ssh's ConnectTimeout does not cover NAME
            # RESOLUTION, so probing a segment name whose resolver just moved hung for 30s
            # against a 5s ConnectTimeout.
            timeout = "${pkgsForSystem.coreutils}/bin/timeout";
            installScript = "${mkBaremetalLinkInstall system bm}";
            uninstallScript = "${mkBaremetalLinkUninstall system bm}";
            vzHost = "vzhost.${bm.domain}";
            # The out-of-band path, from the catalog rather than guessed. It used to be
            # `${bm.domain}.local`, which silently addressed the wrong MACHINE wherever the
            # bare-metal is not itself named after the segment — on nikopol that mDNS name is
            # the vz guest VM. The LAN name also has a Host block in the operator's ssh config,
            # so the identity resolves; `nikopol.local` matched none and was refused.
            bootstrapHost = "${bm.vzHostLanName}${catalogData.netplan.lan.domain}";
            # Where the enrich pipeline lands the vz-nudge private+cert (usage
            # ssh-host → root-owned systemKeysDir). Read at runtime by deploy.sh and
            # shipped to the target so link-up.sh can auth the guest nudge. Matches
            # modules/.common.d/ssh-paths.nix `systemKeysDir` default. deploy.sh also
            # reads ${systemKeysDir}/rdp-host{,-cert.pub} from here as the vzhost
            # login identity (root-readable; the activation oneshot runs as root).
            systemKeysDir = "/var/lib/ndh/ssh-keys";
            # vzhost's OS login — read from the catalog, which now holds it beside the vz-host's
            # other identity facts. It used to be written here with a comment conceding that no
            # single source existed and that the string was already duplicated in
            # modules/home-manager/ssh-tailnet-hosts.nix. There is one now, and both read it.
            vzUser = bm.vzHostUser;
          }
        );

      # The vz-hosts that ARE nix-darwin machines (bioskop: the Mac Mini is its own
      # bare-metal, so `vzhost.bioskop` and the darwinConfiguration `bioskop` are one
      # machine). They take the SAME rendered install.sh — the artifact is identical, only
      # the delivery differs: piped over ssh for a foreign vz-host, run from the host's own
      # activation here (modules/darwin/baremetal-link.nix). Exposed as a package so that
      # module can reference it instead of re-deriving the tokens.
      baremetalLinkNixHosts = nixpkgs.lib.filterAttrs (
        _: bm: bm ? linkCidr && bm.vzHostKind == "nix-managed"
      ) catalogData.netplan.baremetal;

      # Per-baremetal-host packages: `<domain>-baremetal-link-deploy` for a foreign vz-host
      # (ssh delivery), `<domain>-baremetal-link-install` for a nix-managed one (activation).
      mkBaremetalLinkPackages =
        system:
        builtins.foldl' (
          acc: bm: acc // { "${bm.domain}-baremetal-link-deploy" = mkBaremetalLinkDeploy system bm; }
        ) { } (builtins.attrValues baremetalLinkHosts)
        // builtins.foldl' (
          acc: bm: acc // { "${bm.domain}-baremetal-link-install" = mkBaremetalLinkInstall system bm; }
        ) { } (builtins.attrValues baremetalLinkNixHosts);

      # Resolve a relative path to its OWN store path, hashed on that file (or subtree) alone — not on
      # the whole worktree the way `${self}/<file>` does, so unrelated source edits don't bust
      # downstream derivations like the bringup disk image.  See docs/bringup-image-unification.adoc.
      #
      # ⚠️ It used to be `./. + "/${rel}"`, which achieved NEITHER half of that sentence. In a flake
      # `./.` is already the store path of the whole source, so the result was a path INSIDE it: hashed
      # on the entire worktree, and — the part that actually broke — a string that the reference
      # scanner never records. Measured 2026-10-01 on the tart materializer: the activation script
      # NAMED `/nix/store/…-source/.secrets` while `nix-store --query --requisites` on it found 0
      # occurrences of that source. So the file was not in the closure, never travelled to a host that
      # had not built locally, and `manage-tailnet --reclaim-host` died on
      # `--secrets-file not found` — refusing the factory reset, correctly, for a missing dependency
      # that LOOKED declared.
      #
      # ★ The scope is the file's DIRECTORY, not the file — which is what makes ONE helper enough.
      # Isolating the file alone also works for the closure and breaks everything that resolves a
      # sibling: measured, `modules/.common.d/ssh-paths.nix` lost its relative imports outright, and
      # `shell.d/nix-bash-trampoline.sh` finds its logger through `${BASH_SOURCE[0]%/*}/logger.sh`.
      # Those scripts need their neighbours, and a directory gives them both the neighbours and the
      # reference.
      #
      # Probed rather than assumed, because the shape is the one that FAILED above: a path inside a
      # DEDICATED `builtins.path` directory IS recorded as a reference (a `writeText` naming
      # `${dir}/nix-bash-trampoline.sh` lists that dir in `--references`). So the broken shape was
      # never "a path inside a store path" — it was a path inside the WHOLE-SOURCE path specifically,
      # whose context is discarded somewhere downstream, which is exactly what one would want for the
      # source and exactly what silently took `.secrets` with it.
      #
      # A root-level file (`.secrets`) is scoped to the FILE: its directory IS the whole worktree,
      # which is the thing being avoided, and it has no sibling set to preserve.
      # ⚠️ And it cannot be ONE helper, which two separate evaluation failures established in order:
      #
      #   1. file-scoped `of` broke every script resolving a sibling, hence the directory scope;
      #   2. directory- or file-scoped `of` then broke the MODULE SYSTEM, which dedupes imports by
      #      PATH: `profile.nix` reached through a new store identity read as a second module —
      #      "The option `profile' in `…-ndh-profile.nix' is already declared in `…-source/profile.nix'".
      #
      # So identity and dependency pull in opposite directions, and the two uses are named apart:
      #
      #   of          — EVAL-time. Identity-preserving, because a module imported by two different
      #                 paths is imported TWICE. Never reach for it where a BUILT artifact will later
      #                 open the file.
      #   runtimeFile — a real DEPENDENCY, scoped to the file's DIRECTORY so siblings survive, and
      #                 scanned into the closure so it travels.
      worktreePath = {
        of = rel: ./. + "/${rel}";
        runtimeFile =
          rel:
          let
            split = builtins.match "(.*)/([^/]+)" rel;
            storeName = p: "ndh-${builtins.replaceStrings [ "/" ] [ "-" ] p}";
          in
          if split == null then
            # A root-level file (`.secrets`): its directory IS the whole worktree — the thing being
            # avoided — and it has no sibling set to preserve.
            builtins.path {
              path = ./. + "/${rel}";
              name = storeName rel;
            }
          else
            builtins.path {
              path = ./. + "/${builtins.elemAt split 0}";
              name = storeName (builtins.elemAt split 0);
            }
            + "/${builtins.elemAt split 1}";
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

      # No treefmt check here (its API mismatched during evaluation); the formatter runs as a hook.
      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor { inherit system; };
          managed = import ./modules/darwin/claude-code-managed.d/package.nix { inherit pkgs; };
          sessionHooks = import ./modules/home-manager/claude-code.d/hooks/package.nix { inherit pkgs; };
        in
        {
          claude-code-managed-settings = managed.settings;
          claude-code-deny-hook = managed.tests;
          claude-code-session-hooks = sessionHooks.tests;
          ssh-keys-bats = import ./modules/.common.d/ssh-keys.d/tests/package.nix {
            inherit pkgs;
            trampoline = mkNdhNixBashTrampoline { pkgsForSystem = pkgs; };
          };
          ssh-keys-renew-bats = import ./modules/.common.d/ssh-keys-renew.d/tests/package.nix {
            inherit pkgs;
          };
          ssh-keys-certify-bats = import ./modules/.common.d/ssh-keys-certify.d/tests/package.nix {
            inherit pkgs;
          };
          cache-signing-key-rotate-bats =
            import ./modules/.common.d/cache-signing-key-rotate.d/tests/package.nix
              {
                inherit pkgs;
              };
          restart-on-secret-change-bats =
            import ./modules/darwin/restart-on-secret-change.d/tests/package.nix
              {
                inherit pkgs;
              };
          # keys.yaml against its schema, ENCRYPTED as committed: the schema accepts ENC[...]
          # wherever a private may sit, so the sandbox needs no key and nothing is decrypted.
          # Each broken fixture must be REFUSED — a schema that accepts them proves nothing.
          ssh-keys-schema =
            pkgs.runCommand "ssh-keys-schema" { nativeBuildInputs = [ pkgs.check-jsonschema ]; }
              ''
                schema=${./modules/home-manager/ssh.d/keys.schema.yaml}
                check-jsonschema --schemafile "$schema" ${./modules/home-manager/ssh.d/keys.yaml}
                for broken in ${./modules/home-manager/ssh.d/tests}/broken-*.yaml; do
                  if check-jsonschema --schemafile "$schema" "$broken" >/dev/null 2>&1; then
                    echo "the schema ACCEPTED $broken, which it must refuse" >&2
                    exit 1
                  fi
                done
                touch $out
              '';
          # The logger wrapper every ndh script runs under: a `set -e` script's failure stops it and fails
          # the wrapper.
          logger-command-run-bats = import ./modules/.common.d/shell.d/tests/package.nix { inherit pkgs; };
          # The sshd post-flight checks: an unreadable host key is reported, an sshd not up refuses, the
          # authorized-keys check never blocks sshd.
          openssh-checks-bats = import ./modules/nixos/systemd/openssh.d/tests/package.nix { inherit pkgs; };
          # baremetal-link deploy: nothing unapplied is ever reported done.
          baremetal-link-deploy-bats = import ./pkgs/baremetal-link.d/tests/package.nix { inherit pkgs; };
          # incus-cluster-join: a join that did not take is never reported joined.
          incus-cluster-join-bats = import ./pkgs/incus-cluster-join.d/tests/package.nix { inherit pkgs; };
          incus-cluster-cert-bats = import ./modules/.common.d/incus-cluster-cert.d/tests/package.nix {
            inherit pkgs;
          };
          tls-authority-keychain-bats = import ./modules/darwin/tls-authority-keychain.d/tests/package.nix {
            inherit pkgs;
            trampoline = mkNdhNixBashTrampoline { pkgsForSystem = pkgs; };
          };
          # A two-slot authority whose old slot is compromised: ONE trusted slot, ONE to remove.
          ssh-keys-trust =
            let
              trust = import ./modules/.common.d/keys-yaml.d/trust.nix { inherit (pkgs) lib; };
              authorities.tls.slots = {
                "26-05-29" = {
                  ca_crt = "OLD";
                  compromised = "published";
                };
                "26-10-04".ca_crt = "NEW";
              };
            in
            assert pkgs.lib.assertMsg (
              pkgs.lib.attrNames (trust.trustedSlots authorities).tls == [ "26-10-04" ]
            ) "a compromised slot is still trusted";
            assert pkgs.lib.assertMsg (
              pkgs.lib.attrNames (trust.compromisedSlots authorities).tls == [ "26-05-29" ]
            ) "a compromised slot is not listed for removal";
            # The phase-2 gate: an ordinary retirement needs the slot that now signs to be trusted.
            assert pkgs.lib.assertMsg (
              trust.phase2Gaps { tls.slots."26-10-04".ca_crt = "NEW"; } { "tls@26-05-29".reason = "retired"; }
              == [ "tls@26-05-29" ]
            ) "an ordinary retirement passed the gate without `trusted`";
            assert pkgs.lib.assertMsg (
              trust.phase2Gaps {
                tls.slots."26-10-04" = {
                  ca_crt = "NEW";
                  trusted = "26-10-12";
                };
              } { "tls@26-05-29".reason = "retired"; } == [ ]
            ) "a retirement whose successor is trusted was refused";
            assert pkgs.lib.assertMsg (
              trust.phase2Gaps { tls.slots."26-10-04".ca_crt = "NEW"; } {
                "tls@26-05-29" = {
                  reason = "published";
                  compromised = true;
                };
              } == [ ]
            ) "a compromised retirement was held by the gate";
            pkgs.runCommand "ssh-keys-trust" { } "touch $out";
          # Built for aarch64-linux (the builder runs it): the check runs a real sshd, and on darwin
          # sshd's preauth child cannot enter its own seatbelt sandbox inside the nix build sandbox
          # (sandbox_init: Operation not permitted).
          openssh-revoked-host-keys = import ./modules/.common.d/openssh-policy.d/tests/package.nix {
            pkgs = pkgsForLinux;
          };
        }
        // nixpkgs.lib.listToAttrs (
          map
            (
              host:
              let
                darwin = self.darwinConfigurations.${host}.config;
                owned = [
                  "root@bioskop-nixos"
                  "root@nikopol-nixos"
                  "bioskop-nixos.local"
                  "nikopol-nixos.local"
                  "router.lan"
                  "bioskop.mammoth-skate.ts.net"
                ];
                everywhere = owned ++ [ "example.com" ];
              in
              nixpkgs.lib.nameValuePair "ssh-client-effective-${host}" (
                import ./modules/darwin/ssh-client.d/tests/effective.nix {
                  inherit pkgs;
                  inherit (nixpkgs) lib;
                  name = host;
                  etc = darwin.environment.etc;
                  expect =
                    map (target: {
                      inherit target;
                      option = "stricthostkeychecking";
                      value = "true";
                    }) owned
                    ++ map (target: {
                      inherit target;
                      option = "controlmaster";
                      value = "false";
                    }) everywhere
                    ++ map (target: {
                      inherit target;
                      option = "globalknownhostsfile";
                      value = "/etc/ssh/ssh_known_hosts";
                    }) everywhere
                    ++ map (target: {
                      inherit target;
                      option = "revokedhostkeys";
                      value = "${darwin.ndh.keysYaml.revokedKeysFile}";
                    }) everywhere
                    ++ [
                      {
                        target = "example.com";
                        option = "stricthostkeychecking";
                        value = "accept-new";
                      }
                    ];
                }
              )
            )
            [
              "bioskop"
              "nikopol"
            ]
        )
        // nixpkgs.lib.listToAttrs (
          map
            (
              host:
              nixpkgs.lib.nameValuePair "secrets-read-after-install-${host}" (
                import ./modules/darwin/activation-order.d/tests/read-after-install.nix {
                  inherit pkgs;
                  name = host;
                  text = self.darwinConfigurations.${host}.config.system.activationScripts.postActivation.text;
                }
              )
            )
            [
              "bioskop"
              "nikopol"
            ]
        )
        # The mask a failed install's log goes through into the build log: key material never passes.
        // {
          bringup-install-log-mask =
            (pkgsFor { system = "aarch64-linux"; }).runCommand "bringup-install-log-mask"
              { nativeBuildInputs = [ (pkgsFor { system = "aarch64-linux"; }).openssh ]; }
              ''
                ssh-keygen -q -t ed25519 -N "" -f key
                { echo before; cat key; printf 'AGE-SECRET-'"KEY-1%s\\n" "$(head -c 400 /dev/urandom | base64 -w0 | tr -dc 'A-Z0-9' | head -c 58)"; echo after; } > log
                sed -E -f ${./modules/nixos/bringup-zfs-disk-image.d/install-log-mask.sed} log > masked
                grep -qx before masked && grep -qx after masked
                if grep -qE '^[A-Za-z0-9+/=]{40,}$|AGE-SECRET-KEY-1[A-Z0-9]{50,}' masked; then
                  echo "key material passed the mask" >&2
                  exit 1
                fi
                [ "$(grep -c '\[MASKED\]' masked)" -ge 2 ]
                touch $out
              '';
        }
        # The in-guest secret-material guard, on a real install: a private key born in the target root
        # stops the raw build, and the refusal names it in the build log. A full VM build (~13 min).
        // {
          bringup-in-guest-secret-guard =
            let
              linuxPkgs = pkgsFor { system = "aarch64-linux"; };
              # testers.testBuildFailure, by overrideDerivation: a runInLinuxVM derivation has no
              # overrideAttrs. The same expect-failure.sh, around the original builder and args.
              refused =
                linuxPkgs.lib.overrideDerivation hostOutputs.nikopol.nixosBringupSecretCanaryBuild
                  (orig: {
                    builder = "${linuxPkgs.bash}/bin/bash";
                    args = [
                      (linuxPkgs.replaceVars "${linuxPkgs.path}/pkgs/build-support/testers/expect-failure.sh" {
                        coreutils = linuxPkgs.coreutils;
                        vars = linuxPkgs.lib.toShellVars { outputNames = orig.outputs or [ "out" ]; };
                      })
                      orig.builder
                    ]
                    ++ orig.args;
                  });
            in
            linuxPkgs.runCommand "bringup-in-guest-secret-guard" { } ''
              grep -q 'secret-material-guard: REFUSED /mnt/zfs-root/root/.secret-canary/id ' ${refused}/testBuildFailure.log
              touch $out
            '';
        }
        # The bringup images' secret-material guard, proven by canaries — on aarch64-linux, where the
        # store layers it guards are packed, through the remote builder, like the images themselves.
        // {
          secret-material-guard =
            let
              linuxPkgs = pkgsFor { system = "aarch64-linux"; };
            in
            import ./modules/nixos/secret-material-guard.d/tests/package.nix {
              pkgs = linuxPkgs;
              nixBashTrampoline = "${mkNdhNixBashTrampoline { pkgsForSystem = linuxPkgs; }}";
            };
        }
      );

      # Surface the resolved catalog + inventory as flat (OS-independent) outputs
      # so the operator can review them directly — `nix eval .#catalog.netplan.lan.hosts`
      # or `:lf .` then `catalog…` — without drilling through a host's
      # `darwinConfigurations.<host>._module.specialArgs.catalog`. The catalog's
      # rke2 hosts are the projection of rke2lab's networkBlueprint (see the
      # fabric-plan input), so this is also the easiest way to diff the live underlay
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
        # The keychain reconcile, buildable ON ITS OWN by revision: a fix between two
        # configurations ships as this closure, copied to the host and run by the operator
        # (`sudo ndh-keychain-reconcile` from the GUI session) — the same script the darwin
        # activation runs (modules/darwin/tls-authority-keychain.nix).
        nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          ndh-keychain-reconcile = self.darwinConfigurations.bioskop.config.ndh.tlsAuthorityKeychain.package;
          # T14, by the same rule: one closure built by revision, run from the seat.
          incus-cluster-cert-renew = import ./modules/.common.d/incus-cluster-cert.d/package.nix {
            pkgs = systemPkgs;
            inherit (nixpkgs) lib;
            netplan = catalogData.netplan;
            operatorIdentity = incusCertOperatorIdentity;
          };
        }
        // {
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
          # The Incus CLI, for BOTH systems.  `pkgs.incus` is the full daemon and is Linux-only in
          # nixpkgs (it wants lxc, libcap, cowsql…), but nixpkgs ships a client-only variant as
          # `incus.passthru.client` that builds on Darwin too because it needs only Go and the
          # `cmd/incus` subpackage.  There is NO top-level `incus-client` attribute in our nixpkgs pin
          # — checked on both systems — so `passthru.client` is the route, not a workaround.
          #
          # ndh owns this rather than rke2lab, and that is the natural direction: ndh already owns the
          # incus DAEMON (modules/nixos/incus.nix, incus-cluster.nix) and the operator's trust to it
          # (modules/darwin/incus-remote-trust.nix), so the client belongs beside them. rke2lab
          # re-exports this package for its flox env, the same way ndh's manage-tailnet already
          # travels in that direction. Cross-referencing it the other way — ndh importing rke2lab's
          # client — would have the host layer borrow a tool from the cluster layer that runs ON it.
          incus-client = systemPkgs.incus.passthru.client;
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
        }
        // mkBaremetalLinkPackages system
        # Darwin only: the join is an operator act run from the operator's machine, and the recipe is
        # built against the Darwin store API. Exposed as packages too so it can be built and
        # dry-run'd on its own, not only through `nix run`.
        // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") (
          builtins.listToAttrs (
            map (domain: {
              name = "${domain}-incus-cluster-join";
              value = incusClusterJoinPackages.${domain};
            }) (builtins.attrNames incusClusterJoinPackages)
          )
        )
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
          # `-materialize` is the local counterpart of `-deploy`, and on a host that
          # runs the Tart VM itself (not a remote vz host) it is the ONLY entry point
          # to (re)materialize the VM — e.g.
          # `VM_FACTORY_RESET=true nix run .#nerd-tart-bioskop-materialize`.
          # Darwin activation deliberately never does this: staging the bringup images
          # is tens of GiB (see the `includeBringupSymlink` notes in
          # modules/darwin/tart-config.nix), and it has its own cadence, independent
          # of host convergence.  So the image stays out of the darwin system closure
          # and reaching it is an explicit operator gesture.
          let
            systemPkgs = pkgsFor { inherit system; };
            anyHostName = builtins.head (builtins.attrNames hostCatalog);
            anyHostDeploy =
              hostOutputs.${anyHostName}.darwinConfiguration.config.tart.configGenerator.deployPackage;
            mkDeployHelper =
              {
                mainName,
                vmName,
                runManifest,
                # The host's OWN bringup images: their third store layer is the host's runtime
                # residue, so another host's images would boot another host's system.
                bringupImages,
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
                  per-VM YAML, and ${mainName}'s bringup disk images to <vz-host>
                  (default: vzhost.${mainName}); installs the YAML at
                  ~/.config/nerd-tart/${mainName}.yaml on the vz host; then execs
                  nerd-tart there to materialize and run the VM.
                  USAGE
                      exit 0
                      ;;
                  esac

                  deploy_bundle=${anyHostDeploy}
                  vm_config=${runManifest}
                  bringup_images=${bringupImages}

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
                  bringupImages = hostOutput.nixosDiskImageBringupSystemdZfs;
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
          # One bringup disk-image set PER HOST: the third store layer is the host's runtime residue
          # (see modules/nixos/bringup-zfs-disk-image.nix), so the sets are no longer bit-identical
          # across hosts, and an arbitrary host's set boots that host's system.
          builtins.listToAttrs (
            map (hostName: {
              name = "nerd-nixos-${
                hostMainNameForProfile hostCatalog.${hostName}.hostProfile
              }-bringup-zfs-systemd-disk";
              value = hostOutputs.${hostName}.nixosDiskImageBringupSystemdZfs;
            }) (builtins.attrNames hostCatalog)
          )
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
          # listToAttrs, NOT mapAttrs: the recipe keys by bare domain, and mapAttrs would keep that
          # key — exposing the app as `nix run .#nikopol`, a name generic enough to collide.
          incusClusterJoinApps = builtins.listToAttrs (
            map (domain: {
              name = "${domain}-incus-cluster-join";
              value = {
                type = "app";
                program = "${incusClusterJoinPackages.${domain}}/bin/${domain}-incus-cluster-join";
                meta.description = "Join ${domain}-nixos to the Incus cluster, then pin it OUT of the raft (database-client) — src: pkgs/incus-cluster-join.d/";
              };
            }) (builtins.attrNames incusClusterJoinPackages)
          );
          nixBuildObservePackage = mkNixBuildObservePackage system;
          pkgsForSystem = pkgsFor { inherit system; };
          # check-jsonschema against keys.yaml AS COMMITTED — encrypted: the schema accepts
          # ENC[...] wherever a private may sit, so nothing is decrypted and no plaintext copy
          # is written. The same validation runs as checks.<system>.ssh-keys-schema and in the
          # pre-commit (treefmt keys-schema); this app checks an uncommitted keys.yaml, from the
          # repo root, with the tool named by revision:
          #   nix run "git+file://$PWD?rev=$(git rev-parse HEAD)#ssh-keys-v2-validate" -- <keys.yaml>
          sshKeysValidatorPackage = pkgsForSystem.writeShellApplication {
            name = "ssh-keys-v2-validate";
            runtimeInputs = [ pkgsForSystem.check-jsonschema ];
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
              exec check-jsonschema --schemafile "$schema" "$target"
            '';
          };
          # The envs vendored under .flox-envs.d arrive WITHOUT their manifest.lock: fleet
          # gitignores it, and the lock is what makes an env includable — so a fresh clone
          # cannot activate the seat until this runs ("manifest and lockfile are out of sync").
          # The locks stay gitignored on purpose: fleet publishes manifests, each checkout
          # realises its own lock.
          #
          # The include graph is WALKED, not listed: `nix` includes `../keyhole`, and a composed
          # env must be locked after the ones it includes. A hardcoded list rots the next time
          # fleet adds an include. Both quote styles are read because fleet writes the seat form
          # with double quotes and the internal form with single quotes.
          #
          # `flox` comes from the host (the flox installer), not nixpkgs —
          # writeShellApplication prepends runtimeInputs and keeps the inherited PATH.
          #
          # ⚠️ This is a SECOND copy — rke2lab's flake carries the same app. Its decided home is a
          # flake INSIDE the subtree, owned by fleet (`nix run ./.flox-envs.d#lock`): what it encodes
          # is fleet's own relative-include convention, so the producer should own it, and that route
          # adds no flake input edge. Moving it must delete rke2lab's copy in the same change, or two
          # copies become three.
          lockFloxEnvsPackage = pkgsForSystem.writeShellApplication {
            name = "lock-flox-envs";
            runtimeInputs = [
              pkgsForSystem.git
              pkgsForSystem.gnused
            ];
            text = ''
              cd "$(git rev-parse --show-toplevel)"

              declare -A walked=()

              deps_of() {
                sed -n -e "s|^[[:space:]]*{\? *dir = '\.\./\([^']*\)'.*|\1|p" \
                       -e 's|^[[:space:]]*{\? *dir = "\.\./\([^"]*\)".*|\1|p' "$1"
              }

              seat_includes() {
                sed -n -e "s|^[[:space:]]*{\? *dir = '\./\.flox-envs\.d/\([^']*\)'.*|\1|p" \
                       -e 's|^[[:space:]]*{\? *dir = "\./\.flox-envs\.d/\([^"]*\)".*|\1|p' "$1"
              }

              lock_env() {
                local env="$1"
                local dir=".flox-envs.d/$env"
                if [ -n "''${walked[$env]:-}" ]; then
                  return 0
                fi
                walked[$env]=1
                if [ ! -f "$dir/.flox/env/manifest.toml" ]; then
                  echo "lock-flox-envs: no vendored env '$env' — is the subtree imported?" >&2
                  exit 1
                fi
                local dep
                while read -r dep; do
                  if [ -n "$dep" ]; then
                    lock_env "$dep"
                  fi
                done < <(deps_of "$dir/.flox/env/manifest.toml")
                if [ -f "$dir/.flox/env/manifest.lock" ]; then
                  echo "  $env already locked"
                else
                  echo "  locking $env"
                  flox upgrade --dir "$dir" >/dev/null
                fi
              }

              # Refusing on zero is the point, not a guard against a typo: with no matches the
              # loop below simply never runs, and the success line still prints. The operator is
              # then told "ready" and `flox activate` fails with the very "manifest and lockfile
              # are out of sync" this app exists to prevent. A locker that cannot read the
              # manifest must SAY SO, not answer "nothing" — so this stays correct even for an
              # include form neither reader above anticipates.
              includes="$(seat_includes .flox/env/manifest.toml)"
              if [ -z "$includes" ]; then
                echo "lock-flox-envs: no [include] entries under .flox-envs.d found in" >&2
                echo "  .flox/env/manifest.toml — refusing to report success." >&2
                exit 1
              fi

              while read -r env; do
                if [ -n "$env" ]; then
                  lock_env "$env"
                fi
              done <<< "$includes"

              echo "vendored flox envs locked — 'flox activate' is ready"
            '';
          };
          # manage-tailnet: administer the tailnet (rotate auth keys / sync-policy /
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
          # Operator ceremony: phase 1 of an SSH key renewal — add a dated slot to
          # selected keys.yaml entries and generate into it, so BOTH generations are
          # published while the fleet activates. Dry run unless --apply.
          #
          # ★ Generation happens HERE rather than by emptying a slot and letting
          # activation fill it: the enrichment runs against the sops-decrypted
          # RUNTIME copy, which is rewritten from the encrypted source on every
          # switch, so an empty slot in the source would be a different key after
          # every activation.
          # ★ Nothing is pinned by store path here, unlike its two siblings below:
          # sops, yq, ssh-keygen, git and the coreutils this needs are all part of
          # the bringup runtime profile's command contract, so the trampoline either
          # provides them or refuses with an install hint. `sops` was the one that
          # was NOT in that profile and had to come from the system closure — it is
          # in the contract now (53 MB of closure, measured).
          sshKeysRenewPackage = ndhStoreApiDarwin.installBinScript "ssh-keys-renew" (
            pkgsForSystem.replaceVars ./modules/.common.d/ssh-keys-renew.d/ssh-keys-renew.sh {
              nixBashTrampoline = ndhNixBashTrampolineDarwin;
              loggerTag = "ndh.ssh-keys-renew";
            }
          );
          # 6a: the seat signs every SSH certificate keys.yaml declares, host certificates for
          # fleetHostPrincipals; the activation only installs them.
          # The fleet's nix signing key, replaced on the seat (the interim rotation of 2026-10-13).
          cacheSigningKeyRotatePackage = ndhStoreApiDarwin.installBinScript "cache-signing-key-rotate" (
            pkgsForSystem.replaceVars ./modules/.common.d/cache-signing-key-rotate.d/cache-signing-key-rotate.sh
              {
                nixBashTrampoline = ndhNixBashTrampolineDarwin;
                loggerTag = "ndh.cache-signing-key-rotate";
                nix = "${pkgsForSystem.nix}/bin/nix";
              }
          );
          sshKeysCertifyPackage = ndhStoreApiDarwin.installBinScript "ssh-keys-certify" (
            pkgsForSystem.replaceVars ./modules/.common.d/ssh-keys-certify.d/ssh-keys-certify.sh {
              nixBashTrampoline = ndhNixBashTrampolineDarwin;
              loggerTag = "ndh.ssh-keys-certify";
              hostPrincipals = nixpkgs.lib.concatStringsSep "," fleetHostPrincipals;
              sshKeygen = "${pkgsForSystem.openssh}/bin/ssh-keygen";
            }
          );
          # T14's closure: re-mint and install the Incus cluster certificate (one definition,
          # also packages.<system>.incus-cluster-cert-renew) — see its package.nix.
          incusClusterCertRenewPackage = import ./modules/.common.d/incus-cluster-cert.d/package.nix {
            pkgs = pkgsForSystem;
            inherit (nixpkgs) lib;
            netplan = catalogData.netplan;
            operatorIdentity = incusCertOperatorIdentity;
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
          lock-flox-envs = {
            type = "app";
            program = "${lockFloxEnvsPackage}/bin/lock-flox-envs";
            meta.description = "Lock the flox envs vendored under .flox-envs.d so the seat can activate (fresh-clone bootstrap) — src: flake.nix (lockFloxEnvsPackage)";
          };
          # relock — nix-flake-commons' `lib.mkRelockApp`, the one implementation every seedmatic
          # flake shares. ndh supplies its name; the heads, the order and what each head pins are read
          # from nix-flake-commons:fabric/heads.
          relock = {
            type = "app";
            program = "${
              inputs.flake-commons.lib.mkRelockApp {
                pkgs = pkgsForSystem;
                name = "ndh";
              }
            }/bin/relock";
            meta.description = "Reconcile THIS head's locks: bump each input, DROP any bump that moves nothing it exports, push. --plan shows a pass, --downstream plays it over every head of fabric/heads";
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
          incus-cluster-cert-renew = {
            type = "app";
            program = "${incusClusterCertRenewPackage}/bin/incus-cluster-cert-renew";
            meta.description = "Re-mint the Incus cluster certificate under the current TLS signing slot, install it on every member, re-pin the seat client, verify — run from the seat, built by revision — src: modules/.common.d/incus-cluster-cert.d/";
          };
          authority-bootstrap-tls-root = {
            type = "app";
            program = "${authorityBootstrapTlsRootPackage}/bin/authority-bootstrap-tls-root";
            meta.description = "Mint/rotate a self-signed TLS root for a keys.yaml authority — <authority> [--force|--create <keyType>], run from repo root — src: modules/.common.d/authority-bootstrap-tls-root.d/";
          };
          ssh-keys-renew = {
            type = "app";
            program = "${sshKeysRenewPackage}/bin/ssh-keys-renew";
            meta.description = "Phase 1 of an SSH key renewal: add a dated slot and generate into it — [--key NAME] [--authority NAME] [--older-than Nd] [--apply], or declare a new entry with --create NAME --usage TAG, dry run by default, run from repo root — src: modules/.common.d/ssh-keys-renew.d/";
          };
          cache-signing-key-rotate = {
            type = "app";
            program = "${cacheSigningKeyRotatePackage}/bin/cache-signing-key-rotate";
            meta.description = "Replace the fleet's nix signing key on the seat: generate it, write it encrypted into catalog/cache-trust.yaml, print the new public — --to NAME [--apply], dry run by default, run from repo root — src: modules/.common.d/cache-signing-key-rotate.d/";
          };
          ssh-keys-certify = {
            type = "app";
            program = "${sshKeysCertifyPackage}/bin/ssh-keys-certify";
            meta.description = "Sign, on the seat, every SSH certificate keys.yaml declares (host certificates for every fleet name) and record them in keys.yaml — [--apply], dry run by default, run from repo root — src: modules/.common.d/ssh-keys-certify.d/";
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
        // incusClusterJoinApps
      );

      mkHostOutputs =
        {
          hostProfile,
          profileModule,
          darwinExtraModules ? [ ],
          nixosExtraModules ? [ ],
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
          nixosBringupSecretCanaryBuild = nixosOutputs.bringupSecretCanaryBuild;
          nixosDiskImageBringupGrub = nixosOutputs.diskImageBringupGrub;
          nixosDiskSizeHint = nixosOutputs.diskSizeHint;
          nixosDiskSizeMiB = nixosOutputs.diskSizeMiB;
          nixosDiskoConfiguration = nixosOutputs.diskoConfiguration;
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
              extraSpecialArgs = mkNdhHomeManagerSpecialArgs {
                inherit
                  self
                  worktreePath
                  profile
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
              };
            };
          darwinOutputs = mkDarwinOutputs {
            inherit hostProfile catalog;
            inventory = inventoryData;
            profileModule =
              { ... }:
              {
                imports = [
                  profileModule
                  (
                    { ... }:
                    {
                      # These store paths are what the `nerd-tart-<host>-materialize`
                      # staging gesture resolves. They reach the Tart bundle, never the
                      # darwin system closure — no activation path consumes the bundle.
                      tart.configGenerator.rawImageManifestPath = "${nixosDiskImageBringupSystemdZfs}/manifest.yaml";
                      tart.configGenerator.rawImageStorePath = "${nixosDiskImageBringupSystemdZfs}/boot.img";
                      tart.configGenerator.vmRunSopsAgeHostShare =
                        nixosOutputs.nixosConfigurations."${mainName}-nixos".config.ndh.sopsAgeKeyBootstrap.nixosHostKeyImport.enable;
                      tart.configGenerator.vmRunFirstBootAttachDiskManifestPath = null;
                      tart.configGenerator.vmRunFirstBootAttachDiskPath = "";
                      tart.configGenerator.linuxBuilderGcBeforeBuild = linuxBuilderGcBeforeBuild;
                      tart.configGenerator.enableBuildObserve = enableBuildObserve;
                      tart.configGenerator.buildObserveInterval = buildObserveInterval;
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
            nixosBringupSecretCanaryBuild
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

      # `<host>-incus-cluster-join` — mint a join token on the sedentary member and consume it on the
      # itinerant one in the same breath (the token is single-use and short-lived, so it cannot be
      # baked into an image).  Darwin-only, and that is the point: joining a cluster is an OPERATOR
      # act, not host state — see the rationale in modules/nixos/incus-cluster.nix.  Exposed BOTH as
      # apps and as packages, so the recipe lives here once (like manage-tailnet).
      #
      # Sits HERE rather than in the outer `let` because it needs `hostOutputs`: the joining member's
      # pool SOURCE is the one member-specific value `incus admin init --preseed` wants in
      # `member_config`, and its single source of truth is that host's own
      # `virtualisation.incus.preseed.storage_pools` — read from there rather than restated.
      incusStoragePools =
        let
          nixosConfigurationsAll = builtins.foldl' (
            acc: hostOutput: acc // hostOutput.nixosConfigurations
          ) { } (builtins.attrValues hostOutputs);
        in
        builtins.mapAttrs (
          _: bm:
          let
            pool =
              builtins.head
                nixosConfigurationsAll."${bm.domain}-nixos".config.virtualisation.incus.preseed.storage_pools;
          in
          {
            inherit (pool) name;
            inherit (pool.config) source;
          }
        ) (catalogData.netplan.baremetal or { });

      incusClusterJoinPackages = import ./pkgs/incus-cluster-join.d {
        pkgs = pkgsForDarwin;
        catalog = catalogData;
        ndhStore = ndhStoreApiDarwin;
        nixBashTrampoline = ndhNixBashTrampolineDarwin;
        storagePools = incusStoragePools;
      };

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
            flox = inputs.flox.packages.${hostSystem}.default;
          };

        qemuOverlay = inputs: import ./overlays/qemu.nix inputs;
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
