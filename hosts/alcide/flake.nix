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

      profileModule = { lib, config, pkgs, ... }: {
        imports = [ 
          ../../profiles/work-minimal.nix
          # Teleport removed - using Tailscale for external access
        ];
        config = {
          profile = {
            host = {
              hostName = lib.mkDefault hostProfile.hostName;
              hostAlias = lib.mkDefault hostProfile.hostAlias;
              tailnet = hostProfile.tailnet;
            };
            darwin = darwinProfile;
          };
          
          # Minimal macOS host configuration for JAMF-managed system
          # Most development work happens in Lima NixOS VM
          
          # Override system packages with minimal set
          environment.systemPackages = lib.mkForce (import ../../modules/common/system-packages-minimal.nix { inherit pkgs; });
          
          # Configure SSL certificates for JAMF-managed system
          nix.settings.ssl-cert-file = "/etc/ssl/cert.pem";
          
          # Disable cross-host distributed builds during bootstrap
          # The local Linux builder will still work, but remote builders via SSH won't
          # Enable this after both hosts are set up with Tailscale mesh networking
          services.crossHostBuilders.enable = false;
          
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
    in nix-darwin-home.mkHostOutputs { inherit hostProfile profileModule; };
}
