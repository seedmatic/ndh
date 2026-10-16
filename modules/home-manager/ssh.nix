{
  config,
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
        # Never forward: the agent holds the operator key and the GitHub signing and push keys, and any host
        # reached — the corporate vz host included — could use them for as long as the master connection lives.
        # Hops go through ProxyJump; commits are signed and pushed from the operator seat.
        ForwardAgent = false;
        ForwardX11 = false;
        AddKeysToAgent = "no";
        ControlMaster = "auto";
        ControlPersist = "yes";
        ControlPath = "${config.home.homeDirectory}/.ssh/master-%C";
      };
    };
  };
}
