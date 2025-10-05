{ config, lib, pkgs, self, ... }:
let

  cfg = config.profile;
  user = cfg.user;
  userName = user.name;
  userHome =
    "${if pkgs.stdenvNoCC.isDarwin then "/Users" else "/home"}/${userName}";

  # Define systemPackages separately
  systemPackages = import ./system-packages.nix {
    inherit pkgs;
    # Pass only necessary parts of config, not the entire config
    inherit (config) programs environment;
  };

in {

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

    bash = { completion.enable = true; };

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
    extraSpecialArgs = {
      inherit self;
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

    variables = { XDG_RUNTIME_DIR = "${userHome}/.xdg"; };

    # list of acceptable shells in /etc/shells
    shells = with pkgs; [ bash zsh fish ];
  };

  services.tailscale = { enable = true; };

  fonts = { packages = with pkgs; [ powerline-fonts ]; };

  limaHost = { guestName = "nixos"; };

}
