{
  description = "NixOS ZFS installer lab (systemd-boot on raidz1)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "aarch64-darwin" "aarch64-linux" ];
    in
    {
      packages = forAllSystems (hostSystem:
        let
          hostPkgs = import nixpkgs { system = hostSystem; };
          materializeInstallerScriptTemplate = builtins.readFile ./scripts/materialize-nixos-installer-tart.sh;

          materializeNixosInstallerTart = hostPkgs.writeShellApplication {
            name = "materialize-nixos-installer-tart";
            runtimeInputs = [ hostPkgs.coreutils hostPkgs.findutils hostPkgs.gnugrep hostPkgs.nix hostPkgs.openssh ];
            text = materializeInstallerScriptTemplate;
          };

        in
        {
          materialize-nixos-installer-tart = materializeNixosInstallerTart;
        }
      );

      apps = forAllSystems (hostSystem:
        let
          hostPackages = self.packages.${hostSystem};
        in
        {
          materialize-nixos-installer-tart = {
            type = "app";
            program = "${hostPackages.materialize-nixos-installer-tart}/bin/materialize-nixos-installer-tart";
          };
        }
      );

      nixosConfigurations.nixos-installer-zfs-lab = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ({ ... }: {
            # @codebase
            # Lab install profile used by stage1 script. Keep it pure-evaluable:
            # do not import /mnt-generated files from hardware scan.

            networking.hostName = "nixos-installer-zfs-lab";
            networking.hostId = "4a1b2c3d";
            networking.useDHCP = true;

            boot.initrd.availableKernelModules = [
              "virtio_pci"
              "virtio_mmio"
              "virtio_blk"
              "virtio_scsi"
              "virtio_net"
              "sd_mod"
              "sr_mod"
            ];
            boot.initrd.verbose = true;
            boot.kernelParams = [
              "console=hvc0"
              "console=tty0"
              "earlycon"
              "loglevel=7"
              "ignore_loglevel"
            ];

            boot.supportedFilesystems = [ "zfs" "vfat" "ext4" ];
            boot.zfs.forceImportRoot = true;
            boot.zfs.devNodes = "/dev/disk/by-partlabel";
            boot.loader.efi.canTouchEfiVariables = false;
            boot.loader.efi.efiSysMountPoint = "/boot/efi";
            boot.loader.systemd-boot.enable = true;
            boot.loader.systemd-boot.editor = false;

            fileSystems."/" = {
              device = "tank/root";
              fsType = "zfs";
            };

            fileSystems."/nix" = {
              device = "tank/nix";
              fsType = "zfs";
              neededForBoot = true;
            };

            fileSystems."/home" = {
              device = "tank/home";
              fsType = "zfs";
            };

            fileSystems."/boot/efi" = {
              device = "/dev/disk/by-partlabel/esp";
              fsType = "vfat";
              neededForBoot = true;
            };

            services.openssh.enable = true;
            services.getty.autologinUser = "root";

            system.stateVersion = "25.11";
          })
        ];
      };
    };
}
