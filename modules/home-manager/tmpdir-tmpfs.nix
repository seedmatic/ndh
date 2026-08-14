# Volatile, case-sensitive tmpfs backing the operator's TMPDIR.
#
# WHY: the OSGi framework (Felix bundle cache ~64 MiB) and the manifests
# synthesis mint temp dirs under $TMPDIR; a RAM-backed volume gives them fast,
# volatile scratch that vanishes on reboot (belt-1: the machine owns the
# volatile backing; consumers still sweep their own temp).
#
# macOS mount_tmpfs needs root, so a login LaunchAgent re-execs the mount script
# under `sudo -n` (nxmatic has NOPASSWD — modules/darwin/security.nix). The
# mount point always exists as a plain on-disk dir, so TMPDIR stays valid even
# when the mount is skipped or fails — the tmpfs simply overlays it.
#
# Darwin-only by construction: pulled in only through a per-host darwin bridge
# (hosts/<host>/modules/darwin/tmpdir-tmpfs.nix), so it never loads on NixOS.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.tmpdirTmpfs;
  script = pkgs.writeScriptBin "mount-tmpdir-tmpfs.sh" (builtins.readFile ./tmpdir-tmpfs.sh);
  reapScript = pkgs.writeScriptBin "tmpdir-reap.sh" (
    builtins.replaceStrings [ "@lsof@" ] [ "${pkgs.lsof}/bin/lsof" ] (
      builtins.readFile ./tmpdir-reap.sh
    )
  );
in
{
  options.services.tmpdirTmpfs = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Mount a volatile case-sensitive tmpfs as the operator's TMPDIR.";
    };

    mountPoint = mkOption {
      type = types.str;
      default = "${config.home.homeDirectory}/.tmpfs";
      description = "Directory the tmpfs is mounted at; also the value of TMPDIR.";
    };

    maxSize = mkOption {
      type = types.str;
      default = "4g";
      description = "tmpfs size cap passed to mount_tmpfs -s (k/m/g/t suffix).";
    };

    overrideTmpdir = mkOption {
      type = types.bool;
      default = true;
      description = "Point home.sessionVariables.TMPDIR at the mount point (all shells).";
    };

    reap = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Periodically sweep stale, unopened files from the tmpfs scratch.";
      };

      days = mkOption {
        type = types.int;
        default = 3;
        description = "Delete regular files untouched (mtime) for more than this many days and not held open.";
      };

      intervalSeconds = mkOption {
        type = types.int;
        default = 14400;
        description = "Reaper cadence (StartInterval); also fires on wake if an interval elapsed during sleep.";
      };
    };
  };

  config = mkIf cfg.enable {
    launchd.agents.tmpdir-tmpfs = {
      enable = true;
      config = {
        Label = "io.nxmatic.nix-darwin-home.tmpdir-tmpfs";
        ProgramArguments = [
          "${script}/bin/mount-tmpdir-tmpfs.sh"
          cfg.mountPoint
          cfg.maxSize
        ];
        RunAtLoad = true;
        KeepAlive = false;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/tmpdir-tmpfs.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/tmpdir-tmpfs.log";
        EnvironmentVariables = {
          PATH = "/usr/sbin:/sbin:/usr/bin:/bin:${pkgs.coreutils}/bin";
        };
      };
    };

    # Belt-2 backstop: RAM-backed tmpfs only reclaims space at reboot, so sweep
    # stale, unopened files every intervalSeconds (and on wake, when launchd
    # replays a due interval missed during sleep). Keeps a long-running host
    # from filling the volatile scratch with temp that consumers leaked.
    launchd.agents.tmpdir-tmpfs-reap = mkIf cfg.reap.enable {
      enable = true;
      config = {
        Label = "io.nxmatic.nix-darwin-home.tmpdir-tmpfs-reap";
        ProgramArguments = [
          "${reapScript}/bin/tmpdir-reap.sh"
          cfg.mountPoint
          (toString cfg.reap.days)
        ];
        StartInterval = cfg.reap.intervalSeconds;
        RunAtLoad = false;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/tmpdir-tmpfs.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/tmpdir-tmpfs.log";
        EnvironmentVariables = {
          PATH = "/usr/sbin:/sbin:/usr/bin:/bin";
        };
      };
    };

    # TMPDIR must always name a real directory, so create the mount point as a
    # plain on-disk dir at activation (the tmpfs overlays it when the agent
    # runs). Runs as the user, no sudo.
    home.activation.ensureTmpdirMountPoint = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
      /bin/mkdir -p ${escapeShellArg cfg.mountPoint}
      /bin/chmod 0700 ${escapeShellArg cfg.mountPoint}
    '';

    home.sessionVariables = mkIf cfg.overrideTmpdir {
      TMPDIR = cfg.mountPoint;
    };
  };
}
