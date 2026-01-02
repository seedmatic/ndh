{ config, lib, ... }:
let
  user = config.profile.user;
  userName = user.name;
  homeDir = toString user.home; # already resolved by profile logic
  # Fallback group: if user.group null, assume same as userName
  group = if (user.group or null) == null then userName else user.group;
  dirs = [
    "${homeDir}/.local"
    "${homeDir}/.local/state"
    "${homeDir}/.local/state/nix"
    "${homeDir}/.local/state/nix/profiles"
    "${homeDir}/.local/state/home-manager"
    "${homeDir}/.local/state/home-manager/gcroots"
  ];
in
{
  # Use tmpfiles to ensure directory tree exists with correct ownership/mode
  systemd.tmpfiles.rules = map (d: "d ${d} 0755 ${userName} ${group} -") dirs;

  # Extra activation script (idempotent) to guard against any race where tmpfiles runs late
  system.activationScripts.hmStateDirs = {
    deps = [ ];
    text = ''
      for d in ${builtins.concatStringsSep " " dirs}; do
        if [ ! -d "$d" ]; then
          install -d -m 0755 -o ${userName} -g ${group} "$d"
        fi
      done
    '';
  };
}
