{ lib, pkgs, ... }:
{
  # Disable bootloader installation in Lima / containerized / ZFS guest context.
  boot.loader = {
    systemd-boot.enable = lib.mkForce false;
    grub = {
      enable = lib.mkForce false;
      device = lib.mkForce "nodev"; # explicit no disk target
    };
    generic-extlinux-compatible.enable = lib.mkForce false;
    timeout = 0;
    efi.canTouchEfiVariables = lib.mkForce false;
  };

  # Provide a no-op installBootLoader hook so nixos-rebuild doesn't attempt bootspec/systemd-boot operations.
  system.build.installBootLoader = pkgs.replaceVars ./no-bootloader.d/skip-install-bootloader.sh { };

  # Reduce spurious warning: system expects some loader; we deliberately skip.
  # Mark system as virtualized so tooling is less insistent (optional hint; benign if already set elsewhere)
  virtualisation = {
    # No change to actual hypervisor; just a hint flag if unused elsewhere.
  };
}
