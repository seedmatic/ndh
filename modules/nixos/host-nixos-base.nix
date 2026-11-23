# Common NixOS host base: the mechanical, host-name-parameterised blocks shared
# by the NixOS guests of bioskop and nikopol (sops age bootstrap, attic cache,
# LLM gateway, NFS/sshfs mounts, bringup observe, omo package, ...).
#
# Host-specific concerns (mcp browser forward / on-demand tunnels, loopback
# forward, ssh-lan override, store freeze toggle, dns-authoritative) stay in
# the per-host nixos.nix.
{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

let
  cfg = config.ndh.hostNixosBase;
  hostName = cfg.hostName;
in
{
  options.ndh.hostNixosBase = {
    enable = mkEnableOption "common NixOS host base";

    hostName = mkOption {
      type = types.str;
      default = config.profile.host.hostName;
      description = "Short host name (bioskop/nikopol). Drives device names and paths.";
    };

    metalspace = mkOption {
      type = types.str;
      default = hostName;
      description = "Metalspace name for the per-host attic cache.";
    };

    remoteSwapUrl = mkOption {
      type = types.nullOr types.str;
      default = "http://darwin.${hostName}:8000";
      description = "URL of the Darwin peer's llama-swap instance.";
    };

    sshfsRemoteHost = mkOption {
      type = types.str;
      default = "${hostName}.local";
      description = "SSH host name used by sshfs mounts.";
    };

    enableStoreFreeze = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the store freeze (tried first on this host).";
    };
  };

  config = mkIf cfg.enable {
    profile.user.home = lib.mkForce "/home/${config.profile.user.name}";

    ndh.sopsAgeKeyBootstrap = {
      defaultAgeKeyFile = "/var/lib/sops-nix/${hostName}-nixos.age";
      nixosHostKeyImport.enable = false;
    };
    sops.age.sshKeyPaths = [ ];

    ndh.atticCache = {
      enable = true;
      metalspace = cfg.metalspace;
      target = cfg.metalspace;
    };

    environment.systemPackages = [ pkgs.omo-ai ];

    services.llmGateway = {
      enable = true;
      sopsEncryptedFile = ../../.secrets;
      remoteSwapUrl = cfg.remoteSwapUrl;
    };

    bringupObserve.upstreamEndpoint = "http://192.168.5.2:9001";

    services.rpcbind.enable = true;

    # nfsmount.conf lives in /run (tmpfs, runtime-modifiable). A symlink
    # in /etc points to it so mount.nfs reads it, but the real file can be
    # edited at runtime without a rebuild.
    systemd.tmpfiles.rules = [
      "d /run/nfsmount.conf.d 0755 root root -"
      "w+ /run/nfsmount.conf.d/99-ndh.conf 0644 root root - [ NFSMount_Global_Options ]\\nVers=3\\nProto=tcp\\nSoft=True\\nTimeo=600\\nRetrans=2\\nActimeo=30\\nRsize=64k\\nWsize=64k\\n"
      "L+ /etc/nfsmount.conf.d/99-ndh.conf - - - - /run/nfsmount.conf.d/99-ndh.conf"
    ];

    # All NFS options live in nfsmount.conf (above). Per-mount options only
    # carry the systemd automount directives.
    fileSystems."/srv/darwin/git-worktree-store" = {
      device = "darwin.${hostName}:/Volumes/git-worktree-store";
      fsType = "nfs";
      options = [
        "x-systemd.automount"
        "noauto"
        "x-systemd.idle-timeout=60"
        "x-systemd.mount-timeout=30s"
      ];
    };

    fileSystems."/srv/darwin/git-bare-store" = {
      device = "darwin.${hostName}:/Volumes/git-bare-store";
      fsType = "nfs";
      options = [
        "x-systemd.automount"
        "noauto"
        "x-systemd.idle-timeout=60"
        "x-systemd.mount-timeout=30s"
      ];
    };

    services.sshfsMounts = {
      enable = true;
      remoteHost = cfg.sshfsRemoteHost;
      remoteUser = "nxmatic";
      mounts = [
        {
          remotePath = "/Volumes/git-worktree-store";
          localPath = "/srv/darwin/.sshfs/git-worktree-store";
        }
        {
          remotePath = "/Volumes/git-bare-store";
          localPath = "/srv/darwin/.sshfs/git-bare-store";
        }
      ];
    };

    ndh.storeFreeze.enable = cfg.enableStoreFreeze;
  };
}
