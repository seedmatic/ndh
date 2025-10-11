# Profile home directory symlinks (@codebase)
# This module creates symlinks between different profile user home directories for convenience
# when the Darwin host home folder is mounted in the NixOS guest

{ config, lib, pkgs, ... }:

let
  cfgUser = config.profile.user;
  cfgUserName = cfgUser.name;
  homeSymlinksRaw = config.profile.homeSymlinks or [];
  homeSymlinks = lib.filter (u: u != cfgUserName) (lib.unique homeSymlinksRaw);
  currentHome = builtins.toString cfgUser.home; # dynamic rather than hard-coded /home/<user>
  currentHomeBase = builtins.dirOf currentHome; # usually /home
in {
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
        # Write helper script used for each symlink creation target
        createScript = pkgs.writeShellScript "create-profile-symlink" ''
          set -euo pipefail
          target_home="$1"    # real directory we want to point to
          link_path="$2"      # symlink we want to create/update

          # Validate target home exists
          if [ ! -d "$target_home" ]; then
            echo "[profile-home-symlinks] target '$target_home' not present, skip $link_path" >&2
            exit 0
          fi
          # Disallow nesting symlink inside target (avoid loops)
          case "$link_path" in
            "$target_home"/*)
              echo "[profile-home-symlinks] skip $link_path (would reside inside target)" >&2
              exit 0 ;;
          esac
          # If link path exists and is not a symlink, leave it alone
          if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
            echo "[profile-home-symlinks] $link_path exists (not symlink), skipping" >&2
            exit 0
          fi
          mkdir -p "$(dirname "$link_path")"
          ln -snf "$target_home" "$link_path"
          echo "[profile-home-symlinks] $link_path -> $target_home"
        '';

        # Build command list for /home aliases
        homeAliasCmds = lib.concatMapStringsSep "\n" (alias: ''${createScript} "${currentHome}" "${currentHomeBase}/${alias}"'') homeSymlinks;

        # Build command list for /Users aliases (only if /Users exists)
        usersAliasCmds = ''
          if [ -d /Users ]; then
            # Ensure primary user also linked if real dir not present (optional convenience)
            if [ ! -e "/Users/${cfgUserName}" ]; then
              ${createScript} "${currentHome}" "/Users/${cfgUserName}"
            fi
            ${lib.concatMapStringsSep "\n" (alias: ''${createScript} "${currentHome}" "/Users/${alias}"'') homeSymlinks}
          fi
        '';
      in ''
        echo "[profile-home-symlinks] current user: ${cfgUserName} home: ${currentHome}"
        ${homeAliasCmds}
        ${usersAliasCmds}
      '';
    };
  };
}
