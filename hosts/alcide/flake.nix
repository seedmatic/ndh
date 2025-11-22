{
  description = "nix system configurations for alcide";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "APL-dk40njhk9h";
        hostAlias = "alcide";
        tailnet = { };
      };
      darwinProfile = {
        knownNetworkServices = [ "Wi-Fi" "Thunderbolt Ethernet" ];
      };

      profileModule = { pkgs, lib, config, ... }: {
        imports = [ 
          ../../profiles/work.nix
        ];
        config = {
          profile = {
            host = {
              hostName = lib.mkDefault hostProfile.hostName;
              tailnet = hostProfile.tailnet;
            } // (if hostProfile ? hostAlias then {
              hostAlias = lib.mkDefault hostProfile.hostAlias;
            } else {});
            darwin = darwinProfile;
          };
        };
      };
      
      # Darwin-specific module for Lima and macOS host configuration
      darwinModule = { config, lib, pkgs, ... }: {
        config = {
          # Minimal macOS host configuration for JAMF-managed system
          # Most development work happens in Lima NixOS VM
          
          # Use consolidated system packages (already minimal)
          environment.systemPackages = lib.mkForce (import ../../modules/common/system-packages.nix { inherit pkgs; });
          
          # Configure SSL certificates for JAMF-managed system
          nix.settings.ssl-cert-file = "/etc/ssl/cert.pem";
          
          # Configure .lan domain resolution using home LAN DNS server
          networking.lanDnsResolver = {
            enable = true;
            nameserver = "192.168.1.254";
          };
          
          # Lima VM configuration - this is where the real work happens
          lima = {
            configGenerator = {
              vmType = "vz";
              enableIncus = true;  # Enable Incus in VM for container workloads
            };
          };
          
          # Disable heavy services on host (move to VM)
          # Keep only essential networking and VM management
        };
      };
    in nix-darwin-home.mkHostOutputs { 
      inherit hostProfile profileModule; 
      darwinExtraModules = [ darwinModule ];
    };
}
