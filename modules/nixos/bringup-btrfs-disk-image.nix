# @codebase
# Minimal single-disk btrfs bringup image helper for serial/bootloader validation.
{
  lib,
  pkgs,
  config,
  diskSize ? 4096,
  memSize ? 1536,
  vmCpuCores ? 4,
  includeChannel ? false,

  qemuFallbackInVm ? true,
  name ? "nixos-bringup-image",
  efiSystemPartitionSizeMiB ? 512,
  rootFsType ? "btrfs",
  rootFsLabel ? "nixos",
  rootFsMountOptions ? [ ],
  nestedQemuForwardEnable ? true,
  nestedQemuForwardSshHostPort ? 10022,
  nestedQemuForwardMetricsHostPort ? 19100,
  nestedQemuForwardMonitHostPort ? 12812,
  nestedQemuTransientSshEnable ? true,
  nestedQemuTransientSshRootPassword ? "root",
  nestedQemuTransientSshAuthorizedKey ? "",
  nestedQemuTransientSshAuthorizedKeys ? [ ],
  nestedQemuTransientMonitEnable ? true,
  postVM ? "",
}:
assert lib.assertMsg (
  rootFsType == "btrfs"
) "bringup-btrfs-disk-image only supports rootFsType=btrfs";
let
  efiSystemPartitionSizeBytes = efiSystemPartitionSizeMiB * 1024 * 1024;
  espStartMiB = 1;
  espEndMiB = espStartMiB + efiSystemPartitionSizeMiB;
  rootStartMiB = espEndMiB + 1;
  bringupCommon = import ./bringup-disk-image-common.nix {
    inherit
      lib
      pkgs
      qemuFallbackInVm
      nestedQemuForwardEnable
      nestedQemuForwardSshHostPort
      nestedQemuForwardMetricsHostPort
      nestedQemuForwardMonitHostPort
      nestedQemuTransientMonitEnable
      nestedQemuTransientSshAuthorizedKey
      nestedQemuTransientSshAuthorizedKeys
      ;
  };
  bringupCommonScript = ./bringup-disk-image-common.sh;

  channelSources =
    let
      nixpkgsSource = lib.cleanSource pkgs.path;
    in
    pkgs.runCommand "nixos-${config.system.nixos.version}" { } ''
      mkdir -p "$out"
      cp -prd ${nixpkgsSource.outPath} "$out/nixos"
      chmod -R u+w "$out/nixos"
      if [ ! -e "$out/nixos/nixpkgs" ]; then
        ln -s . "$out/nixos/nixpkgs"
      fi
      rm -rf "$out/nixos/.git"
      echo -n ${config.system.nixos.versionSuffix} > "$out/nixos/.version-suffix"
    '';

  closureInfo = pkgs.closureInfo {
    rootPaths = [ config.system.build.toplevel ] ++ (lib.optional includeChannel channelSources);
  };

  modulesTree = pkgs.aggregateModules (
    with config.boot;
    [
      kernelPackages.kernel
      (lib.getOutput "modules" kernelPackages.kernel)
    ]
  );

  tools = lib.makeBinPath (
    with pkgs;
    [
      btrfs-progs
      coreutils
      disko
      nixos-enter
      config.system.build.nixos-install
      dosfstools
      e2fsprogs
      gptfdisk
      nix
      openssh
      monit
      parted
      shadow
      systemd
      util-linux
    ]
  );

  rootFsMkfsExtraArgs = [
    "-f"
    "-L"
    rootFsLabel
  ];

  # Discoverable Partitions Specification root type for systemd-gpt-auto on ARM64.
  rootPartitionType = "B921B045-1DF0-41C3-AF44-4C6F280D3FAE";

  diskoConfigFile = pkgs.writeText "bringup-disko.nix" ''
    { ... }:
    {
      disko.devices.disk.bringup = {
        type = "disk";
        device = "/dev/vda";
        imageSize = "${toString diskSize}M";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              start = "${toString espStartMiB}MiB";
              end = "${toString espEndMiB}MiB";
              type = "EF00";
              label = "ESP";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                extraArgs = [ "-n" "ESP" ];
              };
            };
            root = {
              start = "${toString rootStartMiB}MiB";
              end = "-1MiB";
              type = "${rootPartitionType}";
              label = "root";
              content = {
                type = "filesystem";
                format = "btrfs";
                mountpoint = "/";
                mountOptions = ${lib.generators.toPretty { } rootFsMountOptions};
                extraArgs = ${lib.generators.toPretty { } rootFsMkfsExtraArgs};
              };
            };
          };
        };
      };
    }
  '';

  diskoScript = pkgs.callPackage "${pkgs.disko}/share/disko/cli.nix" {
    inherit lib;
    mode = "format,mount";
    diskoFile = diskoConfigFile;
    rootMountPoint = "/mnt";
    noDeps = true;
  };
  diskoExe = lib.getExe diskoScript;

  fileSystemsCfgFile = pkgs.writeText "bringup-filesystems.nix" ''
    {
      fileSystems."/" = {
        device = "/dev/disk/by-partlabel/root";
        fsType = "btrfs";
        options = ${builtins.toJSON rootFsMountOptions};
      };
      fileSystems."/boot" = {
        device = "/dev/disk/by-partlabel/ESP";
        fsType = "vfat";
      };
      fileSystems."/nix" = {
        device = "/dev/disk/by-partlabel/root";
        fsType = "btrfs";
        options = [
          "subvol=nix"
          "nodatacow"
          "nodatasum"
        ];
      };
    }
  '';

  nestedQemuNetOpts = bringupCommon.nestedQemuNetOpts;
  nestedQemuTransientAuthorizedKeys = bringupCommon.nestedQemuTransientAuthorizedKeys;
  nestedQemuTransientSshPasswordAuthEnable = bringupCommon.nestedQemuTransientSshPasswordAuthEnable;
