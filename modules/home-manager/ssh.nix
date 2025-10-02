{ config, pkgs, ... }: {
  programs.ssh = {
    enable = true;
    includes = [ "config.d/*" ];
    forwardAgent = true;
    addKeysToAgent = "no";
    controlMaster = "auto";
    controlPersist = "yes";
    controlPath = "${config.home.homeDirectory}/.ssh/master-%C";
    
    # GPG agent forwarding for Lima VMs
    # Forward Darwin's GPG agent to the NixOS VM
    matchBlocks = {
      "lima-*" = {
        extraOptions = {
          # Forward GPG agent socket from Darwin to Lima VM
          # IMPORTANT: Must use absolute paths for Unix domain socket forwarding
          # Forward the MAIN agent socket (not .extra) for full key access
          # Remote path: /home/nxmatic/.local/share/gnupg/S.gpg-agent (on NixOS VM)
          # Local path: Darwin main agent socket (not .extra)
          RemoteForward = "/home/${config.home.username}/.local/share/gnupg/S.gpg-agent ${config.xdg.dataHome}/gnupg/S.gpg-agent";
          # Allow the remote socket to be unlinked if it already exists
          StreamLocalBindUnlink = "yes";
          # Allow remote forwarding (required for Unix domain socket forwarding)
          GatewayPorts = "yes";
        };
      };
    };
  };
}
