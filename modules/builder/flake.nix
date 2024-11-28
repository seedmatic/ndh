{
  description = "NixOS builder with SSH enabled";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
    ];

    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
  };

  inputs = {
    darwin-home.url = "../..";

    nixpkgs.follow = "darwin-home/nixpkgs";
  };

  outputs = { darwin-home, nixpkgs }: {
    nixosConfigurations.your-hostname = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ({pkgs, ...}: {
          # Enable SSH
          services.openssh = {
            enable = true;
          };

          # Configure build users
          nix = {
            settings = {
              trusted-users = ["root" "@wheel"];
              auto-optimise-store = true;
            };
            extraOptions = ''
              experimental-features = nix-command flakes
            '';
          };

          # Enable distributed builds
          nix.distributedBuilds = true;
          nix.buildMachines = [
            {
              hostName = "localhost";
              systems = ["x86_64-linux" "i686-linux"];
              maxJobs = 1;
              speedFactor = 2;
              supportedFeatures = ["kvm" "nixos-test" "big-parallel" "benchmark"];
            }
          ];

          system.stateVersion = darwin-home.homeConfigurations.work.config.home.stateVersion;

          # Add any other configuration you need
          environment.systemPackages = with pkgs; [
            vim
            git
          ];
        })
      ];
    };
  };
}
