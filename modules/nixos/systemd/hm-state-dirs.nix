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
  # tmpfiles entries with `recursive = true` use the `Z` rule type
  # instead of `z` so ownership/mode propagates into existing children.
  # The ssh-keys-enrichment service writes individual files as root
  # (User=root on its unit); without `Z` those files stay root-owned
  # even though the directory is correctly `nxmatic`-owned.  Applying
  # `Z` on the keys directory re-chowns the tree on every activation
  # so sshd + home-manager consumers see user-owned artifacts.
  dirEntries = [
    {
      path = "${homeDir}/.local";
      mode = "0755";
    }
    {
      path = "${homeDir}/.local/share";
      mode = "0755";
    }
    # ~/.local/share/ndh is declared further down as secretsRootDir
    # (mode 0700) — don't re-declare here with a conflicting mode.
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
      recursive = true;
    }
    {
      path = config.sshPaths.secretsKeysDir;
      mode = "0700";
      recursive = true;
    }
    {
      path = config.sshPaths.authoritySecretsDir;
      mode = "0755";
      recursive = true;
    }
  ];
  # Use the wrapped activation logger placed in the store so it's always available
  loggerTag = "nixos.activationScripts.hmStateDirs";
in
{
  systemd.tmpfiles.rules = map (
    e:
    let
      # `Z` recursively applies ownership/mode; `z` affects only the dir
      # and its immediate children.  Per-entry opt-in via `recursive`
      # keeps shallow entries cheap while re-chowning known-root-writer
      # trees (ssh-keys-enrichment, cert extraction) every boot.
      ruleType = if (e.recursive or false) then "Z" else "z";
    in
    "${ruleType} ${e.path} ${e.mode} ${userName} ${group} - -"
  ) dirEntries;

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
