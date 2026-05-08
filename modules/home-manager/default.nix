# This is the home configuration of the user.
{
  config,
  pkgs,
  lib,
  floxEnv ? null,
  self,
  # When imported from the system layer we pass `profile` directly; when
  # evaluated inside home-manager proper, it is available via
  # `config._module.specialArgs.profile`.
  profile ? null,
  # Allow direct imports to provide specialArgs when _module.specialArgs is absent
  specialArgs ? { },
  ...
}:
let
  specialArgsResolved =
    (if config ? _module && config._module ? specialArgs then config._module.specialArgs else { })
    // specialArgs;

  ndhContext =
    if
      specialArgsResolved ? ndh
      && specialArgsResolved.ndh != null
      && specialArgsResolved.ndh ? context
      && specialArgsResolved.ndh.context != null
    then
      specialArgsResolved.ndh.context
    else
      null;

  nixBashTrampoline =
    if ndhContext != null && ndhContext ? nixBashTrampoline then
      "${ndhContext.nixBashTrampoline}"
    else
      "${self}/modules/.common.d/shell.d/nix-bash-trampoline.sh";

  ndhArgs =
    if specialArgsResolved ? ndh && specialArgsResolved.ndh != null then
      specialArgsResolved.ndh
    else
      { };

  ndhVmArgs = if ndhArgs ? vm && ndhArgs.vm != null then ndhArgs.vm else { };

  ndhLoggerArgs = if ndhArgs ? logger && ndhArgs.logger != null then ndhArgs.logger else { };

  vmConfigMaterializerPackage =
    if ndhVmArgs ? configMaterializerPackage then ndhVmArgs.configMaterializerPackage else null;

  resolvedProfile =
    if profile != null then profile else lib.attrByPath [ "profile" ] null specialArgsResolved;

  profileName =
    if resolvedProfile != null && resolvedProfile ? name && resolvedProfile.name != null then
      resolvedProfile.name
    else
      null;

  selectedVmProvider =
    if resolvedProfile != null && resolvedProfile ? host && resolvedProfile.host ? vmProvider then
      resolvedProfile.host.vmProvider
    else if ndhContext != null && ndhContext ? vmProvider && ndhContext.vmProvider != null then
      ndhContext.vmProvider
    else
      "lima";

  effectiveHostName =
    if
      resolvedProfile != null
      && resolvedProfile ? host
      && resolvedProfile.host ? hostAlias
      && resolvedProfile.host.hostAlias != null
      && resolvedProfile.host.hostAlias != ""
    then
      resolvedProfile.host.hostAlias
    else if resolvedProfile != null && resolvedProfile ? host && resolvedProfile.host ? hostName then
      resolvedProfile.host.hostName
    else
      null;

  hostCatalogEntries =
    if
      ndhContext != null
      && ndhContext ? inventory
      && ndhContext.inventory ? hosts
      && effectiveHostName != null
    then
      lib.attrByPath [ effectiveHostName ] [ ] ndhContext.inventory.hosts
    else
      [ ];

  activatingOnVzHost = lib.any (
    entry:
    (entry ? form)
    && entry.form == "baremetal"
    && (entry ? vm)
    && (entry.vm ? kind)
    && entry.vm.kind == "vz"
  ) hostCatalogEntries;

  homeUsernameFallback = lib.attrByPath [ "home" "username" ] null config;
  homeDirectoryFallback = lib.attrByPath [ "home" "homeDirectory" ] null config;

  userName =
    if resolvedProfile != null && resolvedProfile ? user && resolvedProfile.user ? name then
      resolvedProfile.user.name
    else
      homeUsernameFallback;

  homeDirectory =
    if resolvedProfile != null && resolvedProfile ? user && resolvedProfile.user ? home then
      resolvedProfile.user.home
    else
      homeDirectoryFallback;

  homeDirectoryString = toString homeDirectory;
  homeDirectorySafe =
    if pkgs.stdenv.isLinux then
      "/home/${userName}"
    else if pkgs.stdenv.isDarwin && builtins.match ".* .*" homeDirectoryString != null then
      "/Users/${userName}"
    else
      homeDirectoryString;
  systemCaBundle =
    if pkgs.stdenvNoCC.isDarwin then "/etc/ssl/cert.pem" else "/etc/ssl/certs/ca-bundle.crt";

  loggerArgs =
    if ndhLoggerArgs != { } then ndhLoggerArgs else throw "specialArgs.ndh.logger is required";
  loggerTagFixConfigOwnership = "home-manager.activationScripts.${userName}.fixConfigOwnership";
  hmVmMaterializationEnabled =
    pkgs.stdenvNoCC.isDarwin
    && activatingOnVzHost
    && vmConfigMaterializerPackage != null
    && builtins.elem selectedVmProvider [
      "lima"
      "tart"
    ];

  resolvedImports = [
    ./avahi.nix
    ./bat.nix
    ./chromium.nix
    ./dircolors.nix
    ./direnv.nix
    ./dotfiles
    ./emacs.nix
    # ./firefox.nix
    ./flox-direnv.nix
    ./fzf.nix
    ./git.nix
    ./gh.nix
    ./gpg.nix
    ./java.nix
    ./keychain.nix
    # ./kitty.nix
    ./shadow-repositories.nix
    # ./nushell.nix
    ./password-store.nix
    ./socket-vmnet.nix
    ./shell.nix
    ./starship.nix
    ./ssh.nix
    ./ssh-keys.nix
    ./ssh-tailnet-hosts.nix
    ./ssh-keychain-removal.nix
    ./tldr.nix
    ./tmate.nix
    ./tmux.nix
    ./xdg.nix
  ];

  baseHomePackages =
    with pkgs;
    [
      alejandra
      awscli2
      avahi
      cachix
      cirrus-cli
      comma
      coreutils-full
      curl
      diffutils
      direnv
      docker
      docker-compose
      ffmpeg
      findutils
      flyctl
      gawk
      gdu
      gh
      git-workspace
      gnugrep
      gnupg
      gnused
      helm-docs
      httpie
      hurl
      jdk
      k9s
      kpt
      krew
      kubectl
      kubectx
      kubernetes-helm
      kustomize
      #     lazydocker
      luajit
      minikube
      mmv
      neofetch
      nix
      nixfmt-classic
      nixpkgs-fmt
      nodejs
      parallel
      passExtensions.pass-otp
      passExtensions.pass-audit
      passExtensions.pass-update
      passExtensions.pass-import
      passExtensions.pass-checkup
      passExtensions.pass-genphrase
      podman
      # podman-desktop
      poetry
      pnpm
      pre-commit
      # rancher-desktop
      ranger
      rclone
      rsync
      shellcheck
      sops
      stylua
      tig
      tree
      treefmt
      trivy
      vault-bin
      yarn
      yamllint
      yq-go
      zellij
      zsh
    ];

