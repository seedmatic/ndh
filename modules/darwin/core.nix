{
  inputs,
  config,
  pkgs,
  ...
}: let
  inherit (pkgs.stdenvNoCC) isAarch64 isAarch32;
in {
  environment = {
    loginShell = pkgs.zsh;
    etc = {darwin.source = "${inputs.darwin}";};
    # Use a custom configuration.nix location.
    # $ darwin-rebuild switch -I darwin-config=$HOME/.config/nixpkgs/darwin/configuration.nix

    # packages installed in system profile (more in ../common.nix)
    # systemPackages = [ ];
  };

  # auto manage nixbld users with nix darwin
  nix = {
    configureBuildUsers = true;
    nixPath = ["darwin=/etc/${config.environment.etc.darwin.target}"];
    extraOptions = ''
      extra-platforms = x86_64-darwin aarch64-darwin
    '';
  };

  nixpkgs.config.allowBroken = true;

  launchd.user.envVariables = {
    XDG_RUNTIME_DIR = "${config.user.home}/.xdg";
  };

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
}
