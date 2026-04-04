{
  config,
  pkgs,
  lib,
  ...
}:
{
  programs.ssh = {
    enable = true;
    includes = [ "config.d/*" ];

    # Explicitly disable the built-in defaults to avoid future schema removals
    enableDefaultConfig = false;

    matchBlocks = {
      "*" = {
        forwardAgent = true;
        addKeysToAgent = "no";
        controlMaster = "auto";
        controlPersist = "yes";
        controlPath = "${config.home.homeDirectory}/.ssh/master-%C";
      };

      # GPG agent forwarding for Lima VMs
      # Forward Darwin's GPG agent to the NixOS VM
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

  home.activation.cleanupLegacyLimaSshConfig = lib.mkIf (!pkgs.stdenvNoCC.isDarwin) (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      rm -f "${config.home.homeDirectory}/.ssh/config.d/lima.conf"
    ''
  );

  home.activation.cleanupLegacyLimaRuntimeOverrides = lib.mkIf pkgs.stdenvNoCC.isDarwin (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      cfg_dir="${config.home.homeDirectory}/.ssh/config.d"
      if [ -d "$cfg_dir" ]; then
        for f in "$cfg_dir"/01-*-runtime.conf; do
          [ -e "$f" ] || continue
          if grep -qE 'UserKnownHostsFile\s+.*/\.lima/_config/known_hosts' "$f" 2>/dev/null; then
            rm -f "$f"
          fi
        done
      fi
    ''
  );
}
