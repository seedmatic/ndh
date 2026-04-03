# Example NixOS configuration for bioskop Lima VM
# Location: ~/.lima/bioskop-nixos/nixos-config.nix (or similar)
#
# This configuration keeps only VM-local client wiring.
# Headscale/Tailscale control-plane and gateway roles are cluster-owned in rke2lab.

{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    # Import Headscale modules from nix-darwin-home
    # Adjust paths based on your setup
  ];

  # === Lima VM as Headscale Client ===
  services.headscale = {
    enable = true;
    serverUrl = "http://192.168.5.10:8080";
    enableSSH = true;

    # Get auth key from Headscale server:
    # incus exec headscale-server -- headscale preauthkeys create --user <username> --reusable
    authKeyFile = "/run/secrets/headscale-authkey";
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
    nameservers = [
      "1.1.1.1"
      "1.0.0.1"
    ];
  };

  # === System Packages ===
  environment.systemPackages = with pkgs; [
    # Additional useful tools:
    curl
    jq
    htop
    vim
  ];

  # === System Configuration ===
  system.stateVersion = "24.05";

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];
  };

  # === User Configuration ===
  # Ensure your user has access to Incus
  users.users.nxmatic = {
    # Replace with your username
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "incus-admin"
    ];
  };
}

# === Deployment Steps ===
#
# 1. Save Headscale auth key:
#    echo "tskey-auth-..." | sudo tee /run/secrets/headscale-authkey
#    sudo chmod 600 /run/secrets/headscale-authkey
#
# 2. Verify client registration:
#    sudo tailscale status
