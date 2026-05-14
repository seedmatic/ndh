{
  config,
  lib,
  options,
  pkgs,
  self,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  userMapping = ndhContext.catalog.users;
  isNixosPlatform = options ? systemd;
  effectiveHostProfile = ndhContext.hostProfile;
  effectiveGenerationMode = ndhContext.generationMode;
  effectiveCatalog = ndhContext.catalog;
  effectiveInventory = ndhContext.inventory;
  effectiveVmProviderFromContext = ndhContext.vmProvider;
  # Bootstrap image mode is a NixOS guest concern. Keep Home Manager enabled on
  # Darwin hosts even when they orchestrate bootstrap guest flows.
  bringupModeInternal = isNixosPlatform && effectiveGenerationMode == "bringup";
  requestedHomeManagerEnabled =
    if
      effectiveHostProfile != null
      && effectiveHostProfile ? enableHomeManager
      && effectiveHostProfile.enableHomeManager != null
    then
      effectiveHostProfile.enableHomeManager
    else
      true;
  homeManagerEnabled = if bringupModeInternal then false else requestedHomeManagerEnabled;
  hasHomeManagerOption = builtins.hasAttr "home-manager" options;
  selectedVmProvider =
    if
      effectiveHostProfile != null
      && effectiveHostProfile ? vmProvider
      && effectiveHostProfile.vmProvider != null
    then
      effectiveHostProfile.vmProvider
    else if effectiveVmProviderFromContext != null then
      effectiveVmProviderFromContext
    else if
      (!isNixosPlatform) && (lib.attrByPath [ "profile" "host" "vmProvider" ] null config) != null
    then
      lib.attrByPath [ "profile" "host" "vmProvider" ] null config
    else
      "lima";
  limaConfigMaterializerPackage = lib.attrByPath [
    "lima"
    "configGenerator"
    "materializerPackage"
  ] null (if isNixosPlatform then { } else config);
  tartConfigMaterializerPackage = lib.attrByPath [
    "tart"
    "configGenerator"
    "materializerPackage"
  ] null (if isNixosPlatform then { } else config);
  vmConfigMaterializerPackage =
    if selectedVmProvider == "tart" then
      tartConfigMaterializerPackage
    else
      limaConfigMaterializerPackage;
  mkNdhHomeManagerSpecialArgs = import ./ndh-home-manager-special-args.nix;
  sopsSshKeysYamlPath = lib.attrByPath [
    "sops"
    "secrets"
    "ssh-keys.yaml"
    "path"
  ] "/run/secrets/nix-darwin-home/ssh-keys.yaml" config;
  hmSpecialArgs = mkNdhHomeManagerSpecialArgs {
    inherit
      self
      profile
      ndhContext
      ndhStore
      vmConfigMaterializerPackage
      ;
    keysYamlPath = sopsSshKeysYamlPath;
  };

  cfg = config.profile;
  profile = cfg;
  user = cfg.user;
  userName = user.name;
  userHome = toString cfg.user.home;
  activationLogFile = "${userHome}/.local/state/nix/activation.log";
  hmActivationPackage = lib.attrByPath [
    "home-manager"
    "users"
    userName
    "home"
    "activationPackage"
  ] null (if isNixosPlatform then { } else config);
  storeNamePrefix = "io.nxmatic.nix-darwin-home";
  prefixStoreName =
    name: if lib.hasPrefix "${storeNamePrefix}-" name then name else "${storeNamePrefix}-${name}";
  loggerTagHmPost = "common.activationScripts.postActivation.home-manager";
  # Define systemPackages separately
  systemPackages =
    (import ./system-packages.nix {
      inherit pkgs lib;
    })
    ++ [ ndhStoreAssetLookupPackage ];

  postActivationScriptSource = pkgs.replaceVars ./shell.d/post-activation.sh {
    nixBashTrampoline = "${trampolineDir}/nix-bash-trampoline.sh";
    hmActivationPackage = toString hmActivationPackage;
    userName = userName;
    userHome = userHome;
    loggerTag = loggerTagHmPost;
  };

  postActivationScript = pkgs.runCommand (prefixStoreName "hm-post-activation.sh") { } ''
    install -m 0555 ${postActivationScriptSource} "$out"
  '';

  installStoreScript =
    {
      name,
      source,
      preferLocalBuild ? null,
      allowSubstitutes ? null,
      mode ? "0555",
    }:
    pkgs.runCommand (prefixStoreName name)
      (
        (lib.optionalAttrs (preferLocalBuild != null) { inherit preferLocalBuild; })
        // (lib.optionalAttrs (allowSubstitutes != null) { inherit allowSubstitutes; })
      )
      ''
        install -m ${mode} ${source} "$out"
      '';

  # Canonical trampoline directory — produced once at flake level by
  # mkNdhNixBashTrampoline and surfaced through ndh.context.  Deriving it
  # here from the trampoline file path keeps the `.common.d` layer free of
  # a duplicate builder that has historically drifted from the flake-level
  # one (different logger content, different LOGGER_CMD binding).
  trampolineDir = builtins.dirOf ndhContext.nixBashTrampoline;
  ndhStoreAssetLookupSource = pkgs.replaceVars ./shell.d/store-asset-lookup.sh {
    nixBashTrampoline = "${trampolineDir}/nix-bash-trampoline.sh";
    nix = toString pkgs.nix;
    gnugrep = toString pkgs.gnugrep;
    coreutils = toString pkgs.coreutils;
    defaultStorePrefix = storeNamePrefix;
  };

  ndhStoreAssetLookupScript = installStoreScript {
    name = "store-asset-lookup.sh";
    source = ndhStoreAssetLookupSource;
  };

  ndhStoreAssetLookupPackage = pkgs.writeShellApplication {
    name = "io.nxmatic.nix-darwin-home-store-asset-lookup";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      gnugrep
      nix
    ];
    text = ''
      export NDH_STORE_PREFIX='${ndhStore.prefix}'
      exec ${pkgs.bash}/bin/bash ${ndhStoreAssetLookupScript} "$@"
    '';
  };

  ndhStore = rec {
    prefix = storeNamePrefix;
    prefixedName = prefixStoreName;
    installScript = installStoreScript;
    runCommand =
      name: attrs: text:
      pkgs.runCommand (prefixedName name) attrs text;
    writeText = name: text: pkgs.writeText (prefixedName name) text;
    writeShellScript = name: text: pkgs.writeShellScript (prefixedName name) text;
    # Like writeShellScript but produces a bin/ directory package.
    # Store drv has the prefixed name; the executable inside is just <name>.
    writeShellScriptBin =
      name: text:
      pkgs.runCommand (prefixedName name) { } ''
        install -Dm755 ${pkgs.writeShellScript name text} "$out/bin/${name}"
      '';
    # Wrap a pre-built source (e.g. replaceVars output) in a bin/ package.
    # Store drv uses the ndh-prefixed name; executable is at $out/bin/<name>.
    installBinScript =
      name: source:
      pkgs.runCommand (prefixedName name) { } ''
        install -Dm755 ${source} "$out/bin/${name}"
      '';
    # Mirror of flake.nix's mkNdhStoreApiFor.installBinScriptBundle — this
    # variant of ndh.store is consumed by home-manager via the specialArgs
    # constructed at ndh-home-manager-special-args.nix.
    installBinScriptBundle =
      name: scripts:
      pkgs.runCommand (prefixedName name) { } (
        "mkdir -p $out/bin\n"
        + lib.concatStrings (
          lib.mapAttrsToList (binName: src: ''
            install -Dm755 ${src} "$out/bin/${binName}"
          '') scripts
        )
      );
    lookupScript = ndhStoreAssetLookupScript;
    lookupPackage = ndhStoreAssetLookupPackage;
    lookupQuery = name: "^${lib.escapeRegex (prefixedName name)}$";
  };

