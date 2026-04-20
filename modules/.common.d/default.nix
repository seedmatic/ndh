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
  loggerBase = ./shell.d/logger.sh;
  loggerScript = pkgs.runCommand (prefixStoreName "logger.sh") { } ''
        cat > "$out" <<'EOF'
    #!/usr/bin/env bash
    LOGGER_CMD=""
    source ${loggerBase}
    EOF
  '';
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

  trampolineDir = pkgs.runCommand (prefixStoreName "trampoline-dir") { } ''
    mkdir -p "$out"
    install -m 0644 ${loggerBase} "$out/logger.sh"
    install -m 0755 ${./shell.d/nix-bash-trampoline.sh} "$out/nix-bash-trampoline.sh"
  '';
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
    lookupScript = ndhStoreAssetLookupScript;
    lookupPackage = ndhStoreAssetLookupPackage;
    lookupQuery = name: "^${lib.escapeRegex (prefixedName name)}$";
  };

in
{

  options.nixBashLogger.cmd = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "Command line (with %TAG% placeholder) used by the shared nix bash logger wrapper.";
  };

  options.nixBashLogger.script = lib.mkOption {
    type = lib.types.path;
    readOnly = true;
    description = "Shared nix bash logger wrapper script that exports LOGGER_CMD.";
  };

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
    ../../profiles/.common.nix
    ./cachix-watch-store.nix
    ./sops.nix
    ./primary-user.nix
    ./user.nix
    ./nixpkgs.nix
    ./io-nxmatic-nix-darwin-home-bringup-runtime.nix
    ./dns-servers.nix
    ./dnsmasq.nix
    ./lima-host.nix
    ./distributed-builds-option.nix
  ];

  config = {

    _module.args.ndh = {
      store = ndhStore;
    };

    nixBashLogger.script = loggerScript;
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
      import ../home-manager {
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

      variables = {
        XDG_RUNTIME_DIR = "${userHome}/.xdg";
      };

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
