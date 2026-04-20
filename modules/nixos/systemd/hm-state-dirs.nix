{
  config,
  lib,
  ndh,
  pkgs,
  ...
}:
let
  nixBashTrampoline = "${ndh.context.nixBashTrampoline}";
  user = config.profile.user;
  userName = user.name;
  homeDir = toString user.home; # already resolved by profile logic
  # Fallback group: if user.group null, assume same as userName
  group = if (user.group or null) == null then userName else user.group;
  dirEntries = [
    {
      path = "${homeDir}/.local";
      mode = "0755";
    }
    {
      path = "${homeDir}/.local/state";
      mode = "0755";
    }
    {
      path = "${homeDir}/.local/state/nix";
      mode = "0755";
    }
    {
      path = "${homeDir}/.local/state/nix/profiles";
      mode = "0755";
    }
    {
      path = "${homeDir}/.local/state/home-manager";
      mode = "0755";
    }
    {
      path = "${homeDir}/.local/state/home-manager/gcroots";
      mode = "0755";
    }
    {
      path = config.sshPaths.secretsRootDir;
      mode = "0700";
    }
    {
      path = config.sshPaths.secretsKeysDir;
      mode = "0700";
    }
    {
      path = config.sshPaths.authoritySecretsDir;
      mode = "0755";
    }
  ];
  # Use the wrapped activation logger placed in the store so it's always available
  loggerTag = "nixos.activationScripts.hmStateDirs";
in
{
  systemd.tmpfiles.rules = map (e: "z ${e.path} ${e.mode} ${userName} ${group} - -") dirEntries;

  # Extra activation script (idempotent) to guard against any race where tmpfiles runs late
  system.activationScripts.hmStateDirs = {
    deps = [ ];
    text =
      builtins.replaceStrings
        [
          "@nixBashTrampoline@"
          "@dirsWithModes@"
          "@userName@"
          "@group@"
          "@secretsRootDir@"
          "@loggerTag@"
        ]
        [
          nixBashTrampoline
          (builtins.concatStringsSep " " (map (e: lib.escapeShellArg "${e.path}|${e.mode}") dirEntries))
          userName
          group
          config.sshPaths.secretsRootDir
          loggerTag
        ]
        (builtins.readFile ./hm-state-dirs.d/ensure-dirs.sh);
  };
}
