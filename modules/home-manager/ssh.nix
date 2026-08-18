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

    # home-manager deprecated `matchBlocks` in favour of the freeform `settings`
    # (keyed by Host pattern; OpenSSH directive names verbatim, no camelCase).
    settings = {
      "*" = {
        ForwardAgent = true;
        AddKeysToAgent = "no";
        ControlMaster = "auto";
        ControlPersist = "yes";
        ControlPath = "${config.home.homeDirectory}/.ssh/master-%C";
      };
    };
  };

  # Transitional: the fleet dropped Lima (Tart/vz only).  These activation
  # steps scrub stale on-disk Lima SSH config left on already-deployed hosts;
  # remove them once every host has been rebuilt at least once.
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
