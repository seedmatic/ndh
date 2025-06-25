{
  description = "nix system configurations for bioskop";

  inputs = {
    nxmatic-darwin-home.url = "path:../..";
  };

  outputs = { self, nxmatic-darwin-home, ... }@inputs:
    let
      inherit (nxmatic-darwin-home) devShells packages overlays mkDarwinConfig;

      system = "aarch64-darwin";

      # Define a new module for the host
      hostModule = { config, lib, pkgs, ... }: {
        imports = [ ../../modules/home-manager/profiles/committed.nix ];
        
        # host-specific configurations
        config = {
          profile = {
            host.name = "bioskop";
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
        imports = [ ../../modules/home-manager/profiles/committed.nix ];
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
      inherit darwinConfiguration devShells packages overlays;

      darwinConfigurations = {
        "bootstrap" = darwinBootstrapConfiguration;
        "bioskop" = darwinConfiguration;
      };

      defaultPackage.aarch64-darwin = darwinConfiguration.system;
    };
}
