{
  description = "nix system configurations for alcide";

  inputs = {
    nxmatic-darwin-home.url = "path:../..";
  };

  outputs = { self, nxmatic-darwin-home, ... }@inputs:
    let
      inherit (nxmatic-darwin-home) devShells packages overlays mkDarwinConfig;

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

      # Use mkDarwinConfig to create the configuration
      darwinConfiguration = mkDarwinConfig {
        profileModule = hostModule;
        inherit system;
      };
    in {
      inherit darwinConfiguration devShells packages overlays;

      darwinConfigurations.bioskop = darwinConfiguration;
    };
}
