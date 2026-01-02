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
          createScript = "${pkgs.replaceVars ./profile-home-symlinks.d/create-profile-symlink.sh { }}";

          homeAliasCmds = lib.concatMapStringsSep "\n" (
            alias: ''${createScript} "${currentHome}" "${currentHomeBase}/${alias}"''
          ) homeSymlinks;

          usersAliasCmds = ''
            if [ -d /Users ]; then
              if [ ! -e "/Users/${cfgUserName}" ]; then
                ${createScript} "${currentHome}" "/Users/${cfgUserName}"
              fi
              ${lib.concatMapStringsSep "\n" (
                alias: ''${createScript} "${currentHome}" "/Users/${alias}"''
              ) homeSymlinks}
            fi
          '';
        in
        builtins.readFile (
          pkgs.replaceVars ./profile-home-symlinks.d/service.sh {
            cfgUserName = cfgUserName;
            currentHome = currentHome;
            homeAliasCmds = homeAliasCmds;
            usersAliasCmds = usersAliasCmds;
          }
        );
    };
  };
}
