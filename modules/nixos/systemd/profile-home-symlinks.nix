# Profile home directory symlinks (@codebase)
# This module creates symlinks between different profile user home directories for convenience
# when the Darwin host home folder is mounted in the NixOS guest

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  homeSymlinksRaw = config.profile.homeSymlinks or [ ];
  homeSymlinks = lib.filter (u: u != cfgUserName) (lib.unique homeSymlinksRaw);
  currentHome = builtins.toString cfgUser.home; # dynamic rather than hard-coded /home/<user>
  currentHomeBase = builtins.dirOf currentHome; # usually /home
in
{
  config = lib.mkIf (homeSymlinks != [ ]) {
    # Create symlink for profile convenience
    systemd.services.lima-home-symlink = {
      description = "Create home directory symlink for profile convenience";
      wantedBy = [ "multi-user.target" ];
      after = [
        "local-fs.target"
        "lima-cloud-init.service"
      ];
      requires = [ "lima-cloud-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        let
          # Executable helper to create a single symlink safely
          createScript = pkgs.writeShellScript "create-profile-symlink.sh" (
            builtins.readFile (pkgs.replaceVars ./profile-home-symlinks.d/create-profile-symlink.sh { })
          );

          symlinkScriptTemplate = pkgs.replaceVars ./profile-home-symlinks.d/run.sh {
            currentHome = lib.escapeShellArg currentHome;
            currentHomeBase = lib.escapeShellArg currentHomeBase;
            cfgUserName = lib.escapeShellArg cfgUserName;
            createScript = lib.escapeShellArg createScript;
            homeAliases = lib.concatMapStringsSep " " lib.escapeShellArg homeSymlinks;
          };

          # Main script: handle aliases (if any) on Linux (/home) and Darwin (/Users)
          symlinkScript = pkgs.writeShellScript "lima-home-symlinks.sh" (
            builtins.readFile symlinkScriptTemplate
          );
        in
        builtins.readFile symlinkScript;
      };
    };
  };
}
