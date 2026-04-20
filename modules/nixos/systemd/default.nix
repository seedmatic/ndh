{
  config,
  pkgs,
  lib,
  hostProfile ? { },
  vmProvider ? null,
  ...
}:
let
  effectiveVmProvider =
    if vmProvider != null then
      vmProvider
    else if hostProfile ? vmProvider && hostProfile.vmProvider != null then
      hostProfile.vmProvider
    else
      "lima";

  hostImageMode =
    if hostProfile ? nixosImageMode && hostProfile.nixosImageMode != null then
      hostProfile.nixosImageMode
    else
      "full";
  bootstrapMode = hostImageMode == "bootstrap";
  profileUserName =
    if config ? profile && config.profile ? user && config.profile.user ? name then
      config.profile.user.name
    else
      "root";
  homeManagerServiceName = "home-manager-${profileUserName}";
  keysTargetUnit = "keys.target";
  hasSopsInstallSecretsService = builtins.hasAttr "sops-install-secrets" config.systemd.services;
  hasSshKeysEnrichmentService = builtins.hasAttr "io-nxmatic-nix-darwin-home-ssh-keys-enrichment" config.systemd.services;
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
  ]
  ++ (lib.optionals (effectiveVmProvider == "lima") [
    ./lima-cloud-init.nix
    ./lima-nixos-config.nix
    ./lima-guest-agent.nix
  ])
  ++ (lib.optionals (effectiveVmProvider == "tart") [ ./tart-guest-agent.nix ])
  ++ (lib.optionals (effectiveVmProvider == "tart") [ ./tart-host-shares.nix ])
  ++ (lib.optionals (!bootstrapMode) [
    ./buildkitd.nix
    ./hm-state-dirs.nix
  ]);

  config.systemd.targets.io-nxmatic-nix-darwin-home-contributed = {
    description = "Nix Darwin Home contributed units (@codebase)";
    requires = [ keysTargetUnit ];
    after = [ keysTargetUnit ];
    wantedBy = [ "multi-user.target" ];
  };

  config.systemd.services.${homeManagerServiceName} = lib.mkIf (!bootstrapMode) {
    wantedBy = [ "io-nxmatic-nix-darwin-home-contributed.target" ];
    requires = [
      keysTargetUnit
    ]
    ++ lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ]
    ++ lib.optionals hasSshKeysEnrichmentService [
      "io-nxmatic-nix-darwin-home-ssh-keys-enrichment.service"
    ];
    after = [
      keysTargetUnit
    ]
    ++ lib.optionals hasSopsInstallSecretsService [ "sops-install-secrets.service" ]
    ++ lib.optionals hasSshKeysEnrichmentService [
      "io-nxmatic-nix-darwin-home-ssh-keys-enrichment.service"
    ];
  };
}
