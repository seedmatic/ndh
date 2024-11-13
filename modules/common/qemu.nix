{pkgs, ...}: let
  # Create a derivation for setting up QEMU firmware
  setupFirmware = pkgs.runCommandLocal "setup-qemu-firmware" {} ''
    mkdir -p $out
    cp ${pkgs.qemu}/share/qemu/firmware/*.json $out
    substituteInPlace $out/*.json --replace ${pkgs.qemu} /run/current-system/sw
  '';
in {
  # Add necessary packages to system environment
  environment.systemPackages = with pkgs; [
    qemu
    libvirt
    virt-manager
    setupFirmware # Ensure firmware setup is included
  ];

  # Additional configuration options can be added here as needed
}
