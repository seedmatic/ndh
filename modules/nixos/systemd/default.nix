{
  config,
  pkgs,
  lib,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  hostProfile = ndhContext.hostProfile;
  effectiveVmProvider = ndhContext.vmProvider;
  bringupMode = ndhContext.generationMode == "bringup";
  profileUserName =
    if config ? profile && config.profile ? user && config.profile.user ? name then
      config.profile.user.name
    else
      "root";
  homeManagerServiceName = "home-manager-${profileUserName}";
  keysTargetUnit = "keys.target";
  ndhUnitPrefix = "io-nxmatic-nix-darwin-home";
  mkNdhUnitName =
    suffix: if lib.hasPrefix "${ndhUnitPrefix}-" suffix then suffix else "${ndhUnitPrefix}-${suffix}";
  mkNdhServiceName = suffix: "${mkNdhUnitName suffix}.service";
  mkNdhTargetName = suffix: "${mkNdhUnitName suffix}.target";
  contributedTargetName = mkNdhTargetName "contributed";
  sshKeysEnrichmentServiceName = mkNdhServiceName "ssh-keys-enrichment";
  attachToContributedTarget =
    serviceAttrs:
    serviceAttrs
    // {
      wantedBy = lib.unique ((serviceAttrs.wantedBy or [ ]) ++ [ contributedTargetName ]);
    };
in
{
  options.ndh.vm.provider = lib.mkOption {
    type = lib.types.enum [
      "lima"
      "tart"
      "none"
    ];
    default = effectiveVmProvider;
    description = ''
      VM provider mode for guest-side systemd wiring.
      - lima: enable Lima cidata/cloud-init + guest agent units.
      - tart: disable Lima-specific units (Tart-specific units can be layered separately).
      - none: disable provider-specific VM units.
    '';
  };

  options.rescue.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable rescue-mode tooling and units (off by default; enable per-host if needed).";
  };

  imports = [
    ./openssh.nix
    ./ssh-keys-enrichment.nix
    ./rescue.nix
    ./tart-host-shares.nix
  ]
  ++ (lib.optionals (effectiveVmProvider == "lima") [
    ./lima-cloud-init.nix
    ./lima-nixos-config.nix
    ./lima-guest-agent.nix
  ])
  ++ (lib.optionals (effectiveVmProvider == "tart") [ ./tart-guest-agent.nix ])
  ++ (lib.optionals bringupMode [ ./zfs-nixos-install.nix ])
  ++ (lib.optionals (!bringupMode) [
    ./buildkitd.nix
    ./hm-state-dirs.nix
    ./nix-store-identity.nix
  ]);

  # Ensure the systemd manager's own PATH includes NixOS system paths.
  # Without this, systemd-run transient units (e.g. nixos-rebuild switch-to-configuration)
  # inherit only the minimal systemd bootstrap PATH, causing "bash: not found" errors
  # when the bootloader installer or activation scripts invoke bash.
  # lib.mkForce overrides the lib.mkDefault in openssh.nix, which sets a narrower PATH.
  config.systemd.globalEnvironment.PATH = lib.mkForce (
    lib.concatStringsSep ":" [
      "/run/wrappers/bin"
      "/run/current-system/sw/bin"
      "/nix/var/nix/profiles/default/bin"
      "/bin"
      "/usr/bin"
    ]
  );

  config.systemd.targets.${mkNdhUnitName "contributed"} = {
    description = "Nix Darwin Home contributed units (@codebase)";
    requires = [ keysTargetUnit ];
    after = [ keysTargetUnit ];
    wantedBy = [ "multi-user.target" ];
  };

  config.systemd.services.${homeManagerServiceName} = lib.mkIf (!bringupMode) {
    wantedBy = [ contributedTargetName ];
    requires = [
      keysTargetUnit
    ]
    ++ [ "sops-install-secrets.service" ]
    ++ [
      sshKeysEnrichmentServiceName
    ];
    after = [
      keysTargetUnit
    ]
    ++ [ "sops-install-secrets.service" ]
    ++ [
      sshKeysEnrichmentServiceName
    ]
    ++ [ "systemd-logind.service" ];
    # Expose the user's systemd runtime directory so reloadSystemd can reach
    # the user D-Bus session (required for `systemctl --user` during activation).
    serviceConfig.Environment = "XDG_RUNTIME_DIR=/run/user/%U";
  };

  config._module.args.ndhSystemd = {
    unitPrefix = ndhUnitPrefix;
    mkUnitName = mkNdhUnitName;
    mkServiceName = mkNdhServiceName;
    mkTargetName = mkNdhTargetName;
    contributedTargetName = contributedTargetName;
    attachToContributedTarget = attachToContributedTarget;
    tailscaleAutoconnectUnitName = mkNdhUnitName "tailscaled-autoconnect";
  };
}
