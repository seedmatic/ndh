{
  config,
  lib,
  pkgs,
  ...
}:
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
  # Use the wrapped activation logger placed in the store so it's always available
  logger = config.activation.loggerScript;
  activationTag = "nixos.activationScripts.hmStateDirs";
in
{
  # Use tmpfiles to ensure directory tree exists with correct ownership/mode
  systemd.tmpfiles.rules = map (d: "d ${d} 0755 ${userName} ${group} -") dirs;

  # Extra activation script (idempotent) to guard against any race where tmpfiles runs late
  system.activationScripts.hmStateDirs = {
    deps = [ ];
    text = builtins.readFile (
      pkgs.replaceVars ./hm-state-dirs.d/ensure-dirs.sh {
        dirs = builtins.concatStringsSep " " dirs;
        userName = userName;
        group = group;
        logger = logger;
        activationTag = activationTag;
      }
    );
  };
}
