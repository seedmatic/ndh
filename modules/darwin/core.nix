{ self, config, pkgs, ... }:
let
  user = config.profile.user;
  userName = user.name;
  userDescription = user.description;
  userHome = user.home;
  userShell = user.shell;

in {
  imports = [ ./networking.nix ];

  # Enable automatic backup of conflicting files during activation
  environment.etc.backup.enable = true;

  # auto manage nixbld users with nix darwin
  nix = {

    extraOptions = ''
      include /etc/nix/flox.conf
      accept-flake-config = true
      always-allow-substitutes = true
      min-free = ${toString (10 * 1024 * 1024 * 1024)}  # 10 GB
      max-free = ${toString (20 * 1024 * 1024 * 1024)}  # 20 GB
      ssl-cert-file = /etc/ssl/cert.pem
      extra-experimental-features = nix-command flakes
      extra-platforms = aarch64-darwin
    '';

    # Configure NIX_PATH for legacy nix commands and <nixpkgs> imports
    nixPath = [
      "nixpkgs=${pkgs.path}"
      "darwin=${self.inputs.darwin}"  
      "home-manager=${self.inputs.home-manager}"
    ];

    # Optimize the store
    optimise.automatic = true;
  };

  nixpkgs.config = import ../common/nixpkgs-config.nix;

  # nixpkgs.overlays = [
  #   (self: super: {
  #     # Disable checks for all packages
  #     all = super.all.overrideAttrs (oldAttrs: {
  #       doCheck = false;
  #       doInstallCheck = false;
  #     });
  #   })
  # ];

  launchd.user.envVariables = { XDG_RUNTIME_DIR = "${userHome}/.xdg"; };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 5;

  system.primaryUser = userName;

  users.users.${userName} = {
    home = userHome;
    description = userDescription;
    shell = userShell;
  };

}
