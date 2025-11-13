{
  description = "nix system configurations for bioskop";

  inputs = { nix-darwin-home.url = "path:../.."; };

  outputs = { self, nix-darwin-home, ... }@inputs:
    let
      hostProfile = {
        hostName = "bioskop";
        tailnet = { };
      };
      darwinProfile = {
        knownNetworkServices = [ "Wi-Fi" "Ethernet Adaptor" "Thunderbolt Ethernet" ];
      };

      profileModule = { pkgs, lib, config, ... }: {
        imports = [ 
          ../../profiles/committed.nix
          # Teleport removed - using Headscale for internal network
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

          # Headscale client - connects to server in Lima VM
          # Note: Server must be deployed first at 192.168.5.10:8080
          services.headscale-client = {
            enable = true;
            serverUrl = "http://192.168.5.10:8080";
            enableSSH = true;
          };
          
          # Enable cross-host distributed builds (Darwin only)
          services.crossHostBuilders.enable = true;
        };
      };
      
      # Darwin-specific module for network bonding and monitoring
      darwinModule = { config, lib, ... }: {
        config = {
          # Network bonding configuration (Darwin only)
          # Combines en0 (built-in) and en8 (OWC hub) for ~1.8 Gbps aggregate bandwidth
          networking.bond = {
            enable = false; # Enable when needed
            interfaces = [ "en0" "en8" ];
            mode = "static"; # Static LAG without LACP protocol
          };

          # Network monitoring service - manages route priorities
          # Automatically runs in "individual" mode since bond.enable = false
          networking.monitor = {
            enable = true;
            primaryInterface = "en0";      # Built-in Ethernet (highest priority)
            backupInterface = "en1";       # Wi-Fi (medium priority backup)
            secondaryInterfaces = ["en8"]; # USB Ethernet (lower priority)
            checkInterval = 30;            # Check every 30 seconds
            routeMetrics = {
              primary = 100;    # en0 gets highest priority (lowest metric)
              backup = 200;     # en1 gets medium priority  
              secondary = 300;  # en8 gets lowest priority (highest metric)
            };
          };
        };
      };
    in nix-darwin-home.mkHostOutputs { 
      inherit hostProfile profileModule; 
      darwinExtraModules = [ darwinModule ];
    };
}
