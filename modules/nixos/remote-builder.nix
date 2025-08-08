# NixOS remote builder configuration for Lima VM (@codebase)
# This module configures the Lima NixOS VM to act as a remote builder
# accessible from Tailscale hosts

{ config, lib, pkgs, ... }:

{
  # Configure the builder user for remote builds
  users.users.builder = {
    isNormalUser = true;
    group = "builder";
    extraGroups = [ "wheel" "nixbld" ];
    description = "Nix remote builder user";
    openssh.authorizedKeys.keyFiles = [
      ../../keys/builder_ed25519.pub
    ];
  };

  users.groups.builder = {};

  # Configure Nix for remote building
  nix.settings = {
    # Allow the builder user to perform builds
    trusted-users = [ "builder" "root" ];
    
    # Optimize for remote builds
    max-jobs = 6;
    cores = 0;  # Use all available cores
    
    # Performance optimizations for transfers
    connect-timeout = 20;
    stalled-download-timeout = 300;
    download-attempts = 3;
    
    # Enable compression for faster transfers
    compress-build-log = true;
    
    # Enable features needed for builds
    system-features = [ "kvm" "nixos-test" "benchmark" "big-parallel" ];
  };

  # Enable SSH daemon with proper configuration
  services.openssh = {
    enable = true;
    settings = {
      # Allow the builder user to connect
      AllowUsers = [ "builder" config.profile.user.name ];
      AllowGroups = [ "builder" "wheel" "ssh" ];
      
      # Security settings
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      PubkeyAuthentication = true;
      
      # Performance settings for builds
      Compression = true;
      TCPKeepAlive = true;
      ClientAliveInterval = 60;
      ClientAliveCountMax = 10;
      
      # Optimize for large file transfers (build artifacts)
      MaxSessions = 20;
      MaxStartups = "20:30:100";
      # Enable faster cipher for local network transfers
      Ciphers = "chacha20-poly1305@openssh.com,aes128-gcm@openssh.com,aes256-gcm@openssh.com";
    };
    
    # Authorized keys configuration
    authorizedKeysFiles = [
      "/etc/ssh/authorized_keys.d/%u_ed25519.pub"
      "%h/.ssh/authorized_keys"
    ];
  };

  # Configure sudo for the builder user
  security.sudo.extraRules = [
    {
      users = [ "builder" ];
      commands = [
        {
          command = "${pkgs.nix}/bin/nix-store";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${pkgs.nix}/bin/nix-daemon";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  # Open firewall for SSH (port 22)
  networking.firewall = {
    allowedTCPPorts = [ 22 ];
    trustedInterfaces = [ "tailscale0" ];
  };

  # Install builder keys in authorized_keys directory
  environment.etc."ssh/authorized_keys.d/builder_ed25519.pub".source = 
    ../../keys/builder_ed25519.pub;

  # Ensure the nixbld group exists and builder user is part of it
  users.groups.nixbld.members = [ "builder" ];

  # Additional packages needed for builds
  environment.systemPackages = with pkgs; [
    git          # Often needed for builds
    curl         # For fetchers
    unzip        # For archives
    rsync        # For file transfers
    openssh      # For SSH operations
  ];

  # Performance tuning for builds
  boot.kernel.sysctl = {
    # Increase file descriptor limits
    "fs.file-max" = 1048576;
    # Improve network performance for large transfers
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.core.rmem_default" = 262144;
    "net.core.wmem_default" = 262144;
    # TCP optimizations for bulk transfers
    "net.ipv4.tcp_window_scaling" = 1;
    "net.ipv4.tcp_timestamps" = 1;
    "net.ipv4.tcp_sack" = 1;
    # Reduce TCP congestion control for local transfers
    "net.ipv4.tcp_congestion_control" = "bbr";
  };
}
