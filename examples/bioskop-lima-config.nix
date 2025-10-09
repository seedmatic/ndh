# Example NixOS configuration for bioskop Lima VM
# Location: ~/.lima/bioskop-nixos/nixos-config.nix (or similar)
#
# This configuration deploys:
# - Headscale server (Incus container)
# - Headscale gateway (Incus container - Tailscale bridge)
# - Headscale client on Lima VM itself

{ config, pkgs, lib, ... }:

{
  imports = [
    # Import Headscale modules from nix-darwin-home
    # Adjust paths based on your setup
  ];

  # === Headscale Server Configuration ===
  services.incus-headscale-server = {
    enable = true;
    instanceName = "headscale-server";
    serverUrl = "http://192.168.5.10:8080";
    baseDomain = "home.local";
    listenAddr = "0.0.0.0:8080";
    ipAddress = "192.168.5.10";  # Static IP for easy access
    profile = "default";
  };

  # === Headscale Gateway Configuration ===
  # Bridges Tailscale network to Headscale network
  services.incus-headscale-gateway = {
    enable = true;
    instanceName = "headscale-gateway";
    hostname = "bioskop-hs-gateway";
    
    # Path to Tailscale auth key (create this file manually)
    # Get auth key from: https://login.tailscale.com/admin/settings/keys
    tailscaleAuthKeyFile = "/run/secrets/tailscale-authkey";
    
    # Routes to advertise to Tailscale network
    advertiseRoutes = [
      "100.64.0.0/10"     # Headscale mesh network
      "192.168.1.0/24"    # Home LAN (adjust to your network)
      "192.168.5.0/24"    # Lima shared network
      "10.80.16.0/20"     # bioskop RKE2 cluster subnet
    ];
    
    tags = [ "gateway" "bioskop" ];
    profile = "default";
  };

  # === Lima VM as Headscale Client ===
  services.headscale-client = {
    enable = true;
    serverUrl = "http://192.168.5.10:8080";
    enableSSH = true;
    
    # Get auth key from Headscale server:
    # incus exec headscale-server -- headscale preauthkeys create --user <username> --reusable
    authKeyFile = "/run/secrets/headscale-authkey";
  };

  # === Incus Configuration ===
  virtualisation.incus = {
    enable = true;
    
    # Optional: Configure Incus networking
    # If you need custom network setup for containers
  };

  # === Networking ===
  networking = {
    hostName = "bioskop-nixos";
    
    firewall = {
      enable = true;
      
      # Trust Incus bridge
      trustedInterfaces = [ "incusbr0" ];
      
      # Open ports for Headscale server access from Darwin host
      allowedTCPPorts = [
        # 8080  # If you want to access Headscale directly (not recommended, use via container)
      ];
    };
    
    # Optional: Custom DNS servers
    nameservers = [ "1.1.1.1" "1.0.0.1" ];
  };

  # === System Packages ===
  environment.systemPackages = with pkgs; [
    # Headscale management tools are automatically included by the modules
    # Additional useful tools:
    incus
    tailscale
    curl
    jq
    htop
    vim
  ];

  # === System Configuration ===
  system.stateVersion = "24.05";
  
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
  };

  # === User Configuration ===
  # Ensure your user has access to Incus
  users.users.nxmatic = {  # Replace with your username
    isNormalUser = true;
    extraGroups = [ "wheel" "incus-admin" ];
  };
}

# === Deployment Steps ===
# 
# 1. Save Tailscale auth key:
#    sudo mkdir -p /run/secrets
#    echo "tskey-auth-..." | sudo tee /run/secrets/tailscale-authkey
#    sudo chmod 600 /run/secrets/tailscale-authkey
#
# 2. Deploy Headscale server:
#    sudo deploy-headscale-server
#
# 3. Create Headscale user and auth key:
#    sudo headscale-create-user bioskop-admin
#    sudo headscale-create-authkey bioskop-admin --reusable --expiration 720h
#
# 4. Save Headscale auth key:
#    echo "tskey-auth-..." | sudo tee /run/secrets/headscale-authkey
#    sudo chmod 600 /run/secrets/headscale-authkey
#
# 5. Deploy Headscale gateway:
#    sudo deploy-headscale-gateway
#
# 6. Approve routes in Tailscale admin console:
#    https://login.tailscale.com/admin/machines
#    Find "bioskop-hs-gateway" and approve all routes
#
# 7. Verify:
#    sudo headscale-server-status
#    sudo headscale-gateway-status
#    sudo tailscale status
