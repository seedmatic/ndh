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
  nixpkgsConfig = import ../modules/.common.d/nixpkgs-config.nix;
  cacheTrust = import ../catalog/cache-trust.nix {
    upstream = inputs.flake-commons.lib.upstreamCaches;
  };
  inventoryData = import ../inventory/default.nix;
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
  # Roles × keys S3a: what ssh-keys-certify signs host certificates for on the operator seat, computed,
  # never retyped: each machine's own names (host-names.nix refuses a name two machines claim).
  fleetHostCertificates =
    let
      lib = nixpkgs.lib;
      authorities = lib.filterAttrs (
        _: a: lib.elem "ssh-authority" (a.usage or [ ])
      ) self.darwinConfigurations.bioskop.config.ndh.keysYaml.authorities;
      domain =
        assert lib.assertMsg (lib.length (lib.attrNames authorities) == 1)
          "fleetHostCertificates: exactly one ssh-authority is expected, found ${toString (lib.attrNames authorities)}";
        (lib.head (lib.attrValues authorities)).domain;
      hosts = lib.attrNames inventoryData.hosts;
      guestConfigs = map (host: self.nixosConfigurations."${host}-nixos".config) (
        lib.filter (host: self.nixosConfigurations ? "${host}-nixos") hosts
      );
      guests = map (config: config.vm) guestConfigs;
      names = import ../modules/.common.d/ssh-keys-certify.d/host-names.nix { inherit lib; } {
        inherit domain hosts guests;
      };
    in
    {
      inherit names;
    };

  atticEnabledGuests = nixpkgs.lib.filterAttrs (
    _: c: c.config.ndh.atticCache.enable or false
  ) self.nixosConfigurations;
  darwinSeatConfig = seat: self.darwinConfigurations.${seat}.config;
  catalogData = import ../catalog/default.nix {
    inherit cacheTrust networkBlueprint dataplan;
    hostForms = builtins.mapAttrs (_: entry: entry.hostProfile.form or null) hostCatalog;
  };
  defaultSystems = [
    "aarch64-darwin"
    "aarch64-linux"
  ];

  forAllSystems = nixpkgs.lib.genAttrs defaultSystems;
  # The checks run on both platforms the fleet runs (operator, 2026-10-22: « on check les deux systèmes,
  # et on bascule la fleet quand on a besoin »): aarch64-linux through the seats' Linux builder. A check
  # changes no machine; a switch stays its own, ordered gesture.
  checkSystems = [
    "aarch64-darwin"
    "aarch64-linux"
  ];
  # The checks that cannot run on aarch64-linux, each with why. The linux set is the darwin set minus exactly these.
  darwinOnlyChecks = {
  };
  # The checks of every system from ONE body that drops nothing: linux is cut by darwinOnlyChecks alone, and any other
  # difference between the systems (an optionalAttrs on system inside the body, a stale entry) fails the evaluation.
  splitChecks =
    body:
    let
      lib = nixpkgs.lib;
      declared = builtins.attrNames darwinOnlyChecks;
      names = system: builtins.attrNames (body system);
      darwin = names "aarch64-darwin";
      linux = names "aarch64-linux";
      stale = builtins.filter (n: !builtins.elem n darwin) declared;
      undeclared = builtins.filter (n: !builtins.elem n linux) darwin;
      linuxOnly = builtins.filter (n: !builtins.elem n darwin) linux;
    in
    assert lib.assertMsg (
      stale == [ ]
    ) "darwinOnlyChecks names checks that do not exist: ${toString stale}";
    assert lib.assertMsg (undeclared == [ ] && linuxOnly == [ ])
      "the checks differ between systems outside darwinOnlyChecks: darwin only ${toString undeclared}, linux only ${toString linuxOnly}";
    lib.genAttrs checkSystems (
      system:
      if system == "aarch64-linux" then builtins.removeAttrs (body system) declared else body system
    );
  # The seedmatic root's ceremony VM (roles × keys ⑧): aarch64-linux, built by revision, run by
  # ndh-ceremony-vm on an operator seat.
  ceremonyVm = nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [ ../modules/nixos/ceremony-vm.nix ];
  };

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
        install -m 0644 ${../modules/.common.d/shell.d/logger.sh} "$out/logger.sh"
        install -m 0755 ${../modules/.common.d/shell.d/nix-bash-trampoline.sh} "$out/nix-bash-trampoline.sh"
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
    hostName: _: import (../hosts + "/${hostName}")
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
          ../modules/nixos
        ]
      else if system == "darwin" then
        [
          inputs.sops-nix.darwinModules.sops
          home-manager.darwinModules.home-manager
          # Only include impermanence if darwinModules exists
        ]
        ++ (if impermanence ? darwinModules then [ impermanence.darwinModules.impermanence ] else [ ])
        ++ [ ../modules/darwin ]
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
        source ${../modules/.common.d/shell.d/logger.sh}
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
        pkgsForSystem.replaceVars ../modules/.common.d/bringup-runtime.d/install-standalone.sh
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
        disko = import ${../modules/nixos/zfs-disko-config.nix} {
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
  # bioskop's Mac is reachable itself but not from the instances of its metalspace (see
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
    # it that vz-host can reach a Tailscale Service only by its virtual IP.  Shared by install
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
    bridgeService = (import (../hosts + "/${bm.domain}/hardware.nix")).vmBridgeService;
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
    (pkgsFor { inherit system; }).replaceVars ../pkgs/baremetal-link.d/install.sh (
      baremetalLinkVars bm
      // {
        linkPrefix = nixpkgs.lib.last (nixpkgs.lib.splitString "/" bm.linkCidr);
        netGateway = bm.netGateway;
        log = "/var/log/baremetal-link.log";
      }
    );

  mkBaremetalLinkUninstall =
    system: bm:
    (pkgsFor { inherit system; }).replaceVars ../pkgs/baremetal-link.d/uninstall.sh (
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
      pkgsForSystem.replaceVars ../pkgs/baremetal-link.d/deploy.sh {
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
        # reads the operator's key and certificate from here as the vzhost login
        # identity (root-readable; the activation oneshot runs as root).
        systemKeysDir = "/var/lib/ndh/ssh-keys";
        vzKeyName = self.darwinConfigurations.bioskop.config.sshPaths.keyName;
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
  # ⚠️ It used to be `../. + "/${rel}"`, which achieved NEITHER half of that sentence. In a flake
  # `../.` is already the store path of the whole source, so the result was a path INSIDE it: hashed
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
    of = rel: ../. + "/${rel}";
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
          path = ../. + "/${rel}";
          name = storeName rel;
        }
      else
        builtins.path {
          path = ../. + "/${builtins.elemAt split 0}";
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
  mkNdhHomeManagerSpecialArgs = import ../modules/.common.d/ndh-home-manager-special-args.nix;

  darwinOutputsApi = import ../modules/darwin/outputs.nix {
    inherit
      inputs
      pkgsForDarwin
      ndhStoreApiDarwin
      ndhNixBashTrampolineDarwin
      mkModulesFor
      mkSpecialArgs
      ;
  };

  nixosOutputsApi = import ../modules/nixos/outputs.nix {
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
  # A cluster's builder, defined here and built by rke2lab beside its node image: ndh builds no image of it.
  nixosModules.cluster-builder = {
    imports = [ ../modules/nixos/cluster-builder.nix ];
    ndh.clusterBuilder.upstreamCaches = [ inputs.flake-commons.lib.upstreamCaches.nixos ];
  };

  formatter = forAllSystems (
    system:
    let
      pkgs = pkgsFor { inherit system; };
      treefmtConfig = import ../treefmt.nix {
        inherit pkgs;
        projectRootFile = "flake.nix";
      };
    in
    inputs.treefmt-nix.lib.mkWrapper pkgs treefmtConfig
  );

  # The canary's derivation last proven green on aarch64-linux, one store path, written only by the
  # ndh-canary-proven app (`record`, from a clean ndh checkout): it builds onDemandChecks.bringup-in-guest-secret-guard at
  # the checkout's revision and records it only on a green build that refused the planted key. Empty: never proven.
  canaryProvenRecord = nixpkgs.lib.trim (
    builtins.readFile ../modules/nixos/secret-material-guard.d/canary-proven
  );
  # The canary gate is enforced only for releases: on develop (and any non-release
  # build) the bringup image evaluates without proving the canary, so an
  # unrelated code change does not force a ~13 min VM build. Enforcement is
  # triggered either by NDH_RELEASE=1 in the environment or by the presence of
  # a .release marker file in the checkout (used on main).
  canaryProven =
    image:
    if (builtins.getEnv "NDH_RELEASE" == "1") || (builtins.pathExists (../.release)) then
      (canaryProvenWith canaryProvenRecord) image
    else
      image;
  canaryProvenWith =
    record: image:
    let
      current = builtins.unsafeDiscardStringContext onDemandChecks.bringup-in-guest-secret-guard.drvPath;
    in
    if record == current then
      image
    else
      throw ''
        a bringup image ships only on a guard proven at its current derivation, and this one is not:
          canary now:    ${current}
          last proven:   ${if record == "" then "(never)" else record}
        prove it, then record it: nix build <flake>#onDemandChecks.bringup-in-guest-secret-guard (on linux, ~13 min),
        and on success write that derivation into modules/nixos/secret-material-guard.d/canary-proven.'';

  # Checks never in the default set (nix flake check, a sweep): each builds what a default build must not, built
  # by name only, `nix build <flake>#onDemandChecks.<name>`, when its subject changes (operator, 2026-10-24: the
  # erofs store images are built on demand only, after the linux builder's pool filled twice).
  onDemandChecks = {
    # The in-guest secret-material guard, on a real install: a private key born in the target root stops the
    # raw build, and the refusal names it in the build log. A full VM build (~13 min) with nikopol's three erofs
    # store layers attached. The guard's own canaries (checks.*.secret-material-guard) stay in the default set.
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
  };

  # No treefmt check here (its API mismatched during evaluation); the formatter runs as a hook.
  checks = splitChecks (
    import ../flake/checks.nix {
      inherit
        self
        pkgsFor
        pkgsForDarwin
        pkgsForLinux
        ceremonyVm
        catalogData
        inventoryData
        hostCatalog
        inputs
        mkNdhNixBashTrampoline
        mkNdhStoreApiFor
        nixpkgs
        atticEnabledGuests
        ndhNixBashTrampolineDarwin
        ndhNixBashTrampolineLinux
        onDemandChecks
        canaryProvenWith
        ;
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
    default = import ../modules/nixos/zfs-disko-config.nix { lib = nixpkgs.lib; };
  }
  // builtins.foldl' (acc: hostOutput: acc // hostOutput.diskoConfigurations) { } (
    builtins.attrValues hostOutputs
  );

  diskoModules = {
    default = ../modules/nixos/disko.nix;
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
      ${builtins.readFile ../modules/darwin/bringup-observe.d/nix-build-observe.sh}
    '';

  packages = import ../flake/packages.nix {
    inherit
      self
      hostCatalog
      catalogData
      inputs
      mkNdhBootstrapRuntimePackage
      mkNdhBringupRuntimeInstaller
      mkNdhDiskoPinnedModule
      mkNdhLogCapturePackage
      mkNdhStoreApiFor
      mkNdhVmTartBootstrapInstallerPackage
      mkNixBuildObservePackage
      mkBaremetalLinkPackages
      incusClusterJoinPackages
      hostMainNameForProfile
      ndhBringupRuntimeAttr
      pkgsFor
      ndhNixBashTrampolineDarwin
      ndhNixBashTrampolineLinux
      nixpkgs
      ceremonyVm
      darwinConfigurations
      hostOutputs
      ;
  };

  apps = import ../flake/apps.nix {
    inherit
      self
      hostCatalog
      catalogData
      hostMainNameForProfile
      baremetalLinkHosts
      incusClusterJoinPackages
      ndhBringupInstallerCommand
      ndhLogCaptureCommand
      ndhVmTartBootstrapInstallerAttr
      inputs
      mkBaremetalLinkDeploy
      mkNdhBringupRuntimeInstaller
      mkNdhLogCapturePackage
      mkNdhVmTartBootstrapInstallerPackage
      mkNixBuildObservePackage
      ndhNixBashTrampolineDarwin
      ndhStoreApiDarwin
      pkgsFor
      pkgsForDarwin
      pkgsUnstableForDarwin
      worktreePath
      forAllSystems
      nixpkgs
      ;
  };

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
      # A bringup image ships only on a guard proven at its current derivation (🛡️, 2026-10-24): the in-guest canary
      # left the default checks, so its last green run is recorded, and an image whose canary moved since refuses
      # to evaluate, naming the run that proves it again. Every image route (packages, nixosDiskImages, the tart
      # deploy and materialize bundles) goes through this one binding.
      nixosDiskImageBringupSystemdZfs = canaryProven nixosOutputs.diskImageBringupZfsSystemdBootUngated;
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
            ../modules/home-manager
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
        pkgsForDarwin.replaceVars ../modules/.common.d/bringup-runtime.d/prerequisites-install-wrapper.sh
          {
            bash = "${pkgsForDarwin.bash}/bin/bash";
            loggerTag = "ndh.bringup-runtime.prerequisites-install.darwin";
            autofsMaterializerProgram =
              if autofsNetMaterializerProgram != null then autofsNetMaterializerProgram else "";
            standaloneInstaller = "${ndhBootstrapInstallerPackage}/bin/${ndhBringupInstallerCommand}";
          };
      ndhPrerequisitesInstallerScriptSourceLinux =
        pkgsForLinux.replaceVars ../modules/.common.d/bringup-runtime.d/prerequisites-install-wrapper.sh
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

  incusClusterJoinPackages = import ../pkgs/incus-cluster-join.d {
    pkgs = pkgsForDarwin;
    catalog = catalogData;
    ndhStore = ndhStoreApiDarwin;
    nixBashTrampoline = ndhNixBashTrampolineDarwin;
    storagePools = incusStoragePools;
  };

  # Every name a fleet machine answers to, from the map ssh-keys-certify signs (roles × keys S3a):
  # the clients trust the host authority for these names only, and check them strictly.
  fleetHostNames = nixpkgs.lib.concatLists (nixpkgs.lib.attrValues fleetHostCertificates.names);
  # What ssh-keys-certify signs host certificates for, read by the seat's module (ndh.ndhSwitch.sshKeysCertify).
  inherit fleetHostCertificates;
  # Each machine's own names, the principals of its ONE host certificate (keys-reconcile signs it from these).
  fleetHostNamesByMachine = fleetHostCertificates.names;

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
  overlayFactories = import ../flake/overlays.nix { inherit inputs; };

  # Standard nixpkgs overlays with inputs pre-applied — correct type for the flake overlays output.
  overlays = nixpkgs.lib.mapAttrs (_: f: f inputs) overlayFactories;

  homeManagerModules = import ../flake/home-manager-modules.nix;

}
