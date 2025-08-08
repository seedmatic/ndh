# Profile home directory symlinks (@codebase)
# This module creates symlinks between different profile user home directories for convenience
# when the Darwin host home folder is mounted in the NixOS guest

{ config, lib, pkgs, ... }:

let
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  homeSymlinks = config.profile.homeSymlinks or [];
in
{
  config = lib.mkIf (homeSymlinks != []) {
    # Create symlink for profile convenience
    systemd.services.lima-home-symlink = {
      description = "Create home directory symlink for profile convenience";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "lima-cloud-init.service" ];
      requires = [ "lima-cloud-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        currentHome = "/home/${cfgUserName}";
        
        # Create a bash function for symlink creation
        script = pkgs.writeShellScript "create-profile-symlink" ''
          set -exuo pipefail
          
          current_home="$1"
          target_symlink="$2"
          
          create_symlink() {
            local current_home="$1"
            local target_symlink="$2"
            
            # Check if current user's home exists
            if [[ ! -d "$current_home" ]]; then
              : Warning: Current home directory '$current_home' does not exist, skipping symlink creation
              return 0
            fi
            
            # If target doesn't exist or is a symlink, we can safely create/update it
            if [[ ! -e "$target_symlink" ]] || [[ -L "$target_symlink" ]]; then
              ${pkgs.coreutils}/bin/ln -sf "$current_home" "$target_symlink"
            else
              : Warning: '$target_symlink' exists and is not a symlink, skipping symlink creation
            fi
          }
          
          create_symlink "$current_home" "$target_symlink"
        '';
        
        # Generate commands for each symlink
        symlinkCommands = lib.concatMapStringsSep "\n" (symlinkName: 
          ''${script} "${currentHome}" "/home/${symlinkName}"''
        ) homeSymlinks;
        
      in ''
        ${symlinkCommands}
      '';
    };
  };
}
