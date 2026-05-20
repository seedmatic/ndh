# rke2lab worktree overlay — surfaces the Darwin-side rke2lab clone via NFS
# as an overlayfs lower, with all writes (build outputs, .pulumi-state,
# .local.d/distrobuilder rootfs, …) landing on local /persist storage.
#
# Lower:    /net/<darwin-host>.local/private/var/lib/git/nxmatic/rke2lab
# Upper:    /persist/rke2lab-overlay/upper
# Work:     /persist/rke2lab-overlay/work
# Merged:   /persist/rke2lab-overlay/merged   (cd here to build / pulumi up)
#
# The merged path is auto-mounted lazily — boot succeeds even if the Darwin
# half is unreachable, and the NFS lower is only fetched on first access.
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  hostProfile = config.profile.host;
  cfg = config.services.rke2labOverlay;
  ownerUser = config.profile.user.name;
  ownerGroup = ownerUser;
in
{
  options.services.rke2labOverlay = {
    enable = lib.mkEnableOption "rke2lab worktree overlay over the Darwin-side NFS share";

    darwinHost = lib.mkOption {
      type = lib.types.str;
      default = hostProfile.hostName or "";
      description = ''
        Hostname of the Darwin half that exports the rke2lab clone. The
        default tracks profile.host.hostName, so bioskop-nixos pairs with
        bioskop and nikopol-nixos pairs with nikopol — the same value
        carried by the NDH_RDP_HOST env var.
      '';
    };

    worktreeRelativePath = lib.mkOption {
      type = lib.types.str;
      default = "private/var/lib/git/nxmatic/rke2lab";
      description = "Path of the rke2lab clone relative to the NFS export root.";
    };

    persistRoot = lib.mkOption {
      type = lib.types.path;
      default = /persist/rke2lab-overlay;
      description = "Local-only root holding upper/, work/ and the merged mountpoint.";
    };

    lowerPath = lib.mkOption {
      type = lib.types.str;
      default = "/net/${cfg.darwinHost}.local/${cfg.worktreeRelativePath}";
      description = "Resolved overlayfs lowerdir. Defaults to the autofs path on the Darwin half.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.darwinHost != "";
        message = "services.rke2labOverlay: darwinHost is empty — set it explicitly or define profile.host.hostName.";
      }
      {
        assertion = config.services.nfsAutofs.enable or false;
        message = "services.rke2labOverlay: requires services.nfsAutofs.enable = true (the lowerdir lives under /net/…).";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${toString cfg.persistRoot}        0755 ${ownerUser} ${ownerGroup} -"
      "d ${toString cfg.persistRoot}/upper  0755 ${ownerUser} ${ownerGroup} -"
      "d ${toString cfg.persistRoot}/work   0755 ${ownerUser} ${ownerGroup} -"
      "d ${toString cfg.persistRoot}/merged 0755 ${ownerUser} ${ownerGroup} -"
    ];

    fileSystems."${toString cfg.persistRoot}/merged" = {
      device = "overlay";
      fsType = "overlay";
      options = [
        "lowerdir=${cfg.lowerPath}"
        "upperdir=${toString cfg.persistRoot}/upper"
        "workdir=${toString cfg.persistRoot}/work"
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=600"
        "x-systemd.requires=autofs.service"
      ];
      noCheck = true;
    };
  };
}