in
{

  options.activation.homeManagerPostActivationScript = lib.mkOption {
    type = lib.types.path;
    readOnly = true;
    description = "Wrapped Home Manager post-activation script produced by common module logic.";
  };

  options.activation.postActivationLogShowLabel = lib.mkOption {
    type = lib.types.str;
    default = "activation logs (recent)";
    description = "Label shown for post-activation recent-log inspection command.";
  };

  options.activation.postActivationLogShowCmd = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "Platform-provided command for inspecting recent activation logs after post-activation.";
  };

  options.activation.postActivationLogStreamLabel = lib.mkOption {
    type = lib.types.str;
    default = "activation logs (stream)";
    description = "Label shown for post-activation live-log streaming command.";
  };

  options.activation.postActivationLogStreamCmd = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "Platform-provided command for streaming activation logs after post-activation.";
  };

  imports = [
    # Profile & user
    "${self}/profile.nix"
    ./primary-user.nix
    ./user.nix

    # Secrets (SOPS)
    ./sops.nix
    ./tailnet.nix
    ./headscale-pkg.nix

    # SSH identity (keys.yaml access, nix-store cert-signed identity)
    ./keys-yaml.nix
    ./nix-store-identity.nix

    # Nix daemon configuration
    ./nixpkgs.nix
    ./nix-settings.nix
    ./cache-trust.nix
    ./cachix-watch-store.nix
    ./io-nxmatic-nix-darwin-home-bringup-runtime.nix

    # Networking
    ./dns-servers.nix
    ./dnsmasq.nix
    ./lima-host.nix

    # VM tooling & observability
    ./vm-materializer.nix
    ./bringup-observe.nix
  ];

  config = {

    _module.args.ndh = {
      store = ndhStore;
    };

    activation.homeManagerPostActivationScript = postActivationScript;

    programs = {

      bash = {
        completion.enable = true;
      };

      zsh = {
        enable = true;
        enableCompletion = true;
        enableBashCompletion = true;
      };
    };

    # bootstrap home manager using system config
    hm = lib.mkIf homeManagerEnabled (
      import "${self}/modules/home-manager" {
        inherit
          pkgs
          lib
          user
          self
          profile
          ;
        config = { };

        # Provide specialArgs explicitly for direct imports
        specialArgs = hmSpecialArgs;
      }
    );

    # zen-browser = {
    #    enable = false;
    #    packages = pkgs.zen-browser-unwrapped;
    #  };

    # environment setup
    environment = {

      inherit systemPackages;

      # Deliberately *not* setting XDG_RUNTIME_DIR system-wide:
      # systemd-logind creates `/run/user/$UID` per-user-session and PAM
      # exports XDG_RUNTIME_DIR for interactive sessions.  A prior
      # override to `${userHome}/.xdg` caused any root-run consumer (an
      # activation script, a system systemd unit inheriting the global
      # env) that touched the path to auto-create it with root
      # ownership, which then broke `home-manager-<user>.service`'s
      # per-user activation.  Callers that genuinely need a specific
      # XDG_RUNTIME_DIR (e.g. the home-manager post-activation hook at
      # modules/.common.d/shell.d/post-activation.sh) set it explicitly
      # in their own environment.

      # list of acceptable shells in /etc/shells
      shells = with pkgs; [
        bash
        zsh
        fish
      ];
    };

    services.tailscale = {
      enable = true;
    };

    # Point tailscaled (Go, uses crypto/x509) at the nix-darwin-built
    # system CA bundle so it trusts our `mammoth-skate` root alongside
    # the stock Mozilla store.  macOS's System keychain refuses to
    # install an Ed25519 CA (Apple's Security framework rejects the
    # curve at trust-insertion time with "Unknown format in import"),
    # so the keychain path that works for Chrome/Safari is unavailable
    # to us.  Go honours `SSL_CERT_FILE` when set in its process env;
    # injecting it into the launchd daemon is the minimal fix that
    # unblocks tailscaled against a self-signed LAN headscale.
    #
    # Rationale for not chasing the keychain path: we'd have to re-key
    # the authority to ECDSA P-256, re-issue every SSH cert + every TLS
    # leaf, and add a macOS-specific `security add-trusted-cert`
    # activation script — a lot of churn for a cohort of one user-facing
    # Go daemon.  If browser trust becomes necessary later we revisit.
    launchd.daemons.tailscaled.serviceConfig.EnvironmentVariables = {
      SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      # Force Go's pure-Go x509 verifier instead of delegating to
      # Apple's Security framework.  Apple's SecTrust rejects
      # Ed25519 certs at validation time with "broken key size"
      # even when the chain is otherwise valid and the root is
      # in the env-trusted bundle.  Go 1.22+ with
      # `x509usefallbackroots=1` honours SSL_CERT_FILE and uses
      # its own Ed25519-aware validator.  Scoped to tailscaled
      # only so other Go daemons on the system keep macOS-native
      # validation.
      GODEBUG = "x509usefallbackroots=1";
    };

    fonts = {
      packages = with pkgs; [ powerline-fonts ];
    };

    limaHost = {
      guestName = "nixos";
    };
  }
  // (lib.optionalAttrs (homeManagerEnabled && hasHomeManagerOption) {
    # let nix manage home-manager profiles and use global nixpkgs
    home-manager = {
      extraSpecialArgs = hmSpecialArgs;
      useGlobalPkgs = true;
      useUserPackages = true;
      verbose = true;
      backupFileExtension = "nix-backup";
      overwriteBackup = true;
    };
  });

}