in
{

  imports = resolvedImports;

  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 1d";
  };

  home = {
    homeDirectory = lib.mkForce homeDirectorySafe; # Ensure home directory is set and avoid space-splitting activation issues on Darwin

    stateVersion = "25.11";

    sessionPath = [
      "${homeDirectorySafe}/.rd/bin"
      "${homeDirectorySafe}/.local/bin"
      "${homeDirectorySafe}/.krew/bin"
    ];

    # Define package definitions for current user environment
    packages = baseHomePackages;

    # Canonical TLS trust store path for user-space tooling (git, curl, nix,
    # plugin managers, etc.). Keep one source of truth per platform.
    sessionVariables = {
      SSL_CERT_FILE = systemCaBundle;
      NIX_SSL_CERT_FILE = systemCaBundle;
      GIT_SSL_CAINFO = systemCaBundle;
      CURL_CA_BUNDLE = systemCaBundle;
    };

    activation.fixConfigOwnership =
      let
        fixConfigOwnershipScript = pkgs.replaceVars ./default.d/fix-config-ownership.sh {
          nixBashTrampoline = nixBashTrampoline;
          loggerTag = loggerTagFixConfigOwnership;
        };
      in
      lib.hm.dag.entryBefore [ "writeBoundary" ] ''
        ${pkgs.bash}/bin/bash ${fixConfigOwnershipScript}
      '';

  };

  targets.genericLinux.enable = false;

  assertions = lib.optionals hmVmMaterializationEnabled (
    [
      {
        assertion = builtins.elem selectedVmProvider [
          "lima"
          "tart"
        ];
        message = ''
          Home Manager on Darwin requires a supported `vmProvider` for VM materialization.
          Supported values: "lima" or "tart".
        '';
      }
    ]
  );

  home.activation.materializeVm = lib.mkIf hmVmMaterializationEnabled (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      vm_provider="${selectedVmProvider}"
      case "$vm_provider" in
        lima)
          materializer_binary="nerd-lima-vm-materialize"
          ;;
        tart)
          materializer_binary="nerd-tart-vm-materialize"
          ;;
        *)
          echo "[vmConfig][ERROR] unsupported vm provider for HM materialization: $vm_provider" >&2
          exit 1
          ;;
      esac

      materializer="${vmConfigMaterializerPackage}/bin/$materializer_binary"

      if [[ ! -x "$materializer" ]]; then
        echo "[vmConfig][ERROR] missing Home Manager materializer executable: $materializer" >&2
        exit 1
      fi

      echo "[vmConfig] Home Manager activation: materializing $vm_provider assets and gcroot image"
      NDH_GCROOT_USER="${userName}" "${pkgs.bash}/bin/bash" "$materializer"
    ''
  );

  programs = {

    home-manager.enable = lib.mkDefault true;

    zsh.enable = lib.mkDefault true;

    dircolors.enable = lib.mkDefault true;

    go.enable = lib.mkDefault true;

    gpg.enable = lib.mkDefault false;

    password-store.enable = lib.mkDefault true;

    git.enable = lib.mkDefault true;

    htop.enable = lib.mkDefault true;

    jq.enable = lib.mkDefault true;

    java.enable = lib.mkDefault true;

    k9s.enable = lib.mkDefault true;

    lazygit.enable = lib.mkDefault true;

    less.enable = lib.mkDefault true;

    man.enable = lib.mkDefault true;

    nix-index.enable = lib.mkDefault true;

    pandoc.enable = lib.mkDefault true;

    ripgrep.enable = lib.mkDefault true;

    starship.enable = lib.mkDefault true;

    yt-dlp.enable = lib.mkDefault false;

    zoxide.enable = lib.mkDefault true;

    zellij.enable = lib.mkDefault true;
  };

  services = {
    # Enable the emacs daemon
    emacsDaemon = {
      enable = true;
    };

    # Enable shadowing folders
    shadowRepositories = {
      enable = false;

      mountPoints = [
        "/Volumes/GitHub/HylandSoftware/hxpr"
        "/Volumes/GitHub/nuxeo/nos"
      ];
    };
  };
}
