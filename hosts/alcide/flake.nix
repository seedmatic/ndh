{
  description = "nix system configurations for alcide";

  inputs = { nxmatic-darwin-home.url = "path:../.."; };

  outputs = { self, nxmatic-darwin-home, ... }@inputs:
    let
      inherit (nxmatic-darwin-home) homeManagerModules devShells packages overlays mkDarwinConfig;

      system = "aarch64-darwin";

      # Define a new module for the host
      hostModule = { config, lib, pkgs, ... }: {
        imports = [ ../../modules/home-manager/profiles/work.nix ];

        # host-specific configurations
        config = {
          profile = {
            host.name = "alcide";
            # Add other alcide-specific configurations here
          };

          # You can add more alcide-specific configurations here
          # For example:
          # programs.git.enable = true;
          # home.packages = with pkgs; [ htop neofetch ];
        };
      };

      # Define a bootstrap host module
      bootstrapHostModule = { config, lib, pkgs, ... }: {
        imports = [ ../../modules/home-manager/profiles/work.nix ];
        config = {
          profile = { host.name = "alcide"; };
          linux-builder.useCustomConfig = false;
        };
      };

      # Use mkDarwinConfig to create the configuration
      darwinConfiguration = mkDarwinConfig {
        profileModule = hostModule;
        inherit system;
      };

      # Use mkDarwinConfig to create the bootstrap configuration
      darwinBootstrapConfiguration = mkDarwinConfig {
        profileModule = bootstrapHostModule;
        inherit system;
      };
    in {
      inherit darwinConfiguration homeManagerModules devShells packages overlays;

      darwinConfigurations = {
        "bootstrap" = darwinBootstrapConfiguration;
        "APL-dk40njhk9h" = darwinConfiguration;
      };

      defaultPackage.aarch64-darwin = darwinConfiguration.system;
    };
}
