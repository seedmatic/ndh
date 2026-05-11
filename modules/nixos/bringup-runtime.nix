{
  config,
  lib,
  pkgs,
  ...
}:
# NixOS wiring for the bringup-runtime profile.
#
# Options + package derivations live at
# modules/.common.d/io-nxmatic-nix-darwin-home-bringup-runtime.nix. This
# module adds the NixOS-specific pieces:
#
#   - environment.systemPackages: expose the installer binary in the
#     system closure so it's available during manual recovery.
#   - systemd.tmpfiles: seed the profile symlinks declaratively (avoids
#     shell-trampoline mutation of profile state).
#   - systemd.services: oneshot that runs the installer at boot, so
#     `nixos-rebuild boot` (which skips activation) still has the
#     command contract available before sops-install-secrets runs.
let
  cfg = config.ndh.bringupRuntime;
in
{
  config = lib.mkIf cfg.enable {
    # Keep installer command available in the NixOS system closure, including
    # bootstrap images where we need explicit/manual profile installation.
    environment.systemPackages = [ cfg.installerPackage ];

    # Seed canonical runtime profile links as declarative host policy so
    # scripts do not need to mutate profile state via shell trampoline.
    systemd.tmpfiles.rules = [
      "d /nix/var/nix/profiles/per-user/root 0755 root root -"
      "L+ ${cfg.profileDir} - - - - ${cfg.runtimePackage}"
    ]
    ++ lib.optionals (config.profile.user.name != "root") [
      "d /nix/var/nix/profiles/per-user/${config.profile.user.name} 0755 root root -"
      "L+ /nix/var/nix/profiles/per-user/${config.profile.user.name}/${cfg.name} - - - - ${cfg.runtimePackage}"
    ];

    # `nixos-rebuild boot` does not run activation on the currently running
    # system. Ensure the bringup runtime profile is provisioned at next boot
    # before services that rely on the command contract.
    systemd.services.io-nxmatic-nix-darwin-home-bringup-runtime-install = {
      description = "Install NDH bringup runtime profile for root (@codebase)";
      wantedBy = [ "multi-user.target" ];
      requiredBy = [
        "sops-install-secrets.service"
        "io-nxmatic-nix-darwin-home-hostkey-enrollment-check.service"
      ];
      before = [
        # Read the configured name so NDH-prefixed (or otherwise overridden)
        # unit names are honored.
        "${config.ndh.sopsAgeKeyBootstrap.systemdUnitName}.service"
        "sops-install-secrets.service"
        "io-nxmatic-nix-darwin-home-hostkey-enrollment-check.service"
      ];
      path = [
        pkgs.bash
        config.nix.package
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        profile_dir_root="/nix/var/nix/profiles/per-user/root/${cfg.name}"
        profile_user="${config.profile.user.name}"
        profile_dir_user="/nix/var/nix/profiles/per-user/${config.profile.user.name}/${cfg.name}"

        mkdir -p /nix/var/nix/profiles/per-user/root
        mkdir -p "/nix/var/nix/profiles/per-user/${config.profile.user.name}"

        ${cfg.installerPackage}/bin/${cfg.installerCommand} "$profile_dir_root"

        if [ "$profile_user" != "root" ]; then
          ${cfg.installerPackage}/bin/${cfg.installerCommand} "$profile_dir_user"
        fi
      '';
    };
  };
}
