# Boot loader configuration for EFI systems (VZ/Tart VMs).
# Uses systemd-boot with EFI variables disabled (not persistent in VMs).
{ lib, config, ... }:
let
  ndhContext = config.ndh.context or { };
  hostProfile = ndhContext.hostProfile or { };
  generationMode = ndhContext.generationMode or "full";
  bringupMode = generationMode == "bringup";
  bootDebug = hostProfile.nixosBootstrapDebug or false;
in
{
  boot.loader = {
    # Disable GRUB - systemd-boot only
    grub.enable = lib.mkForce false;

    # systemd-boot for EFI
    systemd-boot.enable = lib.mkForce true;

    # Configuration limit:
    # - Bringup: 1 generation (disposable single-use image)
    # - Runtime: 3 generations (keep some history for rollback)
    systemd-boot.configurationLimit = if bringupMode then 1 else lib.mkDefault 3;

    # EFI variables are not persistent in VZ/Tart VMs
    efi.canTouchEfiVariables = lib.mkForce false;

    # Boot timeout
    timeout = lib.mkForce (
      if bringupMode then
        0 # Immediate boot for bringup
      else if bootDebug then
        15 # Extended timeout for debug/inspection
      else
        5 # Normal 5 second timeout for runtime
    );
  };
}
