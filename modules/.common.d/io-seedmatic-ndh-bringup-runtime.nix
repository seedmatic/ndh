{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.ndh.bringupRuntime;
  ndhContext = ndh.context;
  installerCommand = "nerd-bringup-install";
  installerAttrDefault = "nerd-bringup-install";
  hostNameForAttr =
    if
      config ? profile
      && config.profile ? host
      && config.profile.host ? hostAlias
      && config.profile.host.hostAlias != null
      && config.profile.host.hostAlias != ""
    then
      config.profile.host.hostAlias
    else if
      config ? profile
      && config.profile ? host
      && config.profile.host ? hostName
      && config.profile.host.hostName != null
      && config.profile.host.hostName != ""
    then
      config.profile.host.hostName
    else
      null;
  installerAttr =
    if hostNameForAttr != null then "${hostNameForAttr}-bringup-install" else installerAttrDefault;
  storeNamePrefix = "io.seedmatic.ndh";
  prefixStoreName =
    name: if lib.hasPrefix "${storeNamePrefix}-" name then name else "${storeNamePrefix}-${name}";
  requiredCommandsString = lib.concatStringsSep " " cfg.requiredCommands;
  installHint = "nix run .#${installerAttr} -- ${cfg.profileDir}";
  loggerShim = pkgs.writeShellScriptBin "logger" ''
    if [[ -x /usr/bin/logger ]]; then
      exec /usr/bin/logger "$@"
    fi
    if [[ -x /run/current-system/sw/bin/logger ]]; then
      exec /run/current-system/sw/bin/logger "$@"
    fi
    echo "[ndh][WARN] logger binary unavailable; message was: $*" >&2
    exit 0
  '';
  # The tools every trampoline script finds here, on top of the base set below: one profile per machine, built
  # for its platform, a common layer and a platform's own. Two costs, both measured 2026-10-22: what the machine
  # pays is what its system does not already hold, 0 MB on the NixOS guests and 4 MB on the darwin seats; what a
  # `nix copy` of the profile ALONE pays is its own closure, which the layers grow (see the profile's check). A
  # symlinkJoin links each package's own default output only, so a tool reached as another's dependency (gpg under
  # pass) is listed for itself, and a split output (util-linux's bin) is named.
  commonLayer = with pkgs; [
    curl
    diffutils
    gnupg
    openssl
    # pass depends on the full git, which pulls python3, llvm, clang and the apple-sdk: +1428 MB on darwin.
    # Against gitMinimal it builds the same password-store, and init/insert/show/git init work (measured).
    (pass.override { git = gitMinimal; })
    procps
    ssh-to-age
  ];
  # No darwin program calls a util-linux command (surveyed), and its darwin build ships a partial set: Linux only.
  # The trampoline puts this profile FIRST on PATH, so a command here wins over the system's: a system-bound one must
  # BE the system's package (its zfs matched to its kernel module, its incus to its daemon), never a sibling build.
  incusEnabled = config.virtualisation.incus.enable or false;
  linuxLayer = lib.optionals pkgs.stdenv.hostPlatform.isLinux (
    with pkgs;
    [
      getent
      iproute2
      util-linux.bin
      config.boot.zfs.package
      config.systemd.package
    ]
    ++ lib.optional incusEnabled config.virtualisation.incus.package
  );
  darwinLayer = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.tart ];
  bootstrapRuntimePackage = pkgs.symlinkJoin {
    name = prefixStoreName "bringup-runtime-profile-holder";
    paths =
      commonLayer
      ++ linuxLayer
      ++ darwinLayer
      ++ (with pkgs; [
        (lib.getBin bashInteractive)
        (lib.getBin config.nix.package)
        age
        coreutils-full
        findutils
        gawk
        # ⛔ NOT `git`. On darwin git pulls python3, which pulls clang, cctools and
        # the apple-sdk: 1614.9 MB of closure against gitMinimal's 159.3 MB, both
        # measured — git alone was 95% of this profile, and this profile is
        # `nix copy`'d to every vz-host. gitMinimal pulls no python3, clang or
        # apple-sdk at all.
        #
        # Everything reachable from the trampoline uses add / commit / rev-parse /
        # diff / clone / checkout / push / config, and nothing uses the perl or
        # python subcommands gitMinimal drops (`add -i`, `rebase -i`, send-email,
        # p4, svn, gitk) — surveyed across every *.sh and *.nix in the repo.
        gitMinimal
        gnugrep
        gnused
        keychain
        loggerShim
        openssh
        # The profile already carries `age`, which decrypts; `sops` is what every
        # script that reads or rewrites an encrypted document actually calls, and it
        # was the one tool a trampoline-sourced script had to find in the SYSTEM
        # profile instead. 53 MB of closure, against 1.6 GB for the git already
        # here — measured, not assumed.
        sops
        step-cli
        yq-go
      ]);
  };
  activationCheckSource =
    builtins.replaceStrings
      [
        "@profileBin@"
        "@nixBin@"
        "@autoInstall@"
        "@requiredCommands@"
        "@installHint@"
        "@runtimePackage@"
        "@bootstrapInstaller@"
        "@profileDir@"
      ]
      [
        "${cfg.profileDir}/bin"
        "${config.nix.package.out}/bin/nix"
        (if cfg.autoInstallOnActivation then "1" else "0")
        requiredCommandsString
        installHint
        "${bootstrapRuntimePackage}"
        "${ndhPrerequisitesInstallerPackage}/bin/${installerCommand}"
        cfg.profileDir
      ]
      (builtins.readFile ./bringup-runtime.d/activation-check.sh);
  # Activation check as a proper directory package — script lives in share/, not at the store root.
  # Defined after ndhPrerequisitesInstallerPackage due to @bootstrapInstaller@ reference.
  ndhActivationCheckPackage =
    pkgs.runCommand (prefixStoreName "bringup-runtime-activation-check") { }
      ''
        install -Dm755 ${pkgs.writeShellScript "activation-check" activationCheckSource} \
          "$out/share/activation-check.sh"
      '';
  # Canonical trampoline directory from the flake-level builder (single
  # version across initrd / activation / runtime — see
  # modules/.common.d/default.nix).
  trampolineDir = builtins.dirOf ndhContext.nixBashTrampoline;
  standaloneInstallSource =
    builtins.replaceStrings
      [
        "@nixBashTrampoline@"
        "@nix@"
        "@loggerTag@"
        "@runtimePackage@"
        "@defaultProfileDir@"
        "@requiredCommands@"
      ]
      [
        "${trampolineDir}/nix-bash-trampoline.sh"
        "${config.nix.package.out}/bin/nix"
        "ndh.bringup-runtime.install-standalone"
        "${bootstrapRuntimePackage}"
        cfg.profileDir
        requiredCommandsString
      ]
      (builtins.readFile ./bringup-runtime.d/install-standalone.sh);
  # Installer as a proper directory package — script lives in bin/, not at the store root.
  # standaloneInstallSource already has #!/usr/bin/env bash so writeTextFile is sufficient.
  ndhPrerequisitesInstallerPackage = pkgs.writeTextFile {
    name = prefixStoreName "bringup-runtime-profile-installer";
    text = standaloneInstallSource;
    executable = true;
    destination = "/bin/${installerCommand}";
  };
