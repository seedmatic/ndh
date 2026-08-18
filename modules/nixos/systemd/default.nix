{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
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
  mkNdhUnitName = ndhSystemd.mkUnitName;
  mkNdhServiceName = ndhSystemd.mkServiceName;
  contributedTargetName = ndhSystemd.contributedTargetName;
  sshKeysEnrichmentServiceName = mkNdhServiceName "ssh-keys-enrichment";
in
{
  # Note: `options.ndh.vm.provider` is declared in ./tart-host-shares.nix so
  # that modules outside the systemd aggregator (e.g. bringup-minimal via
  # ../sops.nix) can import host-shares without pulling the full aggregator.

  options.rescue.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable rescue-mode tooling and units (off by default; enable per-host if needed).";
  };

  imports = [
    ./naming.nix
    ./openssh.nix
    ./ssh-keys-enrichment.nix
    ./rescue.nix
    ./tart-host-shares.nix
  ]
  ++ (lib.optionals (effectiveVmProvider == "tart") [ ./tart-guest-agent.nix ])
  ++ (lib.optionals bringupMode [ ./zfs-nixos-install.nix ])
  ++ (lib.optionals (!bringupMode) [
    ./buildkitd.nix
    ./hm-state-dirs.nix
    # nix-store-identity moved to modules/nixos/nix-store-identity.nix
    # (platform-owned wiring per the common/platform split).
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

  # contributed.target declaration lives in ./naming.nix so modules that
  # only import naming.nix (e.g. bringup-minimal-system.nix) still get the
  # target.  Keeping it there avoids a duplicate declaration here.

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

}
