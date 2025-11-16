{
  description = "Bootstrap configuration for alcide - Stage 1: Minimal nix-darwin without linux-builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-25.05-darwin";
    darwin = {
      url = "github:LnL7/nix-darwin/nix-darwin-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, darwin, ... }:
    let
      system = "aarch64-darwin";
    in {
      darwinConfigurations."APL-dk40njhk9h" = darwin.lib.darwinSystem {
        inherit system;
        
        modules = [
          # Minimal inline configuration - use standard nix-darwin linux-builder
          ({ lib, pkgs, config, ... }: {
            # Define profile.name option that linux-builder requires
            options.profile.name = lib.mkOption {
              type = lib.types.str;
              default = "work";
            };
            
            config = {
              # Set profile name to "work" (matches keys.yaml)
              profile.name = "work";
              
              # State version for nix-darwin
              system.stateVersion = 6;
              
              # Basic system info
              networking.hostName = "APL-dk40njhk9h";
              networking.computerName = "alcide";
              
              # Minimal packages - only Darwin-native builds
              environment.systemPackages = with pkgs; [
                bash
                git
              ];
              
              # SSL certificates for JAMF
              nix.settings.ssl-cert-file = "/etc/ssl/cert.pem";
              
              # Enable experimental features (should already be in /etc/nix/nix.conf)
              nix.settings.experimental-features = [ "nix-command" "flakes" ];
              
              # Trusted users prerequisite for linux-builder
              nix.settings.trusted-users = [ "@admin" ];
              
              # Enable default nix-darwin linux-builder
              nix.linux-builder.enable = true;
            };
          })
        ];
      };
    };
}