in
{
  options.ndh.bringupRuntime = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable dedicated Nix profile contract for NDH bringup runtime tools.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "io-seedmatic-ndh-bringup-runtime";
      description = "Dedicated Nix profile name for NDH bringup runtime tools.";
    };

    profileDir = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/profiles/per-user/root/${cfg.name}";
      description = "Absolute Nix profile path used by NDH bringup runtime scripts.";
    };

    requiredCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "bash"
        "nix"
        "age"
        "age-keygen"
        "awk"
        "sed"
        "grep"
        "ssh"
        "ssh-keygen"
        "sops"
        "step"
        "yq"
        "git"
        "logger"
        "curl"
        "diff"
        "gpg"
        "openssl"
        "pass"
        "ps"
        "ssh-to-age"
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        "getent"
        "ip"
        "findmnt"
        "zfs"
        "systemctl"
      ]
      ++ lib.optional incusEnabled "incus"
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ "tart" ];
      description = "Command contract that must be present in the dedicated bringup runtime profile.";
    };

    autoInstallOnActivation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "When true, activation installs/refreshes the dedicated bringup runtime profile before enforcing command checks.";
    };

    requireForActivation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Fail activation if dedicated bringup runtime profile is missing/incomplete.";
    };

    # Packages exposed for platform modules to consume. Read-only — built
    # here, used by (e.g.) modules/nixos/bringup-runtime.nix to wire the
    # systemd unit that installs the profile on first boot.
    runtimePackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "symlinkJoin derivation holding the full bringup runtime command set.";
    };

    installerPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Standalone installer (writeTextFile) that materializes runtimePackage into a Nix profile.";
    };

    installerCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Name of the installer binary inside installerPackage (bin/<name>).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Canonical policy (@codebase): always install/refresh NDH bringup
    # prerequisites during activation.
    ndh.bringupRuntime = {
      autoInstallOnActivation = lib.mkForce true;
      runtimePackage = bootstrapRuntimePackage;
      installerPackage = ndhPrerequisitesInstallerPackage;
      inherit installerCommand;
    };

    environment.variables = {
      NDH_BOOTSTRAP_PROFILE_OWNER = "root";
      NDH_BOOTSTRAP_PROFILE_DIR = cfg.profileDir;
      NDH_BOOTSTRAP_PROFILE_BIN = "${cfg.profileDir}/bin";
      NDH_BOOTSTRAP_INSTALL_ATTR = installerAttr;
      NDH_BOOTSTRAP_RUNTIME_PACKAGE = "${bootstrapRuntimePackage}";
      NDH_BOOTSTRAP_INSTALLER = "${ndhPrerequisitesInstallerPackage}/bin/${installerCommand}";
      NDH_BOOTSTRAP_REQUIRED_COMMANDS = requiredCommandsString;
      NDH_BOOTSTRAP_STRICT = if cfg.requireForActivation then "1" else "0";
      NDH_BOOTSTRAP_INSTALL_HINT = installHint;
    };

    # preActivation is a cross-platform nix activation phase (both nix-
    # darwin and NixOS honour it). Safe to keep here.
    system.activationScripts.preActivation.text = lib.mkOrder 0 ''
      ${ndhActivationCheckPackage}/share/activation-check.sh
    '';
  };
}