in
(bringupCommon.vmToolsBase.override {
  rootModules = [
    "btrfs"
    "fuse"
    "9p"
    "9pnet_virtio"
    "virtio_blk"
    "virtio_pci"
    "virtiofs"
  ];
  kernel = modulesTree;
}).runInLinuxVM
  (
    pkgs.runCommand name
      {
        QEMU_OPTS = lib.concatStringsSep " " [
          "-drive file=$bringupDiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          nestedQemuNetOpts
        ];
        # Keep inner VM CPU count aligned with hostProfile.nixosDiskImageVmCpuCores
        # (propagated as vmCpuCores from modules/nixos/outputs.nix).
        NIX_BUILD_CORES = toString vmCpuCores;
        inherit memSize;

        preVM = ''
          PATH="$PATH:${pkgs.qemu_kvm}/bin"
          mkdir "$out"

          source ${bringupCommonScript}

          bringupDiskImage=disk.raw
          bringup::create_raw_disk "$bringupDiskImage" ${toString diskSize}
        '';

        postVM = ''
          mv "$bringupDiskImage" "$out/nixos.img"
          if [[ -f boot-size-hint.json ]]; then
            mv boot-size-hint.json "$out/boot-size-hint.json"
          fi

          set -x
          ${postVM}
        '';
      }
      ''
                export PATH=${tools}:$PATH
                set -x

                source ${bringupCommonScript}
                bringup::link_legacy_block_devices
                bringup::ensure_nixbld_group
                bringup::ensure_usr_bin_env

                transient_authorized_keys="$(cat <<'EOF'
        ${lib.concatStringsSep "\n" nestedQemuTransientAuthorizedKeys}
        EOF
        )"

                bringup::start_transient_sshd \
                  ${if nestedQemuTransientSshEnable then "true" else "false"} \
                  ${if nestedQemuTransientSshPasswordAuthEnable then "yes" else "no"} \
                  ${lib.escapeShellArg nestedQemuTransientSshRootPassword} \
                  ${toString nestedQemuForwardSshHostPort} \
                  "$transient_authorized_keys"

                bringup::start_transient_monit \
                  ${if nestedQemuTransientMonitEnable then "true" else "false"} \
                  ${toString nestedQemuForwardMonitHostPort}

                mkdir -p /mnt

                # systemd-repart + disko mount-only relies on /dev/disk/by-partlabel/* symlinks.
                # In this minimal VM stage, ensure udev is running so those symlinks exist.
                bringup::udev_block_sync ${pkgs.systemd}/lib/systemd/systemd-udevd

                ${diskoExe}

                mkdir -p /mnt/nix
                if ! btrfs subvolume show /mnt/nix >/dev/null 2>&1; then
                  rmdir /mnt/nix 2>/dev/null || true
                  btrfs subvolume create /mnt/nix
                fi
                chattr +C /mnt/nix || true
                if ! mountpoint -q /mnt/nix; then
                  mount -t btrfs -o subvol=nix,nodatacow,nodatasum /dev/disk/by-partlabel/root /mnt/nix
                fi

                mkdir -p /mnt/etc/nixos

                cat ${fileSystemsCfgFile} > /mnt/etc/nixos/configuration.nix

                nix-store --option build-users-group "" --load-db < ${closureInfo}/registration

                : "Ensure target image store contains the exact system closure referenced"
                : "by boot entries (init=/nix/store/.../init) before nixos-install."
                bringup::ensure_toplevel_in_target_store "/mnt" ${config.system.build.toplevel}
                
                nixos-install \
                  --root /mnt \
                  --system ${config.system.build.toplevel} \
                  --substituters "" \
                  ${lib.optionalString includeChannel "--channel ${channelSources}"}

                boot_used_bytes=$(du -sb /mnt/boot | awk '{print $1}')
                boot_used_mib=$(( (boot_used_bytes + 1048575) / 1048576 ))
                esp_size_mib=${toString efiSystemPartitionSizeMiB}
                # Target policy: keep room for up to 3 boot configurations plus safety slack.
                target_config_count=3
                recommended_esp_mib=$(( (boot_used_mib * target_config_count) + 32 ))
                remaining_for_single_mib=$(( esp_size_mib - boot_used_mib ))

                cat > boot-size-hint.json <<EOF
                {
                  "bootUsedBytesSingleConfiguration": $boot_used_bytes,
                  "bootUsedMiBSingleConfiguration": $boot_used_mib,
                  "espSizeMiB": $esp_size_mib,
                  "remainingMiBAfterSingleConfiguration": $remaining_for_single_mib,
                  "targetConfigurationCount": $target_config_count,
                  "recommendedEspSizeMiBForTarget": $recommended_esp_mib,
                  "policyNote": "Recommended ESP size is estimated from one installed generation * target count + 32MiB slack."
                }
                EOF

                umount /mnt/nix || true
                umount /mnt/boot || true
                umount /mnt || true
      ''
  )
