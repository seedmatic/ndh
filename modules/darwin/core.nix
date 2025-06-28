{ inputs, config, pkgs, ... }:
let

  user = config.profile.user;
  userName = user.name;
  userDescription = user.description;
  userHome = user.home;
  userShell = user.shell;

in {
  imports = [ ./environment.nix ./networking.nix ];

  environment = {
    etc = { darwin.source = "${inputs.darwin}"; };
    # packages installed in system profile (more in ../common/default.nix)
    # systemPackages = [ ];
  };

  # auto manage nixbld users with nix darwin
  nix = {
    nixPath = [ "darwin=/etc/${config.environment.etc.darwin.target}" ];

    extraOptions = ''
      accept-flake-config = true
      experimental-features = nix-command flakes
      extra-platforms = x86_64-darwin aarch64-darwin
      min-free = ${toString (10 * 1024 * 1024 * 1024)}  # 10 GB
      max-free = ${toString (20 * 1024 * 1024 * 1024)}  # 20 GB
    '';

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

  users.users.${userName} = {
    home = userHome;
    description = userDescription;
    shell = userShell;
  };

}
