# @codebase
{ config, lib, pkgs, ... }:
let
  inherit (lib) concatStringsSep mkDefault mkIf mkOption types;
  zfsBin = "${config.boot.zfs.package}/bin/zfs";
in
{
  options.boot.loader.zbootmenu = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable ZBootMenu compatibility hook via boot.loader.external.installHook.";
    };

    bootfs = mkOption {
      type = types.str;
      default = "tank/root";
      description = "Dataset used as ZBootMenu bootfs target.";
    };
  };

  config = mkIf config.boot.loader.zbootmenu.enable {
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.devNodes = mkDefault "/dev";

    boot.loader.external = {
      enable = true;
      installHook = pkgs.writeShellScript "zbootmenu-install-hook" ''
        set -euo pipefail

        mkdir -p /boot

        kernel_src="$(readlink -f /nix/var/nix/profiles/system/kernel)"
        initrd_src="$(readlink -f /nix/var/nix/profiles/system/initrd)"
        system_src="$(readlink -f /nix/var/nix/profiles/system)"

        kernel_dst="/boot/vmlinuz-$(basename "$kernel_src")"
        initrd_dst="/boot/initramfs-$(basename "$initrd_src")"

        cp -f "$kernel_src" "$kernel_dst"
        cp -f "$initrd_src" "$initrd_dst"

        init_path="$system_src/init"
        if [[ ! -f "$init_path" ]]; then
          echo "[zbootmenu][ERROR] init path missing: $init_path" >&2
          exit 1
        fi

        cmdline="init=$init_path ${concatStringsSep " " config.boot.kernelParams}"
        ${zfsBin} set org.zfsbootmenu:commandline="$cmdline" ${config.boot.loader.zbootmenu.bootfs}

        echo "[zbootmenu] kernel=$kernel_dst"
        echo "[zbootmenu] initrd=$initrd_dst"
        echo "[zbootmenu] bootfs=${config.boot.loader.zbootmenu.bootfs}"
      '';
    };
  };
}
