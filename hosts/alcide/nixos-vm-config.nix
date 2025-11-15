# NixOS configuration for alcide Lima VM
# This VM hosts all development tools and applications
# The macOS host (alcide) is minimal and JAMF-managed
#
# Architecture:
# - macOS host (alcide): Minimal nix, Lima, SSH, basic shell tools
# - Lima NixOS VM: All development tools, containers, services
# - Incus cluster (in VM): Application workloads

{ config, pkgs, lib, ... }:

{
  imports = [
    # Base NixOS modules from nix-darwin-home
    # Adjust paths if needed based on how this config is loaded
  ];

  # === System Configuration ===
  networking = {
    hostName = "alcide-nixos";
    firewall = {
      enable = true;
      # Trust Incus bridge for container communication
      trustedInterfaces = [ "incusbr0" "lan-br" ];
      # Open ports as needed for development
      allowedTCPPorts = [
        22    # SSH
        3000  # Common dev server port
        8080  # Common dev server port
      ];
    };
  };

  # === User Configuration ===
  # Ensure your user has access to all necessary groups
  users.users.nxmatic = {  # Match your username from work profile
    isNormalUser = true;
    extraGroups = [ 
      "wheel"        # sudo access
      "incus-admin"  # Incus container management
      "docker"       # Docker/Podman (if needed)
    ];
  };

  # === Development Packages ===
  # All the tools moved from macOS host
  environment.systemPackages = with pkgs; [
    # Core development tools
    git
    gitflow
    gh  # GitHub CLI
    
    # Editors
    emacs-nox
    vim
    
    # Shell and utilities
    bash
    zsh
    coreutils-full
    direnv
    flox
    
    # Build tools
    remake
    gnumake
    gcc
    
    # Container and orchestration tools
    kubectl
    k9s
    helm
    incus
    incus-compose
    docker-compose
    podman
    buildah
    skopeo
    
    # Development utilities
    ripgrep
    ripvcs
    fd
    fzf
    jq
    yq-go
    
    # Security and secrets
    sops
    ssh-to-age
    gnupg
    
    # Monitoring and debugging
    htop
    iotop
    tcpdump
    wireshark
    lsof
    strace
    
    # Network tools
    curl
    wget
    netcat
    nmap
    
    # Python environment (if needed)
    python3
    python3Packages.pip
    
    # Node.js environment (if needed)
    nodejs
    
    # Language servers (for IDE support)
    nixd
    
    # Additional fonts
    powerline-fonts
    powerline-go
    powerline-symbols
  ];

  # === Incus Configuration ===
  virtualisation.incus = {
    enable = true;
    ui.enable = true;
  };

  # === Networking for Containers ===
  # Enable IP forwarding for container networking
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  # === Services ===
  
  # Enable SSH for host access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };
  
  # Tailscale/Headscale for networking
  services.tailscale.enable = true;
  
  # Optional: Enable Emacs daemon for remote editing
  # Access from macOS: emacsclient -t via SSH
  # systemd.user.services.emacs = {
  #   enable = true;
  #   description = "Emacs text editor daemon";
  #   serviceConfig = {
  #     Type = "forking";
  #     ExecStart = "${pkgs.emacs-nox}/bin/emacs --daemon";
  #     ExecStop = "${pkgs.emacs-nox}/bin/emacsclient --eval '(kill-emacs)'";
  #     Restart = "on-failure";
  #   };
  #   wantedBy = [ "default.target" ];
  # };

  # === Nix Configuration ===
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
    # Use same caches as Darwin host
    substituters = [
      "https://cache.nixos.org"
      "https://nxmatic.cachix.org"
      "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nxmatic.cachix.org-1:oWogvXdam3gTxKzPZCDqq8khybQpqRdNpQQrKG3r4xM="
    ];
  };

  # === System State ===
  system.stateVersion = "24.05";
}
