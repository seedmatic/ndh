{
  description = "Bootstrap configuration for alcide - Stage 1: Linux builder only";

  inputs = { nix-darwin-home.url = "path:../../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "APL-dk40njhk9h";
        hostAlias = "alcide";
        tailnet = { };
      };

      # Inline bootstrap configuration
      profileModule = { lib, config, pkgs, ... }: {
        imports = [
          ../../../modules/common  # Needed for profile.name
        ];
        
        config = {
          # Minimal profile configuration (required by linux-builder module)
          profile = {
            name = "work";
            email = "stephane.lacoin@gmail.com";
            user = {
              name = "stephane.lacoin";
              home = "/Users/stephane.lacoin";
              description = "Stéphane Lacoin";
            };
            host = {
              hostName = "APL-dk40njhk9h";
              hostAlias = "alcide";
              tailnet = { }; # Empty for bootstrap - not needed yet
            };
            darwin = {
              knownNetworkServices = [ "Wi-Fi" "Thunderbolt Ethernet" ];
            };
          };
          
          # Minimal system info
          networking.hostName = "APL-dk40njhk9h";
          networking.computerName = "alcide";
          
          # Minimal packages - nothing that requires Linux builds
          environment.systemPackages = lib.mkForce (with pkgs; [
            bash
            git
            direnv
          ]);
          
          # Configure SSL certificates for JAMF-managed system
          nix.settings.ssl-cert-file = "/etc/ssl/cert.pem";
          
          # ENABLE Linux builder - this is the whole point of stage 1
          # This will populate /etc/nix/machines and start the VM
          nix.linux-builder.enable = true;
          
          # Disable everything else that might need Linux builds during evaluation
          services.crossHostBuilders.enable = lib.mkForce false;
          
          # Don't configure Lima yet - that comes in stage 2
        };
      };
    in nix-darwin-home.mkHostOutputs { inherit hostProfile profileModule; };
}
