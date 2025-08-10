{ self, config, pkgs, ... }:
let

  user = config.profile.user;
  userName = user.name;
  userDescription = user.description;
  userHome = user.home;
  userShell = user.shell;

in {
  imports = [ ./networking.nix ];

  # auto manage nixbld users with nix darwin
  nix = {

    extraOptions = ''
      accept-flake-config = true
      extra-substituters = https://install.determinate.system
      extra-trusted-public-keys = cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM= cache.flakehub.com-4:Asi8qIv291s0aYLyH6IOnr5Kf6+OF14WVjkE6t3xMio= cache.flakehub.com-5:zB96CRlL7tiPtzA9/WKyPkp3A2vqxqgdgyTVNGShPDU= cache.flakehub.com-6:W4EGFwAGgBj3he7c5fNh9NkOXw0PUVaxygCVKeuvaqU= cache.flakehub.com-7:mvxJ2DZVHn/kRxlIaxYNMuDG1OvMckZu32um1TadOR8= cache.flakehub.com-8:moO+OVS0mnTjBTcOUh2kYLQEd59ExzyoW1QgQ8XAARQ= cache.flakehub.com-9:wChaSeTI6TeCuV/Sg2513ZIM9i0qJaYsF+lZCXg0J6o= cache.flakehub.com-10:2GqeNlIp6AKp4EF2MVbE1kBOp9iBSyo0UPR9KoR0o1Y=

      upgrade-nix-store-path-url = https://install.determinate.systems/determinate-nix/stable/fallback-paths.nix

      extra-experimental-features = nix-command flakes
      extra-platforms = aarch64-darwin
      extra-nix-path = nixpkgs=flake:https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/*.tar.gz
      always-allow-substituters = true
      min-free = ${toString (10 * 1024 * 1024 * 1024)}  # 10 GB
      max-free = ${toString (20 * 1024 * 1024 * 1024)}  # 20 GB
      ssl-cert-file = /etc/nix/macos-keychain.crt

      include flox.conf
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
