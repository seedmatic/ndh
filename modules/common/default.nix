{ inputs, config, lib, pkgs, self, ... }:
let
  inherit (lib) mkOption mkDefault types mkIf;

  cfg = config.profile;
  user = cfg.user;
  userName = user.name;
  userDescription = user.description;
  userHome =  "${if pkgs.stdenvNoCC.isDarwin then "/Users" else "/home"}/${userName}";

  # Define systemPackages separately
  systemPackages = import ./system-packages.nix {
    inherit pkgs inputs;
    # Pass only necessary parts of config, not the entire config
    inherit (config) programs environment;
  };

in {

  imports = [
    ./primary-user.nix
    ./nixpkgs.nix
    ./dnsmasq.nix
    ./qemu.nix
  ];

  programs = {
    zsh = {
      enable = true;
      enableCompletion = true;
      enableBashCompletion = true;
    };
  };

  # bootstrap home manager using system config
  hm = import ../home-manager { inherit config pkgs lib user self; };

  # let nix manage home-manager profiles and use global nixpkgs
  home-manager = {
    extraSpecialArgs = {inherit self inputs;};
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
    variables = {
      XDG_RUNTIME_DIR = "${userHome}/.xdg";
    };

    systemPackages = import ./system-packages.nix {
      inherit pkgs inputs config;
    };

    etc = {
      home-manager.source = "${inputs.home-manager}";
      nixpkgs.source = "${inputs.nixpkgs}";
    };

    # list of acceptable shells in /etc/shells
    shells = with pkgs; [bash zsh fish];
  };

  services.tailscale = {
    enable = true;
    #logDir = config.logDir or null; # Use the value of the logDir option, or null if it is not set
  };

  fonts = {
    packages = with pkgs; [powerline-fonts];
  };

}
