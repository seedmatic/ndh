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
        ForwardAgent = true;
        ForwardX11 = false;
        AddKeysToAgent = "no";
        ControlMaster = "auto";
        ControlPersist = "yes";
        ControlPath = "${config.home.homeDirectory}/.ssh/master-%C";
      };
    };
  };
}
