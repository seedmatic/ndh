{
  inputs,
  config,
  pkgs,
  ...
}: let
  gcScript = pkgs.writeScript "nix-gc-script" ''
    #!${pkgs.bash}/bin/bash
    ${config.nix.package}/bin/nix-collect-garbage --delete-older-than 7d
    ${config.nix.package}/bin/nix store optimise
  '';
in {
  environment = {
    etc = {darwin.source = "${inputs.darwin}";};
    # packages installed in system profile (more in ../common.nix)
    # systemPackages = [ ];
  };

  # auto manage nixbld users with nix darwin
  nix = {
    configureBuildUsers = true;
    nixPath = ["darwin=/etc/${config.environment.etc.darwin.target}"];

    # Additional garbage collection triggers
    extraOptions = ''
      accept-flake-config = true
      extra-platforms = x86_64-darwin aarch64-darwin
      min-free = ${toString (10 * 1024 * 1024 * 1024)}  # 10 GB
      max-free = ${toString (20 * 1024 * 1024 * 1024)}  # 20 GB
    '';

    # Optimize the store
    optimise.automatic = true;

    # Define builders
    linux-builder = {
      enable = true;
      ephemeral = true;
      maxJobs = 4;
      config = {
        virtualisation = {
          darwin-builder = {
            diskSize = 200 * 1024;
            memorySize = 8 * 1024;
          };
          cores = 6;
        };

        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = true;
            PermitRootLogin = "yes";
          };
        };

        users.users.root.password = "root";
      };
    };
  };

  launchd.user.agents.nix-gc = {
    serviceConfig = {
      ProgramArguments = ["${gcScript}"];
      KeepAlive = false;
      RunAtLoad = false;
      StartInterval = 43200; # 12 hours in seconds
    };
  };

  nixpkgs.config = {
    allowBroken = true;
    allowUnfree = true;
    checkAllPackages = false;
  };

  # nixpkgs.overlays = [
  #   (self: super: {
  #     # Disable checks for all packages
  #     all = super.all.overrideAttrs (oldAttrs: {
  #       doCheck = false;
  #       doInstallCheck = false;
  #     });
  #   })
  # ];

  launchd.user.envVariables = {
    XDG_RUNTIME_DIR = "${config.user.home}/.xdg";
  };

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
}
