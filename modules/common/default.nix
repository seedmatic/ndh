{
  config,
  lib,
  pkgs,
  self,
  userMapping,
  ...
}:
let

  cfg = config.profile;
  user = cfg.user;
  userName = user.name;
  userHome = "${if pkgs.stdenvNoCC.isDarwin then "/Users" else "/home"}/${userName}";
  hmActivationPackage = lib.attrByPath [
    "home-manager"
    "users"
    userName
    "activationPackage"
  ] null config;
  hmUserExists = hmActivationPackage != null;

  # Define systemPackages separately
  systemPackages = import ./system-packages.nix {
    inherit pkgs lib;
    # Pass only necessary parts of config, not the entire config
    inherit (config) programs environment;
  };

  extraActivationScript = pkgs.runCommand "extra-activation.sh" { } ''
    cp ${./default.d/extra-activation.sh} "$out"
    chmod +x "$out"
  '';

  postActivationScript = pkgs.replaceVars ./default.d/post-activation.sh {
    hmActivationPackage = toString hmActivationPackage;
    userName = userName;
    userHome = userHome;
  };

in
{

  imports = [
    ../../profiles/common.nix
    ./primary-user.nix
    ./user.nix
    ./nixpkgs.nix
    ./dns-servers.nix
    ./dnsmasq.nix
    ./lima-host.nix
    ./distributed-builds-option.nix
  ];

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
  hm = import ../home-manager {
    inherit
      config
      pkgs
      lib
      user
      self
      ;
  };

  # Enable shell tracing early for easier debugging of activation scripts
  # Use extraActivation which runs early in the activation sequence
  system.activationScripts.extraActivation.text = lib.mkBefore ''
    ${extraActivationScript}
  '';

  # Run home-manager after all other activation steps so user files see final system state
  system.activationScripts.postActivation.text = lib.mkOrder 2000 (
    lib.optionalString (pkgs.stdenvNoCC.isDarwin && hmUserExists) ''
      ${postActivationScript}
    ''
  );

  # let nix manage home-manager profiles and use global nixpkgs
  home-manager = {
    extraSpecialArgs = {
      inherit self userMapping;
      profile = config.profile;
    };
    useGlobalPkgs = true;
    useUserPackages = true;
    verbose = true;
    backupFileExtension = "nix-backup";
  };

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
